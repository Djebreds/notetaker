import Foundation

/// Turns a merged transcript into structured notes with a text model on OpenRouter.
nonisolated struct NotesGenerator: Sendable {
    let client: OpenRouterClient
    let model: String
    let zeroRetention: Bool

    struct Context: Sendable {
        let date: Date
        let appName: String?
        let duration: TimeInterval
        let language: NotesLanguage
        let customInstructions: String
        var profile: ReaderProfile = .none
        var gaps: [ClosedRange<Double>] = []
    }

    func generate(transcript: [TranscriptSegment], context: Context) async throws -> (notes: MeetingNotes, cost: Double) {
        guard !transcript.isEmpty else {
            return (MeetingNotes(title: "Untitled meeting", summary: "No speech was captured in this recording.",
                                 discussion: [], keyPoints: [], decisions: [], actionItems: [], openQuestions: [],
                                 participants: []), 0)
        }
        let date = context.date.formatted(date: .complete, time: .shortened)
        let minutes = Int((context.duration / 60).rounded())
        let meetingLine = "Meeting on \(date), about \(minutes) min" + (context.appName.map { ", held on \($0)." } ?? ".")
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 8_000,
            "messages": [
                ["role": "system", "content": Prompts.notesSystem(language: context.language, profile: context.profile)],
                ["role": "user", "content": Prompts.notesUser(meetingLine: meetingLine,
                                                              customInstructions: context.customInstructions,
                                                              transcript: TranscriptMerger.plainText(transcript, gaps: context.gaps))],
            ],
            "response_format": ["type": "json_schema", "json_schema": [
                "name": "meeting_notes", "strict": true, "schema": Prompts.notesSchema,
            ]],
            "provider": OpenRouterClient.providerPreferences(zeroRetention: zeroRetention, urgent: true),
        ]
        let result = try await client.chat(JSONSerialization.data(withJSONObject: body))
        guard let data = JSONText.extractObject(result.content).data(using: .utf8),
              var notes = try? JSONDecoder().decode(MeetingNotes.self, from: data) else {
            throw OpenRouterError(kind: .invalidResponse, message: "The notes were not valid JSON.")
        }
        notes.actionItems = notes.actionItems.map {
            ActionItem(task: $0.task, owner: $0.owner?.nilIfBlank, due: $0.due?.nilIfBlank)
        }
        return (notes, result.cost)
    }
}

extension String {
    nonisolated var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
