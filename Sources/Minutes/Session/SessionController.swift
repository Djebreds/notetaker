import AppKit
import Foundation
import Observation

/// Runs recordings: starts them (hotkey, menu, detected call, notification), keeps the mute monitor and
/// recorder in step, and hands finished recordings to the processing center.
@MainActor @Observable
final class SessionController {
    enum Phase: Equatable {
        case idle, starting, recording, stopping
    }

    struct Active {
        let meetingID: UUID
        let startedAt: Date
        let trigger: Trigger
        var call: CallDetector.Call?
        let recorder: Recorder
        /// When this recording continues an earlier part of the same meeting (the call came back):
        /// seconds since the meeting started, chunks and mute intervals already there.
        var timeOffset: Double = 0
        var earlierChunks = 0
        var earlierMute: [MuteInterval] = []
        var resumed: Bool { earlierChunks > 0 || timeOffset > 0 }
    }

    /// A recording that stopped because its call ended; the same call coming back soon continues it.
    private struct EndedCall {
        let meetingID: UUID
        let appID: String
        let meetingCode: String?
        var at: Date
        var bySleep = false
    }

    /// How long after an automatic stop the same call may come back and continue the meeting. Calls
    /// without a meeting code (native apps) get a short window so back-to-back meetings stay separate.
    static func rejoinWindow(hasCode: Bool) -> TimeInterval { hasCode ? 180 : 30 }

    private(set) var phase: Phase = .idle
    private(set) var active: Active?
    private(set) var health = RecorderHealth()
    private(set) var meterMe: Float = 0
    private(set) var meterOthers: Float = 0
    private(set) var elapsed: TimeInterval = 0
    /// A detected call from an "ask first" app, waiting for the user's answer.
    private(set) var pendingAsk: CallDetector.Call?
    private(set) var lastError: String?

    let store: MeetingStore
    let settings: AppSettings
    let permissions: Permissions
    let detector: CallDetector
    let mute: MuteMonitor
    let processing: ProcessingCenter

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var lastPersistedMute: [MuteInterval] = []
    @ObservationIgnored private var lastEndedCall: EndedCall?

    init(store: MeetingStore, settings: AppSettings, permissions: Permissions, detector: CallDetector,
         mute: MuteMonitor, processing: ProcessingCenter) {
        self.store = store
        self.settings = settings
        self.permissions = permissions
        self.detector = detector
        self.mute = mute
        self.processing = processing

        detector.policy = { [settings] app in settings.policy(for: app) }
        detector.remoteAudibleWithin = { [weak self] seconds in
            (self?.active?.recorder.secondsSinceOthersAudible() ?? .infinity) < seconds
        }
        detector.onStarted = { [weak self] call in self?.callStarted(call) }
        detector.onEnded = { [weak self] call in self?.callEnded(call) }
        Notifier.shared.onAction = { [weak self] action in self?.handle(action) }
    }

    var isRecording: Bool { phase == .recording || phase == .starting }

    // MARK: - User actions

    func toggle() {
        switch phase {
        case .idle: startManual()
        case .recording, .starting: stop(discard: false)
        case .stopping: break
        }
    }

    func startManual() {
        Task { await start(trigger: .manual, call: detector.current) }
    }

    func stop(discard: Bool) {
        Task { await finish(discard: discard) }
    }

    /// Stops and saves, returning once the recording is safely closed (used when quitting).
    func stopAndWait() async {
        await finish(discard: false)
    }

    /// The Mac is going to sleep: close the recording as if the call had ended, so the same call
    /// continues this meeting when it comes back after wake, and let the detector see it again.
    func macWillSleep() {
        let resumable = active?.trigger == .auto
        if isRecording { Log.info("Mac is going to sleep; closing the recording", "session") }
        Task {
            if isRecording { await finish(discard: false, endedByCall: resumable) }
            lastEndedCall?.bySleep = true
            detector.reset()
        }
    }

    /// The rejoin window for a call closed by sleep starts when the Mac wakes, not when it slept.
    func macDidWake() {
        if lastEndedCall?.bySleep == true { lastEndedCall?.at = Date() }
        detector.reset()
    }

    func toggleMicExclusion() {
        guard isRecording else { return }
        mute.toggleManualExclude()
        persistMute()
    }

    // MARK: - Recording lifecycle

