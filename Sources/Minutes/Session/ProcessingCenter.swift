import Foundation
import Observation

/// Turns recorded chunks into a transcript and notes.
///
/// Chunks are transcribed while the call is still running (one at a time per track, both tracks in
/// parallel, so each request can carry the previous lines as context). When the recording ends and
/// every chunk is done, the merged transcript goes to the notes model.
@MainActor @Observable
final class ProcessingCenter {
    private final class Work {
        var pending: [Track: [Int]] = [.me: [], .others: []]
        var running: Set<Track> = []
        var expectedChunks: Int?
        var urgent = false
        var finalizing = false
    }

    private let store: MeetingStore
    private let settings: AppSettings
    private let voices: VoiceProfiles
    @ObservationIgnored private var work: [UUID: Work] = [:]
    /// The last problem worth telling the user about (bad key, no credits…).
    private(set) var lastProblem: String?

    var onNotesReady: ((Meeting) -> Void)?
    var onProblem: ((String) -> Void)?

    /// A chunk needs at least this much detected speech to be worth sending.
    static let minSpeechSeconds = 0.8

    init(store: MeetingStore, settings: AppSettings, voices: VoiceProfiles) {
        self.store = store
        self.settings = settings
        self.voices = voices
    }

    var activeMeetingIDs: Set<UUID> { Set(work.keys) }

    // MARK: - Entry points

    /// A new chunk of an ongoing (or just finished) recording, already stored in meeting.chunks.
    func enqueue(_ meetingID: UUID, chunk: ChunkRecord) {
        let w = work[meetingID] ?? Work()
        work[meetingID] = w
        for track in Track.allCases where chunk[track].state == .pending {
            if chunk[track].speechSeconds < Self.minSpeechSeconds || chunk[track].file == nil {
                setState(meetingID, chunk.index, track, chunk[track].file == nil ? .failed : .skipped)
            } else {
                w.pending[track, default: []].append(chunk.index)
            }
        }
        pump(meetingID)
    }

    /// The recording has ended after `expectedChunks` chunks: finish urgently, then write notes.
    func finish(_ meetingID: UUID, expectedChunks: Int) {
        let w = work[meetingID] ?? Work()
        work[meetingID] = w
        w.expectedChunks = expectedChunks
        w.urgent = true
        pump(meetingID)
    }

    func cancel(_ meetingID: UUID) { work[meetingID] = nil }

    /// A finished meeting is being recorded again (the same call came back): keep queued work, and
    /// let a notes run that is already under way finish without touching the meeting.
    func reopen(_ meetingID: UUID) {
        if let w = work[meetingID], !w.finalizing {
            w.expectedChunks = nil
            w.urgent = false
        } else {
            work[meetingID] = Work()
        }
    }

    func retryFailed(_ meetingID: UUID) {
        guard let meeting = store.meeting(meetingID) else { return }
        let w = Work()
        w.expectedChunks = meeting.chunks.count
        w.urgent = true
        work[meetingID] = w
        store.update(meetingID) { $0.status = .transcribing; $0.statusDetail = nil }
        for chunk in meeting.chunks {
            for track in Track.allCases where chunk[track].state == .failed && chunk[track].file != nil {
                setState(meetingID, chunk.index, track, .pending)
                w.pending[track, default: []].append(chunk.index)
            }
        }
        pump(meetingID)
    }

    /// Transcribes every recorded chunk again with the current model, then rewrites the notes.
    func retranscribe(_ meetingID: UUID) {
        guard work[meetingID] == nil, let meeting = store.meeting(meetingID), !meeting.audioDeleted else { return }
        try? FileManager.default.removeItem(at: store.folder(meeting).appendingPathComponent("raw", isDirectory: true))
        let w = Work()
        w.expectedChunks = meeting.chunks.count
        work[meetingID] = w
        store.update(meetingID) { m in
            m.status = .transcribing
            m.statusDetail = nil
            for i in m.chunks.indices {
                for track in Track.allCases where m.chunks[i][track].state != .skipped && m.chunks[i][track].file != nil {
                    m.chunks[i][track].state = .pending
                    m.chunks[i][track].attempts = 0
                    m.chunks[i][track].error = nil
                }
            }
        }
        guard let updated = store.meeting(meetingID) else { return }
        for chunk in updated.chunks {
            for track in Track.allCases where chunk[track].state == .pending { w.pending[track, default: []].append(chunk.index) }
        }
        Log.info("Re-transcribing \(meeting.folder) with \(settings.transcriptionModel)", "ai")
        pump(meetingID)
    }

    func regenerateNotes(_ meetingID: UUID) {
        guard work[meetingID] == nil else { return }
        let w = Work()
        w.finalizing = true
        work[meetingID] = w
        Task { await finalize(meetingID, w) }
    }

