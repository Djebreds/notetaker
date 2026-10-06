import AVFAudio
import Foundation

/// Turns a closed raw chunk into its final form: muted stretches silenced, speech islands found,
/// encoded as 16 kHz mono FLAC, raw file removed.
nonisolated enum ChunkEncoder {
    struct Output: Sendable {
        let track: Track
        let index: Int
        let start: Double
        let duration: Double
        /// Relative to the meeting folder.
        let file: String
        let speechSeconds: Double
        let islands: [SpeechIsland]
    }

    /// - Parameter mask: chunk-relative ranges (seconds) to silence before anything leaves the Mac.
    static func finalize(_ chunk: ClosedChunk, samples preloaded: [Int16]? = nil, mask: [ClosedRange<Double>],
                         meetingFolder: URL) throws -> Output {
        let rate = TrackWriter.sampleRate
        var samples = try preloaded ?? readPCM(chunk.pcmURL)
        var frameDB = chunk.frameDB

        for range in mask {
            let lo = max(0, Int(range.lowerBound * rate))
            let hi = min(samples.count, Int(range.upperBound * rate))
            if lo < hi { for i in lo..<hi { samples[i] = 0 } }
            let flo = max(0, lo / TrackWriter.frameSamples)
            let fhi = min(frameDB.count, hi / TrackWriter.frameSamples + 1)
            if flo < fhi { for i in flo..<fhi { frameDB[i] = -120 } }
        }

        let islands = speechIslands(frameDB)
        let flacName = String(format: "%04d-%@.flac", chunk.index, chunk.track.rawValue)
        let flacURL = chunk.pcmURL.deletingLastPathComponent().appendingPathComponent(flacName)
        try writeFLAC(samples, to: flacURL)
        try? FileManager.default.removeItem(at: chunk.pcmURL)

        let relative = flacURL.path.replacingOccurrences(of: meetingFolder.path + "/", with: "")
        return Output(track: chunk.track, index: chunk.index,
                      start: Double(chunk.startSample) / rate,
                      duration: Double(samples.count) / rate,
                      file: relative,
                      speechSeconds: islands.reduce(0) { $0 + ($1.end - $1.start) },
                      islands: islands)
    }

    /// Energy of each 20 ms frame (dBFS), as the writer computes it while recording.
    static func frameEnergies(_ samples: [Int16]) -> [Float] {
        let n = TrackWriter.frameSamples
        return stride(from: 0, to: samples.count, by: n).map { offset in
            let frame = samples[offset..<min(offset + n, samples.count)]
            let sum = frame.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) }
            return Float(10 * log10(sum / Double(frame.count) + 1e-12))
        }
    }

    /// Rebuilds a chunk from audio left behind by a crash: a raw .pcm (preferred) or an already
    /// encoded .flac whose chunk never made it into meeting.json.
    static func recover(track: Track, index: Int, startSeconds: Double, audioFolder: URL, meetingFolder: URL,
                        mask: [ClosedRange<Double>]) -> Output? {
        let base = String(format: "%04d-%@", index, track.rawValue)
        let pcm = audioFolder.appendingPathComponent("\(base).pcm")
        if let samples = try? readPCM(pcm) {
            let chunk = ClosedChunk(track: track, index: index, pcmURL: pcm,
                                    startSample: Int64(startSeconds * TrackWriter.sampleRate),
                                    sampleCount: Int64(samples.count), frameDB: frameEnergies(samples))
            return try? finalize(chunk, mask: mask, meetingFolder: meetingFolder)
        }
        let flac = audioFolder.appendingPathComponent("\(base).flac")
        guard let file = try? AVAudioFile(forReading: flac, commonFormat: .pcmFormatInt16, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channel = buffer.int16ChannelData?[0] else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let islands = speechIslands(frameEnergies(samples))
        return Output(track: track, index: index, start: startSeconds, duration: Double(samples.count) / TrackWriter.sampleRate,
                      file: "audio/\(base).flac", speechSeconds: islands.reduce(0) { $0 + ($1.end - $1.start) }, islands: islands)
    }

    static func readPCM(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    static func writeFLAC(_ samples: [Int16], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: TrackWriter.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let block = 160_000
        var offset = 0
        while offset < samples.count {
            let n = min(block, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)),
                  let channel = buffer.int16ChannelData?[0] else { throw AudioCaptureError("Allocating an encode buffer") }
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress! + offset, count: n)
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            offset += n
        }
    }

    /// Finds speech from frame energies: frames well above the chunk's noise floor, merged across
    /// short pauses, ignoring blips, padded slightly.
    static func speechIslands(_ frameDB: [Float]) -> [SpeechIsland] {
        let frameSeconds = Double(TrackWriter.frameSamples) / TrackWriter.sampleRate
        let audible = frameDB.filter { $0 > -100 }.sorted()
        guard !audible.isEmpty else { return [] }
        let floor = audible[Int(Double(audible.count - 1) * 0.15)]
        let threshold = max(floor + 12, -50)

        var raw: [(Int, Int)] = []
        var runStart: Int?
        for (i, db) in frameDB.enumerated() {
            if db >= threshold {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                raw.append((s, i))
                runStart = nil
            }
        }
        if let s = runStart { raw.append((s, frameDB.count)) }

        let maxGap = Int(0.4 / frameSeconds)
        let minLength = Int(0.2 / frameSeconds)
        var merged: [(Int, Int)] = []
        for run in raw {
            if let last = merged.last, run.0 - last.1 <= maxGap {
                merged[merged.count - 1].1 = run.1
            } else {
                merged.append(run)
            }
        }
        let total = Double(frameDB.count) * frameSeconds
        return merged
            .filter { $0.1 - $0.0 >= minLength }
            .map { SpeechIsland(start: max(0, Double($0.0) * frameSeconds - 0.15),
                                end: min(total, Double($0.1) * frameSeconds + 0.15)) }
    }
}