    private func start(trigger: Trigger, call: CallDetector.Call?, resuming resumeID: UUID? = nil) async {
        guard phase == .idle else { return }
        phase = .starting
        lastError = nil
        pendingAsk = nil
        Notifier.shared.remove(Notifier.askID)

        permissions.refresh()
        if permissions.microphone == .notDetermined { await permissions.requestMicrophone() }
        if permissions.microphone == .denied {
            Log.warn("Microphone permission denied; recording meeting audio only", "session")
        }

        let meeting: Meeting
        var timeOffset = 0.0, earlierChunks = 0, firstChunkIndex = 1
        var earlierMute: [MuteInterval] = []
        var resumedFrom: Meeting?
        if let resumeID, let existing = store.meeting(resumeID) {
            meeting = existing
            resumedFrom = existing
            timeOffset = Date().timeIntervalSince(existing.startedAt)
            earlierChunks = existing.chunks.count
            earlierMute = existing.mute
            firstChunkIndex = nextChunkIndex(existing)
            store.update(resumeID) { m in
                m.status = .recording
                m.endedAt = nil
                m.statusDetail = nil
            }
            processing.reopen(resumeID)
            Log.info("The same call came back; continuing \(existing.folder) at chunk \(firstChunkIndex)", "session")
        } else {
            meeting = store.create(appID: call?.app.id, appName: call?.name, trigger: trigger)
        }
        let sessionStart = HostClock.now
        mute.start(sessionStartHost: sessionStart, call: call) { [monitor = detector.monitor] in monitor.current }
        let timeline = mute.timeline
        let meetingID = meeting.id
        let recorder = Recorder(
            meetingFolder: store.folder(meeting),
            sessionStartHost: sessionStart,
            firstChunkIndex: firstChunkIndex,
            timeOffset: timeOffset,
            excludedBundleIDs: AppCatalog.excludedFromRecording,
            mask: { from, to in timeline.mask(from: from, to: to) },
            onChunk: { [weak self] chunk in Task { @MainActor in self?.chunkReady(meetingID, chunk) } },
            onHealth: { [weak self] health in Task { @MainActor in self?.healthChanged(health) } })
        active = Active(meetingID: meetingID, startedAt: Date(), trigger: trigger, call: call, recorder: recorder,
                        timeOffset: timeOffset, earlierChunks: earlierChunks, earlierMute: earlierMute)

        do {
            try await recorder.start()
        } catch {
            Log.error("Recording failed to start: \(error.localizedDescription)", "session")
            lastError = error.localizedDescription
            _ = mute.stop()
            if let resumedFrom {
                // Put the earlier part back the way it was and finish it.
                store.update(meetingID) { m in
                    m.status = .transcribing
                    m.endedAt = resumedFrom.endedAt
                }
                processing.finish(meetingID, expectedChunks: earlierChunks)
            } else {
                store.discard(meetingID)
            }
            active = nil
            phase = .idle
            Notifier.shared.problem("Couldn't start recording: \(error.localizedDescription)")
            return
        }
        phase = .recording
        startTicker()
        Log.info("Recording started (\(trigger.rawValue)\(call.map { ", \($0.name)" } ?? ""))", "session")
        if trigger == .auto { Notifier.shared.recordingStarted(appName: call?.name) }
    }

    private func finish(discard: Bool, endedByCall: Bool = false) async {
        while phase == .starting { try? await Task.sleep(for: .milliseconds(100)) }
        guard phase == .recording, let active else { return }
        phase = .stopping
        ticker?.invalidate()
        ticker = nil
        Notifier.shared.remove(Notifier.recordingID)

        let chunkCount = await active.recorder.stop()
        let intervals = active.earlierMute + Self.shift(mute.stop(), by: active.timeOffset)
        lastPersistedMute = []
        let id = active.meetingID
        lastEndedCall = nil
        if discard, active.resumed {
            // Only this part is discarded; the earlier part of the meeting stays.
            discardChunks(of: id, from: active.earlierChunks)
            store.update(id) { m in
                m.endedAt = Date()
                m.mute = active.earlierMute
                m.status = .transcribing
            }
            processing.finish(id, expectedChunks: active.earlierChunks)
            Log.info("Discarded the resumed part of the recording", "session")
        } else if discard {
            processing.cancel(id)
            store.discard(id)
            Log.info("Recording discarded", "session")
        } else {
            store.update(id) { m in
                m.endedAt = Date()
                m.mute = intervals
                m.status = .transcribing
            }
            processing.finish(id, expectedChunks: active.earlierChunks + chunkCount)
            Log.info("Recording stopped after \(chunkCount) chunk(s)", "session")
            if endedByCall, let call = active.call {
                lastEndedCall = EndedCall(meetingID: id, appID: call.app.id, meetingCode: call.meetingCode, at: Date())
            }
        }
        self.active = nil
        meterMe = 0
        meterOthers = 0
        elapsed = 0
        phase = .idle
    }

    private func chunkReady(_ meetingID: UUID, _ chunk: ChunkRecord) {
        guard store.update(meetingID, { $0.chunks.append(chunk) }) != nil else { return }
        processing.enqueue(meetingID, chunk: chunk)
    }

    private func healthChanged(_ health: RecorderHealth) {
        let wasSilent = self.health.systemAudio == .silent
        self.health = health
        if health.systemAudio == .silent, !wasSilent, let problem = health.problem {
            Notifier.shared.problem(problem)
        }
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let active else { return }
        elapsed = Date().timeIntervalSince(active.startedAt)
        let levels = active.recorder.takeLevels()
        meterMe = Self.meter(levels.me, previous: meterMe)
        meterOthers = Self.meter(levels.others, previous: meterOthers)
        persistMute()
    }

