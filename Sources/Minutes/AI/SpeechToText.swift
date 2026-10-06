import Foundation

/// Transcribes with a dedicated speech-to-text model through OpenRouter's /audio/transcriptions
/// (MAI-Transcribe 2 by default): word-accurate timings and speaker diarization, no prompt.
nonisolated struct OpenRouterSTTTranscriber: Transcriber {
    let client: OpenRouterClient
    let model: String
    let zeroRetention: Bool

    func transcribe(_ job: TranscriptionJob) async throws -> TranscriptionOutput {
        let audio = try Data(contentsOf: job.audioURL).base64EncodedString()
        var provider: [String: Any] = ["data_collection": "deny"]
        if zeroRetention { provider["zdr"] = true }
        // Only the serving provider's options are forwarded. Diarization also gives Azure (MAI-Transcribe)
        // phrase-level timings; without it a clip comes back as one segment spanning the whole file.
        provider["options"] = [
            "azure": ["diarization": ["enabled": true]],
            "deepgram": ["diarize": true, "smart_format": true],
        ]
        let body: [String: Any] = [
            "model": model,
            "input_audio": ["data": audio, "format": job.audioURL.pathExtension.lowercased()],
            "response_format": "verbose_json",
            "timestamp_granularities": ["segment", "word"],
            "provider": provider,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let started = Date()
        let response = try await STTGate.shared.run { try await client.transcription(data) }
        let segments = Self.segments(from: response, track: job.track, duration: job.duration)
        return TranscriptionOutput(segments: segments, cost: response.usage?.cost ?? 0, model: model, provider: nil,
                                   seconds: Date().timeIntervalSince(started))
    }

    /// Provider segments → our segments. Starts come from the first word (exact), long monologues are
    /// split into sentences, and speaker ids become "Speaker 1, 2…" in order of appearance ("Me" on the mic).
    static func segments(from response: STTResponse, track: Track, duration: Double) -> [RawSegment] {
        let words = (response.words ?? []).compactMap { w -> (text: String, start: Double, end: Double, speaker: String?)? in
            guard let text = w.word?.trimmingCharacters(in: .whitespaces), !text.isEmpty, let start = w.start else { return nil }
            return (text, start, w.end ?? start, w.speaker?.value)
        }
        var pieces: [(start: Double, text: String, speaker: String?)] = []
        let sourceSegments = response.segments ?? []
        if sourceSegments.isEmpty {
            if let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                pieces.append((words.first?.start ?? 0, text, nil))
            }
        }
        for segment in sourceSegments {
            guard let text = segment.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let start = segment.start ?? 0, end = segment.end ?? start
            let inside = words.filter { $0.start >= start - 0.5 && $0.start <= end + 0.5 }
            if end - start > 12, inside.count > 8 {
                pieces += sentences(inside).map { ($0.start, $0.text, segment.speaker?.value) }
            } else {
                pieces.append((inside.first?.start ?? start, text, segment.speaker?.value))
            }
        }

        var labels: [String: String] = [:]
        return pieces.map { piece in
            let speaker: String
            if track == .me {
                speaker = "Me"
            } else if let id = piece.speaker {
                if labels[id] == nil { labels[id] = "Speaker \(labels.count + 1)" }
                speaker = labels[id]!
            } else {
                speaker = "Speaker 1"
            }
            return RawSegment(start: min(max(0, piece.start), duration), speaker: speaker, text: piece.text)
        }
        .sorted { $0.start < $1.start }
    }

    /// Groups words into sentences (ending in . ? ! …) or at pauses over 1.5 s.
    private static func sentences(_ words: [(text: String, start: Double, end: Double, speaker: String?)]) -> [(start: Double, text: String)] {
        var result: [(start: Double, text: String)] = []
        var current: [String] = []
        var currentStart = 0.0
        var lastEnd = 0.0
        for word in words {
            if !current.isEmpty, word.start - lastEnd > 1.5 {
                result.append((currentStart, current.joined(separator: " ")))
                current = []
            }
            if current.isEmpty { currentStart = word.start }
            current.append(word.text)
            lastEnd = word.end
            if let last = word.text.last, ".?!…。".contains(last) {
                result.append((currentStart, current.joined(separator: " ")))
                current = []
            }
        }
        if !current.isEmpty { result.append((currentStart, current.joined(separator: " "))) }
        return result
    }
}

/// Speech-to-text providers in preview (MAI-Transcribe on Azure) rate-limit bursts, so requests go
/// out one at a time, at least two seconds apart.
actor STTGate {
    static let shared = STTGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastStart = Date.distantPast

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        let wait = 2 - Date().timeIntervalSince(lastStart)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        lastStart = Date()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

nonisolated enum TranscriberFactory {
    /// Dedicated speech-to-text models use /audio/transcriptions; everything else is an audio-capable chat model.
    static func make(model: String, client: OpenRouterClient, zeroRetention: Bool) -> any Transcriber {
        isSpeechToText(model)
            ? OpenRouterSTTTranscriber(client: client, model: model, zeroRetention: zeroRetention)
            : OpenRouterTranscriber(client: client, model: model, zeroRetention: zeroRetention)
    }

    /// Whether the model tells speakers apart with our request settings. Chat models do it from the
    /// prompt; among speech-to-text models only those whose diarization option we send.
    static func labelsSpeakers(_ model: String) -> Bool {
        guard isSpeechToText(model) else { return true }
        let id = model.lowercased()
        return id.contains("mai-transcribe-2") || id.hasPrefix("deepgram/")
    }

    static func isSpeechToText(_ model: String) -> Bool {
        let id = model.lowercased()
        return ["transcribe", "whisper", "-asr", "-stt", "nova-3", "parakeet", "chirp", "universal-3"].contains { id.contains($0) }
    }
}
