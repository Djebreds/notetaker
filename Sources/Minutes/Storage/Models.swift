import Foundation

/// Which side of the call an audio stream carries.
nonisolated enum Track: String, Codable, Sendable, CaseIterable {
    case me      // the user's microphone
    case others  // everything apps play (the remote participants)
}

nonisolated enum MeetingStatus: String, Codable, Sendable {
    case recording, transcribing, summarizing, done, failed
}

nonisolated enum Trigger: String, Codable, Sendable {
    case auto, manual
}

/// A stretch of detected speech, in seconds relative to the start of its chunk.
nonisolated struct SpeechIsland: Codable, Sendable, Hashable {
    var start: Double
    var end: Double
}

nonisolated enum ChunkTrackState: String, Codable, Sendable {
    case pending, skipped, transcribing, done, failed
}

/// One track of one chunk: the encoded audio file and its transcription state.
nonisolated struct TrackChunk: Codable, Sendable {
    var track: Track
    /// Path relative to the meeting folder, e.g. "audio/0001-me.flac". Nil once audio is deleted.
    var file: String?
    var speechSeconds: Double
    var islands: [SpeechIsland]
    var state: ChunkTrackState
    var attempts: Int = 0
    var error: String?
    /// Seconds of speaker bleed silenced on the mic track (diagnostics).
    var bleedSeconds: Double?
}

/// A ~5-minute slice of the meeting; both tracks share the same boundaries.
nonisolated struct ChunkRecord: Codable, Sendable, Identifiable {
    var index: Int
    /// Seconds from meeting start.
    var start: Double
    var duration: Double
    var me: TrackChunk
    var others: TrackChunk

    var id: Int { index }

    subscript(track: Track) -> TrackChunk {
        get { track == .me ? me : others }
        set { if track == .me { me = newValue } else { others = newValue } }
    }
}

nonisolated enum MuteSource: String, Codable, Sendable {
    case app            // read from the meeting app's own mute control
    case notCapturing   // the meeting app wasn't using the microphone at all
    case manual         // the user's "exclude my mic" hotkey
}

/// A period (seconds from meeting start) during which the user's mic is left out.
nonisolated struct MuteInterval: Codable, Sendable, Hashable {
    var start: Double
    var end: Double?
    var source: MuteSource
}

/// A transcribed line as returned for one chunk; `start` is relative to that chunk.
nonisolated struct RawSegment: Codable, Sendable, Hashable {
    var start: Double
    var speaker: String
    var text: String
}

/// A merged transcript line; times are seconds from meeting start.
nonisolated struct TranscriptSegment: Codable, Sendable, Hashable, Identifiable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
    var track: Track
    /// The voice this line was assigned to by speaker recognition ("S1"…), on the others track.
    var speakerID: String?

    var id: String { "\(track.rawValue)-\(start)-\(speaker)" }
}

/// A stretch of one voice in the meeting audio (seconds from meeting start).
nonisolated struct SpeakerTurn: Codable, Sendable, Hashable {
    var start: Double
    var end: Double
    var speaker: String
}

/// A voice found in a meeting's audio.
nonisolated struct MeetingSpeaker: Codable, Sendable, Hashable, Identifiable {
    var id: String
    /// Confirmed name: typed by the user, or a close voice match to a known person.
    var name: String?
    /// A possible match to a known voice, not yet confirmed.
    var suggestion: String?
    var profileID: UUID?
    /// The user named this voice in this meeting (never replaced by automatic matching).
    var confirmed: Bool = false
    /// L2-normalised voiceprint.
    var embedding: [Float]
    var seconds: Double
}

/// Who spoke when in the meeting audio, from on-device speaker recognition.
nonisolated struct SpeakerAnalysis: Codable, Sendable {
    var turns: [SpeakerTurn]
    var speakers: [MeetingSpeaker]
    /// Speaker count the user asked for; nil = automatic.
    var expectedCount: Int?
    /// Chunks covered; a resumed meeting with more chunks is analysed again.
    var chunkCount: Int
    var model: String

    func speaker(_ id: String) -> MeetingSpeaker? { speakers.first { $0.id == id } }
}

nonisolated struct ActionItem: Codable, Sendable, Hashable {
    var task: String
    var owner: String?
    var due: String?
}

nonisolated struct DiscussionTopic: Codable, Sendable, Hashable {
    var topic: String
    var points: [String]
}

nonisolated struct MeetingNotes: Codable, Sendable {
    var title: String
    var summary: String
    /// The meeting's topics in order, with their substance (absent in notes written before it existed).
    var discussion: [DiscussionTopic]?
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]
    var participants: [String]
}

nonisolated struct Meeting: Codable, Sendable, Identifiable {
    var id: UUID
    /// Folder name under Application Support/Minutes/meetings.
    var folder: String
    var title: String
    var titleEdited: Bool = false
    var appID: String?
    var appName: String?
    var trigger: Trigger
    var startedAt: Date
    var endedAt: Date?
    var status: MeetingStatus
    var statusDetail: String?
    var chunks: [ChunkRecord] = []
    var mute: [MuteInterval] = []
    var transcriptionModel: String?
    var notesModel: String?
    var costUSD: Double = 0
    var audioDeleted: Bool = false
    /// Speaker names changed after the notes were written.
    var notesOutdated: Bool?

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    var isProcessing: Bool { status == .transcribing || status == .summarizing }

    /// e.g. "3/7" while chunks are being transcribed.
    var progressText: String? {
        let tracks = chunks.flatMap { [$0.me, $0.others] }
        guard !tracks.isEmpty else { return nil }
        let finished = tracks.filter { $0.state == .done || $0.state == .skipped || $0.state == .failed }.count
        return "\(finished)/\(tracks.count)"
    }

    var failedTrackCount: Int {
        chunks.reduce(0) { $0 + ($1.me.state == .failed ? 1 : 0) + ($1.others.state == .failed ? 1 : 0) }
    }
}
