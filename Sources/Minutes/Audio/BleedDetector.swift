import Accelerate
import Foundation

/// Finds where the microphone only hears the call coming out of the speakers ("bleed"), by comparing
/// the mic with the system audio track at the speaker-to-mic delay. Both tracks are on one clock, so
/// the delay is measured per 10 s block (built-in speakers ≈ 10–50 ms, Bluetooth up to a few hundred),
/// then every 200 ms window is classified:
///
/// - bleed: the mic is (almost) a scaled copy of what the call played (high correlation, mic no louder
///   than the echo usually is)
/// - double talk: partly a copy, or much louder than echo — the user is talking over the call
/// - local: unrelated to the call audio
///
/// Runs of bleed without double talk are silenced before transcription. Approach after OpenWhispr's
/// meetingEchoLeakDetector, but with measured delays instead of a lag search per 33 ms chunk.
nonisolated enum BleedDetector {
    struct Result: Sendable {
        /// Chunk-relative seconds to silence on the mic track.
        let ranges: [ClosedRange<Double>]
        /// Median speaker-to-mic delay, or nil when no echo path was found (e.g. headphones).
        let delayMs: Double?
        let bleedWindows: Int
        let doubleTalkWindows: Int
        let localWindows: Int

        var bleedSeconds: Double { ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
        static let none = Result(ranges: [], delayMs: nil, bleedWindows: 0, doubleTalkWindows: 0, localWindows: 0)
    }

    static let rate = 16_000
    static let window = 3_200           // 200 ms
    static let hop = 1_600              // 100 ms
    static let block = 160_000          // 10 s, for delay estimates
    static let minLag = -320            // -20 ms (timestamp slack)
    static let micFloor: Float = 0.006  // RMS below this: nothing to judge on the mic
    static let systemFloor: Float = 0.004
    static let bleedCorrelation: Float = 0.74
    static let doubleTalkCorrelation: Float = 0.55
    /// Low on purpose: a wrong delay only makes windows look unrelated, so nothing gets silenced.
    static let blockConfidence: Float = 0.15

    /// - Parameter maxLagMs: longest speaker-to-mic delay searched (default 400 ms covers Bluetooth).
    static func detect(mic micPCM: [Int16], system systemPCM: [Int16], muted: [ClosedRange<Double>],
                       maxLagMs: Double = 400) -> Result {
        let maxLag = Int(maxLagMs * Double(rate) / 1000)
        let n = min(micPCM.count, systemPCM.count)
        guard n > window * 4 else { return .none }
        var mic = toFloat(micPCM, count: n)
        var system = toFloat(systemPCM, count: n)
        highPass(&mic)
        highPass(&system)

        // 1. Speaker-to-mic delay per 10 s block, from blocks where both sides have sound.
        var lags: [Int?] = []
        var start = 0
        while start < n {
            let end = min(n, start + block)
            if end - start >= window * 4,
               rms(mic, start..<end) >= micFloor * 0.5, rms(system, start..<end) >= systemFloor {
                let (lag, correlation) = estimateLag(mic: mic, system: system, range: start..<end, maxLag: maxLag)
                lags.append(correlation >= blockConfidence ? lag : nil)
            } else {
                lags.append(nil)
            }
            start = end
        }
        let found = lags.compactMap { $0 }
        guard !found.isEmpty else { return .none }
        let median = found.sorted()[found.count / 2]
        // Blocks without their own estimate use the nearest one that has it.
        let blockLags: [Int] = lags.indices.map { i in
            if let lag = lags[i] { return lag }
            let nearest = lags.indices.filter { lags[$0] != nil }.min { abs($0 - i) < abs($1 - i) }
            return nearest.flatMap { lags[$0] } ?? median
        }

        // 2. Classify 200 ms windows at that delay (±1 ms for drift).
        enum Kind { case silent, bleed, doubleTalk, local }
        var kinds: [Kind] = []
        var gains: [Float] = []
        var energies: [(mic: Float, system: Float, gain: Float, correlation: Float)] = []
        var t = 0
        while t + window <= n {
            let lag = blockLags[min(t / block, blockLags.count - 1)]
            let micRMS = rms(mic, t..<(t + window))
            var best: (c: Float, gain: Float, systemEnergy: Float) = (0, 0, 0)
            if micRMS >= micFloor {
                for offset in stride(from: -16, through: 16, by: 2) {
                    let s = t - lag - offset
                    guard s >= 0, s + window <= n else { continue }
                    let (c, gain, systemEnergy) = correlate(mic, t, system, s, window)
                    if c > best.c { best = (c, gain, systemEnergy) }
                }
            }
            let micEnergy = micRMS * micRMS * Float(window)
            energies.append((micEnergy, best.systemEnergy, best.gain, best.c))
            if micRMS < micFloor {
                kinds.append(.silent)
            } else if best.systemEnergy < systemFloor * systemFloor * Float(window) {
                kinds.append(.local)
            } else if best.c >= bleedCorrelation {
                kinds.append(.bleed)
                if best.c >= 0.8 { gains.append(best.gain) }
            } else if best.c >= doubleTalkCorrelation {
                kinds.append(.doubleTalk)
            } else {
                kinds.append(.local)
            }
            t += hop
        }

        // 3. Calibrated echo gain: a "bleed" window whose mic is far louder than the echo usually is
        //    has the user talking on top of it.
        if gains.count >= 5 {
            let g = gains.sorted()[gains.count / 2]
            for i in kinds.indices where kinds[i] == .bleed {
                let expected = g * g * energies[i].system
                if energies[i].mic > 4 * expected { kinds[i] = .doubleTalk }
            }
        }

        // 4. Runs of bleed (a silent window may sit inside) with no double talk → silence them. Where a
        //    run touches the user's own speech it keeps 100 ms away, so word edges are never clipped.
        var ranges: [ClosedRange<Double>] = []
        var runStart: Int?
        var runEnd = 0
        var bleedInRun = 0
        func talking(_ i: Int) -> Bool { kinds.indices.contains(i) && (kinds[i] == .local || kinds[i] == .doubleTalk) }
        func closeRun() {
            if let s = runStart, bleedInRun >= 2 {
                // Windows overlap by half: use each one's middle 100 ms.
                var lo = Double(s * hop + (window - hop) / 2) / Double(rate)
                var hi = Double(runEnd * hop + (window + hop) / 2) / Double(rate)
                if talking(s - 1) { lo += 0.1 } else { lo = max(0, lo - 0.02) }
                if talking(runEnd + 1) { hi -= 0.1 } else { hi += 0.02 }
                if hi - lo >= 0.25, !muted.contains(where: { $0.lowerBound <= lo && $0.upperBound >= hi }) {
                    ranges.append(lo...hi)
                }
            }
            runStart = nil
            bleedInRun = 0
        }
        for (i, kind) in kinds.enumerated() {
            switch kind {
            case .bleed:
                if runStart == nil { runStart = i }
                runEnd = i
                bleedInRun += 1
            case .silent:
                if runStart != nil, i - runEnd > 2 { closeRun() }
            case .doubleTalk, .local:
                closeRun()
            }
        }
        closeRun()

        return Result(ranges: ranges, delayMs: Double(median) * 1000 / Double(rate),
                      bleedWindows: kinds.filter { $0 == .bleed }.count,
                      doubleTalkWindows: kinds.filter { $0 == .doubleTalk }.count,
                      localWindows: kinds.filter { $0 == .local }.count)
    }

    // MARK: - Signal helpers

    private static func toFloat(_ pcm: [Int16], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        pcm.withUnsafeBufferPointer { src in
            vDSP_vflt16(src.baseAddress!, 1, &out, 1, vDSP_Length(count))
        }
        var scale: Float = 1 / 32768
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(count))
        return out
    }

    /// 2nd-order Butterworth high-pass at 200 Hz: laptop speakers reproduce little below it, and room
    /// rumble there only blurs the comparison.
    private static func highPass(_ x: inout [Float]) {
        let w0 = 2 * Double.pi * 200 / Double(rate)
        let alpha = sin(w0) / (2 * 0.7071)
        let a0 = 1 + alpha
        let b0 = Float((1 + cos(w0)) / 2 / a0), b1 = Float(-(1 + cos(w0)) / a0), b2 = b0
        let a1 = Float(-2 * cos(w0) / a0), a2 = Float((1 - alpha) / a0)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in x.indices {
            let x0 = x[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
            x[i] = y0
        }
    }

    private static func rms(_ x: [Float], _ range: Range<Int>) -> Float {
        var value: Float = 0
        x.withUnsafeBufferPointer { p in
            vDSP_rmsqv(p.baseAddress! + range.lowerBound, 1, &value, vDSP_Length(range.count))
        }
        return value
    }

    /// Normalised correlation, least-squares gain (mic ≈ gain · system) and system energy of two windows.
    private static func correlate(_ a: [Float], _ aStart: Int, _ b: [Float], _ bStart: Int, _ count: Int) -> (Float, Float, Float) {
        var dot: Float = 0, ea: Float = 0, eb: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                vDSP_dotpr(pa.baseAddress! + aStart, 1, pb.baseAddress! + bStart, 1, &dot, vDSP_Length(count))
                vDSP_svesq(pa.baseAddress! + aStart, 1, &ea, vDSP_Length(count))
                vDSP_svesq(pb.baseAddress! + bStart, 1, &eb, vDSP_Length(count))
            }
        }
        guard ea > 0, eb > 0 else { return (0, 0, eb) }
        return (dot / (ea * eb).squareRoot(), dot / eb, eb)
    }

    /// Delay (in samples, mic after system) with the highest correlation over a block: a coarse search
    /// on 4 kHz copies, refined at 16 kHz.
    private static func estimateLag(mic: [Float], system: [Float], range: Range<Int>, maxLag: Int) -> (Int, Float) {
        let factor = 4
        func decimate(_ x: [Float], _ r: Range<Int>) -> [Float] {
            stride(from: r.lowerBound, to: r.upperBound - factor + 1, by: factor).map { i in
                (x[i] + x[i + 1] + x[i + 2] + x[i + 3]) / 4
            }
        }
        let systemStart = max(0, range.lowerBound - maxLag)
        let systemEnd = min(system.count, range.upperBound - minLag)
        let micD = decimate(mic, range)
        let systemD = decimate(system, systemStart..<systemEnd)
        let offset = (range.lowerBound - systemStart) / factor   // micD[i] aligns with systemD[i + offset] at lag 0

        var bestLag = 0
        var bestDot = -Float.infinity
        for lagD in (minLag / factor)...(maxLag / factor) {
            // correlation at lag L: Σ mic[t] · system[t − L]
            let sysIndex = offset - lagD
            let lo = max(0, -sysIndex)
            let hi = min(micD.count, systemD.count - sysIndex)
            guard hi - lo > 1_000 else { continue }
            var dot: Float = 0
            micD.withUnsafeBufferPointer { pm in
                systemD.withUnsafeBufferPointer { ps in
                    vDSP_dotpr(pm.baseAddress! + lo, 1, ps.baseAddress! + lo + sysIndex, 1, &dot, vDSP_Length(hi - lo))
                }
            }
            if dot > bestDot { bestDot = dot; bestLag = lagD * factor }
        }

        // Refine at full rate around the coarse peak.
        var best: (lag: Int, c: Float) = (bestLag, 0)
        for lag in (bestLag - 6)...(bestLag + 6) {
            let lo = max(range.lowerBound, lag)
            let hi = min(range.upperBound, system.count + lag)
            guard hi - lo > window else { continue }
            let (c, _, _) = correlate(mic, lo, system, lo - lag, hi - lo)
            if c > best.c { best = (lag, c) }
        }
        return (best.lag, best.c)
    }
}
