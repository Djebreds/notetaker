import AVFAudio
import FluidAudio
import Foundation

/// On-device speaker diarization of a meeting's "others" track with FluidAudio (CoreML, Neural Engine).
/// Models (~22 MB, CC-BY-4.0) download once from Hugging Face into
/// ~/Library/Application Support/FluidAudio/Models and stay cached in memory while the app runs.
actor SpeakerIdentifier {
    static let shared = SpeakerIdentifier()
    static let modelName = "fluidaudio-offline-256"

    private var models: OfflineDiarizerModels?

    /// Who spoke when across the whole meeting audio.
    /// - Parameters:
    ///   - chunks: each others-track FLAC chunk with its start (seconds from meeting start)
    ///   - duration: meeting length covered by the chunks
    ///   - expectedSpeakers: exact speaker count when the user set one (automatic otherwise)
    func analyze(chunks: [(start: Double, url: URL)], duration: Double, expectedSpeakers: Int?) async throws -> SpeakerAnalysis {
        let rate = 16_000.0
        var audio = [Float](repeating: 0, count: Int(duration * rate) + 1)
        for chunk in chunks {
            let samples = try Self.decode(chunk.url)
            let offset = Int(chunk.start * rate)
            guard offset < audio.count else { continue }
            let n = min(samples.count, audio.count - offset)
            audio.replaceSubrange(offset..<(offset + n), with: samples[0..<n])
        }
        // Exact digital silence (nothing playing, gaps between parts) makes the diarizer invent speakers
        // (FluidAudio #981); a noise floor far below hearing avoids it.
        var seed: UInt32 = 0x9E37_79B9
        for i in audio.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            audio[i] += (Float(seed >> 8) / Float(1 << 24) - 0.5) * 6e-4
        }

        var config = OfflineDiarizerConfig.default
        if let expectedSpeakers { config = config.withSpeakers(exactly: expectedSpeakers) }
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: try await loadedModels())
        let started = Date()
        let result = try await manager.process(audio: audio)
        Log.info(String(format: "Speaker recognition: %d turns, %d voices in %.1f s for %.0f min of audio",
                        result.segments.count, result.speakerDatabase?.count ?? 0, Date().timeIntervalSince(started),
                        duration / 60), "speakers")

        let turns = result.segments
            .map { SpeakerTurn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId) }
            .sorted { $0.start < $1.start }
        var seconds: [String: Double] = [:]
        for turn in turns { seconds[turn.speaker, default: 0] += turn.end - turn.start }
        let speakers = (result.speakerDatabase ?? [:]).map { id, vector in
            MeetingSpeaker(id: id, embedding: Voiceprint.normalized(vector), seconds: seconds[id] ?? 0)
        }
        .filter { $0.seconds > 0 }
        .sorted { $0.seconds > $1.seconds }
        return SpeakerAnalysis(turns: turns, speakers: speakers, expectedCount: expectedSpeakers,
                               chunkCount: chunks.count, model: Self.modelName)
    }

    private func loadedModels() async throws -> OfflineDiarizerModels {
        if let models { return models }
        let loaded = try await OfflineDiarizerModels.load()
        models = loaded
        return loaded
    }

    private static func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioCaptureError("Can't read \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        if file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
           let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        guard let converted = Resampler().convert(buffer), let channel = converted.floatChannelData?[0] else {
            throw AudioCaptureError("Can't convert \(url.lastPathComponent)")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }
}

nonisolated enum Voiceprint {
    static func normalized(_ v: [Float]) -> [Float] {
        let norm = max(v.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
        return v.map { $0 / norm }
    }

    /// Cosine similarity of two normalised voiceprints.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return dot
    }

    /// Weighted update of a stored voiceprint with a new sample (0.7 old, 0.3 new), re-normalised.
    static func blend(_ old: [Float], _ new: [Float], weight: Float = 0.3) -> [Float] {
        guard old.count == new.count else { return new }
        return normalized(zip(old, new).map { (1 - weight) * $0 + weight * $1 })
    }
}
