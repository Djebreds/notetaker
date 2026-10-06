import Foundation

nonisolated struct TranscriptionJob: Sendable {
    let audioURL: URL
    let track: Track
    let duration: Double
    let knownSpeakers: [String]
    let previousLines: [String]
    /// The user is waiting (the call has ended): skip the slower flex tier.
    let urgent: Bool
}

nonisolated struct TranscriptionOutput: Sendable {
    let segments: [RawSegment]
    let cost: Double
    let model: String
    let provider: String?
    let seconds: Double
}

/// Speech-to-text engines. OpenRouter's audio-capable chat models today; an on-device Apple engine can
/// be added later behind the same protocol.
nonisolated protocol Transcriber: Sendable {
    func transcribe(_ job: TranscriptionJob) async throws -> TranscriptionOutput
}

/// Transcribes a FLAC clip with an audio-capable chat model on OpenRouter (Gemini Flash-Lite by default),
/// asking for JSON segments with MM:SS start times.
nonisolated struct OpenRouterTranscriber: Transcriber {
    let client: OpenRouterClient
    let model: String
    let zeroRetention: Bool

    func transcribe(_ job: TranscriptionJob) async throws -> TranscriptionOutput {
        let audio = try Data(contentsOf: job.audioURL).base64EncodedString()
        let format = job.audioURL.pathExtension.lowercased()
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": 16_000,
            "messages": [
                ["role": "system", "content": Prompts.transcriptionSystem],
                ["role": "user", "content": [
                    ["type": "text", "text": Prompts.transcriptionUser(track: job.track, duration: job.duration,
                                                                       knownSpeakers: job.knownSpeakers,
                                                                       previousLines: job.previousLines)],
                    ["type": "input_audio", "input_audio": ["data": audio, "format": format]],
                ]],
            ],
            "response_format": ["type": "json_schema", "json_schema": [
                "name": "transcript", "strict": true, "schema": Prompts.transcriptSchema,
            ]],
            // "low" rather than "minimal": steadier on accented speech in tests, at about the same cost.
            "reasoning": ["effort": "low"],
            "provider": OpenRouterClient.providerPreferences(zeroRetention: zeroRetention, urgent: job.urgent),
        ]

        var result: ChatResult
        do {
            result = try await client.chat(JSONSerialization.data(withJSONObject: body))
        } catch let error as OpenRouterError where error.kind == .badRequest {
            // Some models reject a reasoning setting; retry once without it.
            Log.warn("Transcription request rejected (\(error.message)); retrying without reasoning setting", "ai")
            body["reasoning"] = nil
            result = try await client.chat(JSONSerialization.data(withJSONObject: body))
        }

        let segments = try Self.parse(result.content, duration: job.duration, track: job.track)
        return TranscriptionOutput(segments: segments, cost: result.cost, model: result.model ?? model,
                                   provider: result.provider, seconds: result.seconds)
    }

    /// Parses and sanity-checks the model's JSON.
    static func parse(_ content: String, duration: Double, track: Track) throws -> [RawSegment] {
        struct Payload: Decodable {
            struct Segment: Decodable { let start: String?; let speaker: String?; let text: String? }
            let segments: [Segment]
        }
        let json = JSONText.extractObject(content)
        guard let data = json.data(using: .utf8), let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw OpenRouterError(kind: .invalidResponse, message: "The transcript was not valid JSON.")
        }
        var segments: [RawSegment] = payload.segments.compactMap { s in
            let text = (s.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = min(max(0, Timecode.seconds(s.start ?? "0") ?? 0), duration)
            var speaker = (s.speaker ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if track == .me || speaker.isEmpty { speaker = track == .me ? "Me" : "Speaker" }
            return RawSegment(start: start, speaker: speaker, text: text)
        }
        segments.sort { $0.start < $1.start }

        // A model stuck in a loop repeats one line over and over.
        if segments.count >= 6 {
            let counts = Dictionary(grouping: segments, by: { AX.normalize($0.text) }).mapValues(\.count)
            if let top = counts.values.max(), Double(top) > Double(segments.count) * 0.5 {
                throw OpenRouterError(kind: .invalidResponse, message: "The transcript repeated itself (model loop).")
            }
        }
        return segments
    }
}

nonisolated enum Timecode {
    /// "MM:SS", "M:SS", "H:MM:SS", "SS" or "MM:SS.s" → seconds.
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// Seconds → "HH:MM:SS".
    static func format(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.rounded()))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

nonisolated enum JSONText {
    /// Strips code fences or prose around a JSON object.
    static func extractObject(_ text: String) -> String {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last else { return text }
        return String(text[first...last])
    }
}