    /// Peak → 0…1 on a 60 dB scale, with a gentle fall-off.
    private static func meter(_ peak: Float, previous: Float) -> Float {
        let db = 20 * log10(max(peak, 1e-6))
        let level = max(0, min(1, (db + 60) / 60))
        return max(level, previous * 0.8)
    }

    /// Saves the mute timeline whenever it changes, so a crash can never leak muted speech.
    private func persistMute() {
        guard let active else { return }
        let intervals = mute.timeline.intervals
        guard intervals != lastPersistedMute else { return }
        lastPersistedMute = intervals
        store.update(active.meetingID) { $0.mute = active.earlierMute + Self.shift(intervals, by: active.timeOffset) }
    }

    private static func shift(_ intervals: [MuteInterval], by offset: Double) -> [MuteInterval] {
        guard offset != 0 else { return intervals }
        return intervals.map { MuteInterval(start: $0.start + offset, end: $0.end.map { $0 + offset }, source: $0.source) }
    }

    /// The next free chunk number: after every chunk in meeting.json and every audio file on disk.
    private func nextChunkIndex(_ meeting: Meeting) -> Int {
        let audio = store.folder(meeting).appendingPathComponent("audio")
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: audio.path)) ?? []).compactMap { Int($0.prefix(4)) }
        return max(meeting.chunks.map(\.index).max() ?? 0, onDisk.max() ?? 0) + 1
    }

    /// Removes the chunks recorded after `count` earlier ones (their records and audio).
    private func discardChunks(of meetingID: UUID, from count: Int) {
        guard let meeting = store.meeting(meetingID) else { return }
        let dropped = meeting.chunks.dropFirst(count)
        let audio = store.folder(meeting).appendingPathComponent("audio")
        for chunk in dropped {
            for track in Track.allCases {
                if let file = chunk[track].file {
                    try? FileManager.default.removeItem(at: store.folder(meeting).appendingPathComponent(file))
                }
                try? FileManager.default.removeItem(at: audio.appendingPathComponent(String(format: "%04d-%@.pcm", chunk.index, track.rawValue)))
            }
        }
        store.update(meetingID) { $0.chunks = Array($0.chunks.prefix(count)) }
    }

    // MARK: - Call detection

    private func callStarted(_ call: CallDetector.Call) {
        if isRecording {
            // A manual recording learns which app it is, for mute detection.
            if var current = active, current.call == nil {
                current.call = call
                active = current
                mute.attach(call) { [monitor = detector.monitor] in monitor.current }
                store.update(current.meetingID) { m in
                    m.appID = call.app.id
                    m.appName = call.name
                }
            }
            return
        }
        guard settings.autoDetect else { return }
        if let ended = lastEndedCall, ended.appID == call.app.id, ended.meetingCode == call.meetingCode,
           Date().timeIntervalSince(ended.at) < Self.rejoinWindow(hasCode: call.meetingCode != nil),
           store.meeting(ended.meetingID) != nil {
            // Same call back within moments (rejoined, or a detection hiccup): continue that meeting,
            // without asking again even for "ask first" apps.
            lastEndedCall = nil
            Task { await start(trigger: .auto, call: call, resuming: ended.meetingID) }
            return
        }
        switch settings.policy(for: call.app) {
        case .auto:
            Task { await start(trigger: .auto, call: call) }
        case .ask:
            pendingAsk = call
            Notifier.shared.ask(appID: call.app.id, appName: call.app.name)
        case .off:
            break
        }
    }

    private func callEnded(_ call: CallDetector.Call) {
        if pendingAsk?.app.id == call.app.id {
            pendingAsk = nil
            Notifier.shared.remove(Notifier.askID)
        }
        // Manual recordings end manually.
        guard let active, active.trigger == .auto, active.call?.app.id == call.app.id else { return }
        Task { await finish(discard: false, endedByCall: true) }
    }

    func answerAsk(record: Bool, always: Bool = false) {
        guard let call = pendingAsk ?? detector.current else { return }
        pendingAsk = nil
        Notifier.shared.remove(Notifier.askID)
        if always { settings.setPolicy(.auto, for: call.app) }
        if record { Task { await start(trigger: .auto, call: call) } }
    }

    private func handle(_ action: Notifier.Action) {
        switch action {
        case .stopAndSave:
            stop(discard: false)
        case .discard:
            stop(discard: true)
        case .record:
            answerAsk(record: true)
        case .alwaysRecord:
            answerAsk(record: true, always: true)
        case .notNow:
            answerAsk(record: false)
        case .open(let meetingID):
            WindowManager.shared.showHistory(select: meetingID)
        }
    }
}