    /// After a crash or quit: rebuild chunks left on disk and continue where processing stopped.
    func resumeUnfinished() {
        for meeting in store.meetings {
            switch meeting.status {
            case .recording:
                recoverRecording(meeting)
            case .transcribing:
                resumeTranscription(meeting)
            case .summarizing:
                regenerateNotes(meeting.id)
            case .done, .failed:
                break
            }
        }
    }

    // MARK: - Scheduling

    private func pump(_ meetingID: UUID) {
        guard let w = work[meetingID], !w.finalizing else { return }
        for track in [Track.others, .me] where !w.running.contains(track) {
            guard let index = w.pending[track]?.first else { continue }
            w.pending[track]?.removeFirst()
            w.running.insert(track)
            Task {
                await transcribe(meetingID, index, track, urgent: w.urgent)
                w.running.remove(track)
                pump(meetingID)
            }
        }
        let idle = w.running.isEmpty && w.pending.values.allSatisfy(\.isEmpty)
        let chunks = store.meeting(meetingID)?.chunks.count ?? 0
        if idle, let expected = w.expectedChunks, chunks >= expected {
            w.finalizing = true
            Task { await finalize(meetingID, w) }
        }
    }

    private func transcribe(_ meetingID: UUID, _ index: Int, _ track: Track, urgent: Bool) async {
        guard let meeting = store.meeting(meetingID),
              let chunk = meeting.chunks.first(where: { $0.index == index }),
              let file = chunk[track].file else { return }
        let client: OpenRouterClient
        do {
            client = try OpenRouterClient.fromKeychain()
        } catch {
            fail(meetingID, index, track, error)
            return
        }
        store.update(meetingID) { m in
            if let i = m.chunks.firstIndex(where: { $0.index == index }) {
                m.chunks[i][track].state = .transcribing
                m.chunks[i][track].attempts += 1
            }
        }
        let transcript = store.transcript(meetingID)
        let previous = transcript.filter { $0.start < chunk.start }.suffix(8).map { "\($0.speaker): \($0.text)" }
        let speakers = Array(Set(transcript.filter { $0.track == .others }.map(\.speaker))).sorted()
        let job = TranscriptionJob(audioURL: store.folder(meeting).appendingPathComponent(file), track: track,
                                   duration: chunk.duration, knownSpeakers: speakers, previousLines: Array(previous),
                                   urgent: urgent)
        let transcriber = TranscriberFactory.make(model: settings.transcriptionModel, client: client,
                                                  zeroRetention: settings.zeroDataRetention)
        do {
            let output = try await Retry.run { try await Task.detached { try await transcriber.transcribe(job) }.value }
            store.saveRaw(output.segments, for: meetingID, chunk: index, track: track)
            store.update(meetingID) { m in
                if let i = m.chunks.firstIndex(where: { $0.index == index }) {
                    m.chunks[i][track].state = .done
                    m.chunks[i][track].error = nil
                }
                m.costUSD += output.cost
                m.transcriptionModel = output.model
            }
            Log.info("Transcribed chunk \(index) (\(track.rawValue)): \(output.segments.count) segments, $\(String(format: "%.5f", output.cost)), \(String(format: "%.1f", output.seconds)) s via \(output.provider ?? "?")", "ai")
            remerge(meetingID)
            lastProblem = nil
        } catch {
            fail(meetingID, index, track, error)
        }
    }

    private func fail(_ meetingID: UUID, _ index: Int, _ track: Track, _ error: Error) {
        Log.error("Chunk \(index) (\(track.rawValue)) failed: \(error.localizedDescription)", "ai")
        store.update(meetingID) { m in
            if let i = m.chunks.firstIndex(where: { $0.index == index }) {
                m.chunks[i][track].state = .failed
                m.chunks[i][track].error = error.localizedDescription
            }
        }
        if let e = error as? OpenRouterError, [.missingKey, .invalidKey, .noCredits].contains(e.kind), lastProblem != e.message {
            lastProblem = e.message
            onProblem?(e.message)
        }
    }

