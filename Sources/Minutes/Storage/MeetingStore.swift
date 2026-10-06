import AppKit
import Foundation
import Observation

/// Meetings on disk, one folder each under Application Support/Minutes/meetings:
///
///     meeting.json                 metadata, chunk states, mute timeline, cost
///     transcript.json              merged transcript
///     notes.json, notes.md         structured notes and their Markdown
///     raw/0001-others.json         per-chunk model output (chunk-relative times)
///     audio/0001-me.flac …         the recording, until retention deletes it
@MainActor @Observable
final class MeetingStore {
    private(set) var meetings: [Meeting] = []

    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    @ObservationIgnored private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        Paths.ensure(Paths.meetings)
        load()
    }

    func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: nil)) ?? []
        meetings = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func folder(_ meeting: Meeting) -> URL { Paths.meetings.appendingPathComponent(meeting.folder, isDirectory: true) }

    func folder(for id: UUID) -> URL? { meeting(id).map(folder) }

    func create(appID: String?, appName: String?, trigger: Trigger) -> Meeting {
        let now = Date()
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let id = UUID()
        let folderName = "\(stamp)-\(id.uuidString.prefix(6).lowercased())"
        let title = (appName.map { "\($0) call" } ?? "Meeting") + " · " + now.formatted(date: .abbreviated, time: .shortened)
        let meeting = Meeting(id: id, folder: folderName, title: title, appID: appID, appName: appName,
                              trigger: trigger, startedAt: now, status: .recording)
        Paths.ensure(Paths.meetings.appendingPathComponent(folderName, isDirectory: true))
        meetings.insert(meeting, at: 0)
        save(meeting)
        return meeting
    }

    /// Mutates a meeting and writes meeting.json.
    @discardableResult
    func update(_ id: UUID, _ change: (inout Meeting) -> Void) -> Meeting? {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return nil }
        change(&meetings[index])
        save(meetings[index])
        return meetings[index]
    }

    func delete(_ id: UUID) {
        guard let meeting = meeting(id) else { return }
        let url = folder(meeting)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
        meetings.removeAll { $0.id == id }
    }

    /// Removes a meeting that was discarded right after recording (no Trash).
    func discard(_ id: UUID) {
        guard let meeting = meeting(id) else { return }
        try? FileManager.default.removeItem(at: folder(meeting))
        meetings.removeAll { $0.id == id }
    }

    // MARK: Transcript, notes, raw chunk results

    func transcript(_ id: UUID) -> [TranscriptSegment] {
        guard let url = folder(for: id)?.appendingPathComponent("transcript.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([TranscriptSegment].self, from: data)) ?? []
    }

    func saveTranscript(_ segments: [TranscriptSegment], for id: UUID) {
        guard let url = folder(for: id)?.appendingPathComponent("transcript.json") else { return }
        write(segments, to: url)
        touch(id)
    }

    func notes(_ id: UUID) -> MeetingNotes? {
        guard let url = folder(for: id)?.appendingPathComponent("notes.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(MeetingNotes.self, from: data)
    }

    func saveNotes(_ notes: MeetingNotes, for id: UUID) {
        guard let meeting = meeting(id) else { return }
        let dir = folder(meeting)
        write(notes, to: dir.appendingPathComponent("notes.json"))
        let md = MarkdownExporter.markdown(meeting: meeting, notes: notes, transcript: transcript(id), includeTranscript: true)
        try? md.write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        touch(id)
    }

    func speakers(_ id: UUID) -> SpeakerAnalysis? {
        guard let url = folder(for: id)?.appendingPathComponent("speakers.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SpeakerAnalysis.self, from: data)
    }

    func saveSpeakers(_ analysis: SpeakerAnalysis, for id: UUID) {
        guard let url = folder(for: id)?.appendingPathComponent("speakers.json") else { return }
        write(analysis, to: url)
        touch(id)
    }

    func raw(_ id: UUID, chunk: Int, track: Track) -> [RawSegment]? {
        guard let url = folder(for: id)?.appendingPathComponent("raw/\(String(format: "%04d", chunk))-\(track.rawValue).json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode([RawSegment].self, from: data)
    }

    func saveRaw(_ segments: [RawSegment], for id: UUID, chunk: Int, track: Track) {
        guard let dir = folder(for: id) else { return }
        let rawDir = Paths.ensure(dir.appendingPathComponent("raw", isDirectory: true))
        write(segments, to: rawDir.appendingPathComponent("\(String(format: "%04d", chunk))-\(track.rawValue).json"))
    }

    /// All raw results of a meeting, keyed by chunk and track.
    func allRaw(_ meeting: Meeting) -> [Int: [Track: [RawSegment]]] {
        var result: [Int: [Track: [RawSegment]]] = [:]
        for chunk in meeting.chunks {
            for track in Track.allCases {
                if let segments = raw(meeting.id, chunk: chunk.index, track: track) { result[chunk.index, default: [:]][track] = segments }
            }
        }
        return result
    }

    /// Changes whenever a transcript or notes file is written, so open views reload them.
    private(set) var lastChange = Date()
    private func touch(_ id: UUID) { lastChange = Date() }

    // MARK: Audio retention

    func applyRetention(_ retention: AudioRetention) {
        guard let days = retention.days else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for meeting in meetings where !meeting.audioDeleted && meeting.status == .done && (meeting.endedAt ?? meeting.startedAt) < cutoff {
            deleteAudio(meeting.id)
        }
    }

    func deleteAudio(_ id: UUID) {
        guard let meeting = meeting(id) else { return }
        try? FileManager.default.removeItem(at: folder(meeting).appendingPathComponent("audio", isDirectory: true))
        update(id) { m in
            m.audioDeleted = true
            for i in m.chunks.indices {
                m.chunks[i].me.file = nil
                m.chunks[i].others.file = nil
            }
        }
        Log.info("Deleted audio of \(meeting.folder)", "store")
    }

    func revealInFinder(_ id: UUID) {
        guard let url = folder(for: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Private

    private func save(_ meeting: Meeting) {
        write(meeting, to: folder(meeting).appendingPathComponent("meeting.json"))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            Log.error("Writing \(url.lastPathComponent) failed: \(error.localizedDescription)", "store")
        }
    }
}
