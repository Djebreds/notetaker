import Foundation

nonisolated enum NotesLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case english, meeting
    var id: String { rawValue }
    var label: String {
        switch self {
        case .english: "English"
        case .meeting: "Same as the meeting"
        }
    }
}

/// Who reads the notes; tailors them when filled in.
nonisolated struct ReaderProfile: Sendable, Equatable {
    var name: String
    var role: String
    var focus: String

    var isEmpty: Bool { [name, role, focus].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    static let none = ReaderProfile(name: "", role: "", focus: "")
}

nonisolated enum Prompts {
    // MARK: Transcription

    static let transcriptionSystem = """
    You are a meticulous meeting transcriber. Transcribe the audio clip exactly as spoken.

    Languages: the meeting is mostly in English, but speakers may switch to Indonesian, Malay or Sundanese, \
    sometimes in the middle of a sentence. Write every word in the language it was actually spoken, using that \
    language's normal spelling. Never translate. Never correct the speaker's grammar or word choice.

    Rules:
    - Verbatim, but drop pure filler sounds (um, uh, eh, hmm) and false starts that carry no meaning.
    - Mark words you cannot make out as [inaudible]. Do not guess names you cannot hear clearly.
    - If the clip contains no speech (silence, music, noise, typing), return an empty "segments" list. Never invent speech.
    - Start a new segment when the speaker changes or after a pause of about two seconds; keep segments under about 30 seconds.
    - "start" is when the segment begins, measured from the beginning of THIS clip, written as MM:SS.
    """

    static func transcriptionUser(track: Track, duration: Double, knownSpeakers: [String], previousLines: [String]) -> String {
        var text: String
        switch track {
        case .me:
            text = """
            This clip is the user's own microphone. Label every segment with the speaker "Me". \
            If other people can be heard faintly in the background (for example from laptop speakers), ignore them \
            and transcribe only the main, close voice.
            """
        case .others:
            text = """
            This clip is the meeting audio of the other participants; it never contains the user. Label each distinct \
            voice consistently as "Speaker 1", "Speaker 2", and so on. Never use names as labels, even when people \
            address each other by name: voices are matched to people separately.
            """
            let named = knownSpeakers.filter { $0 != "Me" }
            if !named.isEmpty {
                text += "\nSpeakers identified earlier in this meeting: \(named.joined(separator: ", ")). Reuse these labels for the same voices."
            }
        }
        text += "\nThe clip is \(Int(duration) / 60) min \(Int(duration) % 60) s long."
        if !previousLines.isEmpty {
            text += "\n\nFor context only (do not repeat), the conversation just before this clip was:\n" + previousLines.joined(separator: "\n")
        }
        return text
    }

    static var transcriptSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "segments": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "start": ["type": "string", "description": "Start time from the beginning of this clip, MM:SS"],
                        "speaker": ["type": "string"],
                        "text": ["type": "string"],
                    ],
                    "required": ["start", "speaker", "text"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["segments"],
        "additionalProperties": false,
    ] }

    // MARK: Notes

    static func notesSystem(language: NotesLanguage, profile: ReaderProfile = .none) -> String {
        let languageLine = language == .english
            ? "Write the notes in English."
            : "Write the notes in the language most of the meeting was held in."
        let intro = """
        You turn meeting transcripts into clear, accurate notes.

        Transcript lines look like "[HH:MM:SS] Speaker: text". "Me" is the person who recorded the meeting and will \
        read these notes. Other speakers are named or labelled "Speaker 1", "Speaker 2", and so on (labels can be \
        inconsistent across the meeting; use context to tell people apart). The meeting is mostly in English but may \
        include Indonesian, Malay or Sundanese; understand all of them. \(languageLine)
        """
        let common = """
        - Base everything strictly on the transcript. Do not invent facts, owners or dates.
        - Speaker labels come from on-device voice recognition: a name means the voice was recognised as that \
        person; "Speaker 2" is a voice not named yet. Use other names only when the conversation makes it clear (for \
        example, someone addressed by name agrees to a task); never claim that a "Speaker N" is a particular person.
        - Lines like "[audio missing 00:10:00–00:15:00]" mark parts that could not be transcribed. Don't guess what \
        was said there.
        - If nothing substantive was discussed (only greetings, setup or silence), say so in the summary and leave the \
        lists empty.
        - title: a short, specific title of at most 8 words (not a generic "Team meeting").
        - discussion: the meeting's topics in the order they came up. Each topic gets a short heading named after the \
        actual project, feature, client or issue, and 2 to 6 points with the substance: facts, numbers, options \
        considered, concerns raised and by whom. Longer meetings get more topics and more detail; skip small talk.
        """
        let closing = """
        - participants: names of the people who spoke or were addressed, including "Me".
        The transcript may contain recognition errors; prefer the most plausible reading in context.
        """
        guard !profile.isEmpty else {
            return intro + "\n\n" + common + "\n" + """
            - summary: 3 to 5 sentences on the purpose, the main discussion and the outcome.
            - keyPoints: the important points discussed, one sentence each.
            - decisions: only what was explicitly agreed or decided, not proposals or ideas that were merely discussed; \
            empty if none.
            - actionItems: concrete follow-ups. owner is the person who took the task on (not whoever raised it): "Me" \
            when it is the reader, or "" if unclear; due is the deadline exactly as said, or ""
            - openQuestions: questions or issues left unresolved.
            """ + "\n" + closing
        }

        var about: [String] = []
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = profile.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let focus = profile.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            about.append("Name: \(name). Other speakers may address them by this name (or a nickname); whatever they are asked to do is theirs.")
        }
        if !role.isEmpty { about.append("Role: \(role).") }
        if !focus.isEmpty { about.append("Focus: \(focus).") }
        let roleWords = role.isEmpty ? "the reader" : "someone in the reader's role (\(role))"
        return intro + "\n\nAbout the reader (\"Me\" in the transcript):\n" + about.joined(separator: "\n") + "\n\n"
            + "The notes are for this reader. Keep the summary general; write everything else from their point of view.\n\n"
            + common + "\n" + """
            - summary: 3 to 5 sentences giving a neutral overview of the whole meeting (purpose, main discussion, \
            outcome), the same for any participant. Do not tailor it to the reader.
            - keyPoints: the points that matter to \(roleWords), most relevant first: the details of their work, \
            systems, scope, timelines, risks and dependencies. Skip points that don't touch their work unless they are \
            central to the meeting.
            - decisions: only what was explicitly agreed or decided, not proposals or ideas that were merely discussed. \
            When one affects the reader's work, say how in a few words. Empty if none.
            - actionItems: the owner is the person who took the task on (not whoever raised it). First the reader's own \
            tasks (owner "Me"), each phrased as a concrete next step for \
            \(roleWords) (for a software engineer: what to build, fix, investigate, review, test or deploy). Then tasks \
            of others that the reader depends on or must follow up on, with their owner. Leave out tasks unrelated to \
            the reader. due is the deadline exactly as said, or "".
            - openQuestions: what the reader should clarify or follow up on from their role's perspective: unclear \
            requirements, unknowns, risks, blockers and dependencies, including questions they should ask.
            """ + "\n" + closing
    }

    static func notesUser(meetingLine: String, customInstructions: String, transcript: String) -> String {
        var text = meetingLine
        let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { text += "\n\nAdditional instructions from the reader: \(custom)" }
        text += "\n\nTranscript:\n\(transcript)"
        return text
    }

    static var notesSchema: [String: Any] {
        let strings: [String: Any] = ["type": "array", "items": ["type": "string"]]
        return [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "summary": ["type": "string"],
                "discussion": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["topic": ["type": "string"], "points": strings],
                        "required": ["topic", "points"],
                        "additionalProperties": false,
                    ],
                ],
                "keyPoints": strings,
                "decisions": strings,
                "actionItems": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "task": ["type": "string"],
                            "owner": ["type": "string"],
                            "due": ["type": "string"],
                        ],
                        "required": ["task", "owner", "due"],
                        "additionalProperties": false,
                    ],
                ],
                "openQuestions": strings,
                "participants": strings,
            ],
            "required": ["title", "summary", "discussion", "keyPoints", "decisions", "actionItems", "openQuestions", "participants"],
            "additionalProperties": false,
        ]
    }
}