    private func finalize(_ meetingID: UUID, _ w: Work) async {
        defer { if work[meetingID] === w { work[meetingID] = nil } }
        guard let current = store.meeting(meetingID), current.status != .recording else { return }
        store.update(meetingID) { $0.status = .summarizing }
        if settings.recognizeSpeakers { await identifySpeakers(meetingID) }
        guard store.meeting(meetingID)?.status != .recording else { return }
        remerge(meetingID)
        guard let meeting = store.meeting(meetingID) else { return }
        let transcript = store.transcript(meetingID)
        do {
            let client = try OpenRouterClient.fromKeychain()
            let generator = NotesGenerator(client: client, model: settings.notesModel, zeroRetention: settings.zeroDataRetention)
            let context = NotesGenerator.Context(date: meeting.startedAt, appName: meeting.appName, duration: meeting.duration,
                                                 language: settings.notesLanguage, customInstructions: settings.customInstructions,
                                                 profile: settings.readerProfile, gaps: TranscriptMerger.gaps(in: meeting.chunks))
            let result = try await Retry.run {
                try await Task.detached { try await generator.generate(transcript: transcript, context: context) }.value
            }
            // Recording resumed meanwhile (the same call came back): its own run writes the notes.
            guard store.meeting(meetingID)?.status != .recording else { return }
            let failed = meeting.failedTrackCount
            store.update(meetingID) { m in
                m.status = .done
                m.statusDetail = failed > 0 ? "\(failed) part\(failed == 1 ? "" : "s") could not be transcribed. Use Retry." : nil
                m.costUSD += result.cost
                m.notesModel = self.settings.notesModel
                m.notesOutdated = nil
                if !m.titleEdited { m.title = result.notes.title }
            }
            store.saveNotes(result.notes, for: meetingID)
            Log.info("Notes ready for \(meeting.folder) ($\(String(format: "%.4f", result.cost)))", "ai")
            if settings.audioRetention == .afterNotes, failed == 0 { store.deleteAudio(meetingID) }
            if let done = store.meeting(meetingID) { onNotesReady?(done) }
        } catch {
            guard store.meeting(meetingID)?.status != .recording else { return }
            Log.error("Notes failed for \(meeting.folder): \(error.localizedDescription)", "ai")
            store.update(meetingID) { m in
                m.status = .failed
                m.statusDetail = "Notes could not be written: \(error.localizedDescription)"
            }
            if let e = error as? OpenRouterError, [.missingKey, .invalidKey, .noCredits].contains(e.kind) { onProblem?(e.message) }
        }
    }

    private func remerge(_ meetingID: UUID) {
        guard let meeting = store.meeting(meetingID) else { return }
        store.saveTranscript(TranscriptMerger.merge(chunks: meeting.chunks, raw: store.allRaw(meeting), mute: meeting.mute,
                                                    speakers: store.speakers(meetingID)),
                            for: meetingID)
    }

    // MARK: - Speakers

    /// Runs on-device speaker recognition over the meeting audio (unless it already covers every chunk
    /// with the same speaker count), then names voices from the known people.
    func identifySpeakers(_ meetingID: UUID, expectedCount: Int?? = nil, force: Bool = false) async {
        guard let meeting = store.meeting(meetingID), !meeting.audioDeleted else { return }
        let existing = store.speakers(meetingID)
        let count: Int? = expectedCount ?? existing?.expectedCount
        if !force, var existing, existing.chunkCount == meeting.chunks.count, existing.expectedCount == count {
            voices.apply(to: &existing)
            store.saveSpeakers(existing, for: meetingID)
            return
        }
        let folder = store.folder(meeting)
        let chunks = meeting.chunks.compactMap { c in c.others.file.map { (start: c.start, url: folder.appendingPathComponent($0)) } }
        guard !chunks.isEmpty else { return }
        let duration = meeting.chunks.map { $0.start + $0.duration }.max() ?? 0
        let previousDetail = meeting.statusDetail
        store.update(meetingID) { $0.statusDetail = "Recognising speakers…" }
        do {
            var analysis = try await SpeakerIdentifier.shared.analyze(chunks: chunks, duration: duration, expectedSpeakers: count)
            voices.apply(to: &analysis)
            store.saveSpeakers(analysis, for: meetingID)
        } catch {
            Log.error("Speaker recognition failed: \(error.localizedDescription)", "speakers")
        }
        store.update(meetingID) { $0.statusDetail = previousDetail }
    }

    /// Runs speaker recognition again with a fixed number of voices (nil = automatic).
    func reidentify(_ meetingID: UUID, count: Int?) {
        guard work[meetingID] == nil else { return }
        let w = Work()
        w.finalizing = true
        work[meetingID] = w
        Task {
            await identifySpeakers(meetingID, expectedCount: .some(count), force: true)
            remerge(meetingID)
            store.update(meetingID) { $0.notesOutdated = true }
            if work[meetingID] === w { work[meetingID] = nil }
        }
    }

