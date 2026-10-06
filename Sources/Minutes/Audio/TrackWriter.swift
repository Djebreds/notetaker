import AVFAudio
import Foundation

/// A chunk of one track, closed and ready to be encoded.
nonisolated struct ClosedChunk: Sendable {
    let track: Track
    let index: Int
    /// Raw little-endian Int16 mono samples at 16 kHz.
    let pcmURL: URL
    /// Position on the session timeline (16 kHz samples since recording started).
    let startSample: Int64
    let sampleCount: Int64
    /// Energy of each 20 ms frame in dBFS.
    let frameDB: [Float]
}

/// Writes one 16 kHz mono track onto the session timeline.
///
/// Samples are placed by host time, so both tracks stay aligned: gaps (a capture restarting, a
/// stalled device) are filled with silence and late duplicates are dropped. Audio goes to raw
/// PCM files, which survive a crash intact. Chunks are cut at an explicit sample index so the
/// "me" and "others" tracks share chunk boundaries.
nonisolated final class TrackWriter: @unchecked Sendable {
    static let sampleRate = 16_000.0
    static let frameSamples = 320   // 20 ms
    private static let maxSkew: Int64 = 3_200  // 0.2 s

    let track: Track
    private let folder: URL
    private let sessionStartHost: UInt64
    private let onClosed: @Sendable (ClosedChunk) -> Void
    private let lock = NSLock()

    private var index = 0
    private var chunkStart: Int64 = 0
    private var position: Int64 = 0
    private var file: FileHandle?
    private var fileURL: URL?
    private var cutAt: Int64?
    private var frameDB: [Float] = []
    private var frameSum: Double = 0
    private var frameCount = 0
    private var peak: Float = 0
    private var lastNonSilentHost: UInt64

    /// - Parameter firstIndex: number of the first chunk (a resumed meeting continues its numbering).
    init(track: Track, folder: URL, sessionStartHost: UInt64, firstIndex: Int = 1,
         onClosed: @escaping @Sendable (ClosedChunk) -> Void) {
        self.track = track
        self.folder = folder
        self.sessionStartHost = sessionStartHost
        self.onClosed = onClosed
        self.lastNonSilentHost = sessionStartHost
        self.index = firstIndex - 1
    }

    // MARK: - Writing

    /// Appends 16 kHz mono Float32 audio whose first sample was captured at `hostTime`.
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        var samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        let expected = Int64(max(0, HostClock.seconds(from: sessionStartHost, to: hostTime)) * Self.sampleRate)

        var closed: [ClosedChunk] = []
        lock.lock()
        if expected - position > Self.maxSkew {
            write(nil, count: Int(expected - position), closed: &closed)
        } else if position - expected > Self.maxSkew {
            let drop = Int(position - expected)
            guard drop < samples.count else { lock.unlock(); return }
            samples = UnsafeBufferPointer(rebasing: samples[drop...])
        }
        var loudest: Float = 0
        for s in samples { loudest = max(loudest, abs(s)) }
        peak = max(peak, loudest)
        if loudest > 0.0005 { lastNonSilentHost = hostTime }
        write(samples, count: samples.count, closed: &closed)
        lock.unlock()
        closed.forEach(onClosed)
    }

    /// Fills silence up to `hostTime` when no audio has been arriving (stalled or restarting capture).
    func padSilence(upTo hostTime: UInt64) {
        let target = Int64(max(0, HostClock.seconds(from: sessionStartHost, to: hostTime)) * Self.sampleRate)
        var closed: [ClosedChunk] = []
        lock.lock()
        if target - position > Self.maxSkew { write(nil, count: Int(target - position), closed: &closed) }
        lock.unlock()
        closed.forEach(onClosed)
    }

    /// Ends the current chunk once the timeline reaches `sample`.
    func requestCut(at sample: Int64) {
        var closed: [ClosedChunk] = []
        lock.lock()
        if sample <= position {
            closeChunk(into: &closed)
        } else {
            cutAt = sample
        }
        lock.unlock()
        closed.forEach(onClosed)
    }

    /// Pads with silence to `sample` (so both tracks end together) and closes the last chunk.
    func finish(padTo sample: Int64) {
        var closed: [ClosedChunk] = []
        lock.lock()
        cutAt = nil
        if sample > position { write(nil, count: Int(sample - position), closed: &closed) }
        closeChunk(into: &closed)
        lock.unlock()
        closed.forEach(onClosed)
    }

    // MARK: - State for the recorder

    var currentPosition: Int64 { lock.withLock { position } }
    var currentChunkStart: Int64 { lock.withLock { chunkStart } }
    var lastAudibleHost: UInt64 { lock.withLock { lastNonSilentHost } }

    /// Loudest 20 ms frame (dBFS) over the last `frames` frames of the current chunk.
    func recentLevel(frames: Int) -> Float {
        lock.withLock { frameDB.suffix(frames).max() ?? -120 }
    }

    /// Peak sample since the previous call, for level meters.
    func takePeak() -> Float {
        lock.withLock {
            defer { peak = 0 }
            return peak
        }
    }

    // MARK: - Internals (lock held)

    private func write(_ samples: UnsafeBufferPointer<Float>?, count: Int, closed: inout [ClosedChunk]) {
        var offset = 0
        while offset < count {
            if file == nil { openChunk() }
            var n = min(count - offset, 160_000)  // bounded blocks, even for long silence gaps
            if let cut = cutAt { n = min(n, Int(max(0, cut - position))) }
            if n > 0 {
                var pcm = [Int16](repeating: 0, count: n)
                if let samples {
                    for i in 0..<n {
                        let v = max(-1, min(1, samples[offset + i]))
                        pcm[i] = Int16(v * 32767)
                    }
                }
                pcm.withUnsafeBytes { file?.write(Data($0)) }
                accumulateEnergy(pcm)
                position += Int64(n)
                offset += n
            }
            if let cut = cutAt, position >= cut {
                closeChunk(into: &closed)
            }
        }
    }

    private func accumulateEnergy(_ pcm: [Int16]) {
        for s in pcm {
            let v = Double(s) / 32768
            frameSum += v * v
            frameCount += 1
            if frameCount == Self.frameSamples { flushFrame() }
        }
    }

    private func flushFrame() {
        guard frameCount > 0 else { return }
        frameDB.append(Float(10 * log10(frameSum / Double(frameCount) + 1e-12)))
        frameSum = 0
        frameCount = 0
    }

    private func openChunk() {
        index += 1
        chunkStart = position
        frameDB = []
        frameSum = 0
        frameCount = 0
        let url = folder.appendingPathComponent(String(format: "%04d-%@.pcm", index, track.rawValue))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
        fileURL = url
        if file == nil { Log.error("Cannot open \(url.lastPathComponent) for writing", "audio") }
    }

    private func closeChunk(into closed: inout [ClosedChunk]) {
        cutAt = nil
        guard let handle = file, let url = fileURL else { return }
        flushFrame()
        try? handle.close()
        file = nil
        fileURL = nil
        closed.append(ClosedChunk(track: track, index: index, pcmURL: url, startSample: chunkStart,
                                  sampleCount: position - chunkStart, frameDB: frameDB))
    }
}
