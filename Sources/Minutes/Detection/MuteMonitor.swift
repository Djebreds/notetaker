import Foundation
import Observation

/// Tracks whether the user is muted in the meeting app during a recording, and keeps the timeline
/// the recorder uses to silence the user's mic.
@MainActor @Observable
final class MuteMonitor {
    enum State: Equatable {
        case unknown
        case muted(String)
        case unmuted(String)

        var isMuted: Bool { if case .muted = self { true } else { false } }
    }

    private(set) var state: State = .unknown
    /// The user's "exclude my mic" override.
    private(set) var manualExclude = false
    private(set) var timeline = MuteTimeline()

    @ObservationIgnored private var sessionStartHost: UInt64 = 0
    @ObservationIgnored private var poller: MutePoller?

    /// Whether the mic is currently being left out of the transcript.
    var micExcluded: Bool { manualExclude || state.isMuted }

    func start(sessionStartHost: UInt64, call: CallDetector.Call?, activity: @escaping @Sendable () -> AudioActivity) {
        stopPolling()
        self.sessionStartHost = sessionStartHost
        timeline = MuteTimeline()
        state = .unknown
        manualExclude = false
        if let call { attach(call, activity: activity) }
    }

    /// Starts reading a call's mute state (also used when a call is found after a manual start).
    func attach(_ call: CallDetector.Call, activity: @escaping @Sendable () -> AudioActivity) {
        stopPolling()
        let poller = MutePoller(app: call.app, pid: call.pid, browserBundleID: call.browserBundleID, activity: activity) { [weak self] reading, source, host in
            Task { @MainActor in self?.apply(reading, source: source, host: host) }
        }
        self.poller = poller
        poller.start()
    }

    /// Stops reading and closes open intervals; returns the session's mute intervals.
    func stop() -> [MuteInterval] {
        stopPolling()
        timeline.closeAll(at: elapsed)
        state = .unknown
        manualExclude = false
        return timeline.intervals
    }

    func toggleManualExclude() {
        manualExclude.toggle()
        timeline.setManual(manualExclude, at: elapsed)
        Log.info("Manual mic exclusion \(manualExclude ? "on" : "off")", "mute")
    }

    private var elapsed: Double { HostClock.seconds(from: sessionStartHost, to: HostClock.now) }

    private func stopPolling() {
        poller?.stop()
        poller = nil
    }

    private func apply(_ reading: MuteReading, source: MuteSource, host: UInt64) {
        let at = HostClock.seconds(from: sessionStartHost, to: host)
        let label = poller?.sourceDescription ?? ""
        switch reading {
        case .muted:
            state = .muted(source == .notCapturing ? "app isn't using the mic" : label)
        case .unmuted:
            state = .unmuted(label)
        case .unknown:
            state = .unknown
        }
        timeline.setDetected(muted: reading == .muted, at: at, source: source)
        Log.info("Mute state: \(reading) (\(source.rawValue)) at \(String(format: "%.1f", at)) s", "mute")
    }
}

/// Polls a meeting app's mute control every 0.5 s on a background queue; a new state must be seen
/// twice in a row before it is reported (with the time it was first seen).
nonisolated final class MutePoller: @unchecked Sendable {
    private let queue = DispatchQueue(label: "minutes.mute", qos: .userInitiated)
    private let app: CallApp
    private let reader: MuteReader
    private let browserBundleID: String?
    private let activity: @Sendable () -> AudioActivity
    private let onChange: @Sendable (MuteReading, MuteSource, UInt64) -> Void
    private var timer: DispatchSourceTimer?
    private var candidate: (reading: MuteReading, source: MuteSource, firstSeen: UInt64, count: Int)?
    private var published: (MuteReading, MuteSource)?
    private let descriptionLock = NSLock()
    private var _source = ""

    init(app: CallApp, pid: pid_t, browserBundleID: String?, activity: @escaping @Sendable () -> AudioActivity,
         onChange: @escaping @Sendable (MuteReading, MuteSource, UInt64) -> Void) {
        self.app = app
        self.reader = MuteReader(app: app, pid: pid)
        self.browserBundleID = browserBundleID
        self.activity = activity
        self.onChange = onChange
    }

    var sourceDescription: String { descriptionLock.withLock { _source } }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        let now = HostClock.now
        var reading = reader.read()
        var source = MuteSource.app
        descriptionLock.withLock { _source = reader.sourceDescription }

        // If the call app isn't capturing the mic at all, nobody can hear the user.
        let holders = activity().micUsers
        let capturing: Bool
        if let browserBundleID {
            capturing = holders.contains { $0.bundleID == browserBundleID }
        } else {
            capturing = holders.contains { app.bundleIDs.contains($0.bundleID) || app.processBundleIDs.contains($0.bundleID) }
        }
        if !capturing {
            reading = .muted
            source = .notCapturing
        }

        // A hidden browser tab can't be read; keep the last known state.
        if reading == .unknown, browserBundleID != nil, published != nil { return }

        if let c = candidate, c.reading == reading, c.source == source {
            candidate?.count += 1
        } else {
            candidate = (reading, source, now, 1)
        }
        guard let c = candidate, c.count >= 2 else { return }
        if let published, published.0 == c.reading, published.1 == c.source { return }
        published = (c.reading, c.source)
        onChange(c.reading, c.source, c.firstSeen)
    }
}