    /// The user named a voice: remember it, relabel this meeting, and name matching voices elsewhere.
    func nameSpeaker(_ meetingID: UUID, speakerID: String, name: String) {
        guard var analysis = store.speakers(meetingID),
              let i = analysis.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            analysis.speakers[i].confirmed = false
            voices.apply(to: &analysis)
        } else {
            let profile = voices.learn(name: trimmed, embedding: analysis.speakers[i].embedding, model: analysis.model)
            analysis.speakers[i].name = profile.name
            analysis.speakers[i].profileID = profile.id
            analysis.speakers[i].suggestion = nil
            analysis.speakers[i].confirmed = true
            // The same person can't be another voice of this meeting.
            for j in analysis.speakers.indices where j != i && analysis.speakers[j].profileID == profile.id
                && !analysis.speakers[j].confirmed {
                analysis.speakers[j].name = nil
                analysis.speakers[j].profileID = nil
            }
        }
        store.saveSpeakers(analysis, for: meetingID)
        remerge(meetingID)
        store.update(meetingID) { $0.notesOutdated = true }
        relabelOtherMeetings(except: meetingID)
    }

    /// Applies the known voices to every other analysed meeting (e.g. after a new name was learned).
    private func relabelOtherMeetings(except meetingID: UUID) {
        for meeting in store.meetings where meeting.id != meetingID && !meeting.isProcessing && meeting.status != .recording {
            guard var analysis = store.speakers(meeting.id) else { continue }
            let before = analysis.speakers.map { "\($0.name ?? "")|\($0.suggestion ?? "")" }
            voices.apply(to: &analysis)
            guard analysis.speakers.map({ "\($0.name ?? "")|\($0.suggestion ?? "")" }) != before else { continue }
            store.saveSpeakers(analysis, for: meeting.id)
            remerge(meeting.id)
            store.update(meeting.id) { $0.notesOutdated = true }
            Log.info("Updated speaker names in \(meeting.folder)", "speakers")
        }
    }

    private func setState(_ meetingID: UUID, _ index: Int, _ track: Track, _ state: ChunkTrackState) {
        store.update(meetingID) { m in
            if let i = m.chunks.firstIndex(where: { $0.index == index }) { m.chunks[i][track].state = state }
        }
    }

    // MARK: - Recovery

    private func resumeTranscription(_ meeting: Meeting) {
        let w = Work()
        w.expectedChunks = meeting.chunks.count
        w.urgent = true
        work[meeting.id] = w
        for chunk in meeting.chunks {
            for track in Track.allCases where chunk[track].state == .pending || chunk[track].state == .transcribing {
                setState(meeting.id, chunk.index, track, .pending)
                if chunk[track].file != nil, chunk[track].speechSeconds >= Self.minSpeechSeconds {
                    w.pending[track, default: []].append(chunk.index)
                } else {
                    setState(meeting.id, chunk.index, track, chunk[track].file == nil ? .failed : .skipped)
                }
            }
        }
        Log.info("Resuming transcription of \(meeting.folder)", "ai")
        pump(meeting.id)
    }

    /// The app quit or crashed mid-recording: encode leftover raw audio into chunks, then continue.
    private func recoverRecording(_ meeting: Meeting) {
        let folder = store.folder(meeting)
        let audio = folder.appendingPathComponent("audio", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: audio.path)) ?? []
        let known = Set(meeting.chunks.map(\.index))
        let indices = Set(files.compactMap { Int($0.prefix(4)) }).subtracting(known).sorted()
        let timeline = MuteTimeline(meeting.mute)
        var start = meeting.chunks.map { $0.start + $0.duration }.max() ?? 0
        var recovered: [ChunkRecord] = []
        for index in indices {
            var outputs: [Track: ChunkEncoder.Output] = [:]
            for track in Track.allCases {
                let mask = track == .me
                    ? timeline.mask(from: start, to: start + 3_600).map { ($0.lowerBound - start)...($0.upperBound - start) }
                    : []
                outputs[track] = ChunkEncoder.recover(track: track, index: index, startSeconds: start, audioFolder: audio,
                                                      meetingFolder: folder, mask: mask)
            }
            let duration = outputs.values.map(\.duration).max() ?? 0
            guard duration > 0 else { continue }
            func trackChunk(_ track: Track) -> TrackChunk {
                guard let o = outputs[track] else {
                    return TrackChunk(track: track, file: nil, speechSeconds: 0, islands: [], state: .skipped)
                }
                return TrackChunk(track: track, file: o.file, speechSeconds: o.speechSeconds, islands: o.islands, state: .pending)
            }
            recovered.append(ChunkRecord(index: index, start: start, duration: duration, me: trackChunk(.me), others: trackChunk(.others)))
            start += duration
        }
        let ended = meeting.startedAt.addingTimeInterval(start)
        store.update(meeting.id) { m in
            m.chunks += recovered
            m.endedAt = m.endedAt ?? ended
            m.mute = m.mute.map { var i = $0; i.end = i.end ?? start; return i }
            m.status = .transcribing
            m.statusDetail = "Recovered after Minutes quit unexpectedly."
        }
        Log.info("Recovered \(recovered.count) chunk(s) of \(meeting.folder)", "ai")
        if let updated = store.meeting(meeting.id) { resumeTranscription(updated) }
    }

}
