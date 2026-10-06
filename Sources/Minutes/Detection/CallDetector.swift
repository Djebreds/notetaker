import AppKit
import Foundation
import Observation

/// Decides when a call starts and ends, from which app holds the microphone (Core Audio, no
/// permission), confirmed with app-specific signals (Zoom's "Meeting" menu, Slack's "Leave huddle",
/// a Meet tab in the browser).
@MainActor @Observable
final class CallDetector {
    struct Call: Equatable, Sendable {
        let app: CallApp
        /// The app's process (the browser's for web calls).
        let pid: pid_t
        let browserBundleID: String?
        let meetingCode: String?
        let startedAt: Date

        var name: String {
            if let browserBundleID, let browser = AppCatalog.browsers[browserBundleID] { return "\(app.name) · \(browser)" }
            return app.name
        }
    }

    static let autoDelay: TimeInterval = 3
    static let askDelay: TimeInterval = 15
    static let nativeEndGrace: TimeInterval = 15
    static let webEndGrace: TimeInterval = 45

    private(set) var activity = AudioActivity()
    /// The ongoing call, once reported through `onStarted`.
    private(set) var current: Call?
    /// Browsers whose tabs could not be read (e.g. Automation permission denied).
    private(set) var browserProblems: [String: String] = [:]

    var policy: (CallApp) -> AppPolicy = { $0.defaultPolicy }
    /// Whether the recording heard the other participants within the given number of seconds.
    var remoteAudibleWithin: (TimeInterval) -> Bool = { _ in false }
    var onStarted: ((Call) -> Void)?
    var onEnded: ((Call) -> Void)?

    @ObservationIgnored let monitor = AudioProcessMonitor()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var candidateSince: [String: Date] = [:]
    @ObservationIgnored private var endSince: Date?
    @ObservationIgnored private var goneSince: Date?
    @ObservationIgnored private var lastLookupWarning = Date.distantPast
    @ObservationIgnored private var confirmations: [String: (value: Bool, at: Date)] = [:]
    @ObservationIgnored private var confirming: Set<String> = []
    @ObservationIgnored private var tabCache: [String: (tabs: [BrowserTabs.Tab], at: Date)] = [:]
    @ObservationIgnored private var titleCache: [String: (titles: [String], at: Date)] = [:]
    @ObservationIgnored private var fetchingTitles: Set<String> = []
    @ObservationIgnored private var fetchingTabs: Set<String> = []
    @ObservationIgnored private let work = DispatchQueue(label: "minutes.detector", qos: .utility)

    private struct Candidate {
        let app: CallApp
        let pid: pid_t
        let browserBundleID: String?
        let meetingCode: String?
        var key: String { "\(app.id)#\(pid)#\(meetingCode ?? "")" }
    }

    func start() {
        monitor.start { [weak self] activity in
            Task { @MainActor in self?.update(activity) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    func stop() {
        monitor.stop()
        timer?.invalidate()
        timer = nil
    }

    private func update(_ activity: AudioActivity) {
        self.activity = activity
        evaluate()
    }

    // MARK: - Evaluation

    private func evaluate() {
        let now = Date()
        if let current {
            evaluateEnd(of: current, now: now)
            return
        }

        var candidates: [Candidate] = []
        var browsersToCheck: [(app: AudioApp, usesMic: Bool)] = []
        for user in activity.micUsers {
            if let app = AppCatalog.nativeApp(for: user.bundleID) {
                let pid = app.id == "facetime" ? (runningPID(of: "com.apple.FaceTime") ?? user.pid) : user.pid
                candidates.append(Candidate(app: app, pid: pid, browserBundleID: nil, meetingCode: nil))
            } else if AppCatalog.browsers[user.bundleID] != nil {
                browsersToCheck.append((user, true))
            }
        }
        // A Meet joined with the mic muted never opens the mic, but the browser plays the call's audio.
        for player in activity.outputApps
        where AppCatalog.browsers[player.bundleID] != nil && !browsersToCheck.contains(where: { $0.app == player }) {
            browsersToCheck.append((player, false))
        }
        for (browser, usesMic) in browsersToCheck {
            // Window titles first: Accessibility only, no prompt (a Meet call's tab is titled "Meet - abc-defg-hij").
            refreshTitles(of: browser, maxAge: 3)
            if let titles = titleCache[browser.bundleID]?.titles,
               let (app, code) = AppCatalog.webApps.lazy.compactMap({ app in Self.titleMatch(titles, app).map { (app, $0.code) } }).first {
                candidates.append(Candidate(app: app, pid: browser.pid, browserBundleID: browser.bundleID, meetingCode: code))
                continue
            }
            // The browser is using the mic but no meeting is in front: look through its tabs (Automation,
            // asked once per browser). Not done for mere playback, so watching a video never prompts.
            guard usesMic else { continue }
            refreshTabs(of: browser.bundleID, maxAge: 5)
            guard let tabs = tabCache[browser.bundleID]?.tabs else { continue }
            for app in AppCatalog.webApps {
                if let match = BrowserTabs.meetingTab(in: tabs, for: app) {
                    candidates.append(Candidate(app: app, pid: browser.pid, browserBundleID: browser.bundleID, meetingCode: match.code))
                    break
                }
            }
        }

        let liveKeys = Set(candidates.map(\.key))
        candidateSince = candidateSince.filter { liveKeys.contains($0.key) }

        for candidate in candidates {
            let policy = policy(candidate.app)
            guard policy != .off else { continue }
            let since = candidateSince[candidate.key] ?? now
            candidateSince[candidate.key] = since
            guard confirmed(candidate) == true else { continue }
            let delay = policy == .ask ? Self.askDelay : Self.autoDelay
            guard now.timeIntervalSince(since) >= delay else { continue }
            let call = Call(app: candidate.app, pid: candidate.pid, browserBundleID: candidate.browserBundleID,
                            meetingCode: candidate.meetingCode, startedAt: since)
            current = call
            endSince = nil
            candidateSince.removeAll()
            Log.info("Call detected: \(call.name)\(call.meetingCode.map { " (\($0))" } ?? "")", "detect")
            onStarted?(call)
            return
        }
    }

    private func evaluateEnd(of call: Call, now: Date) {
        // Ask the kernel whether the app's process still exists. NSRunningApplication lookups have
        // reported a running Arc as gone for a moment, which ended (and split) calls; a real quit is
        // still confirmed over two checks before the call ends.
        let bundleIDs = call.app.bundleIDs + call.app.processBundleIDs
        if !Self.processAlive(call.pid), call.browserBundleID != nil || !activity.isUsingMic(bundleIDs: bundleIDs) {
            let since = goneSince ?? now
            goneSince = since
            if now.timeIntervalSince(since) >= 2 { end(call, reason: call.browserBundleID != nil ? "browser quit" : "app quit") }
            return
        }
        goneSince = nil

        var stillOn = true
        var grace = Self.nativeEndGrace
        if let browser = call.browserBundleID {
            grace = Self.webEndGrace
            if runningPID(of: browser) == nil, now.timeIntervalSince(lastLookupWarning) > 60 {
                lastLookupWarning = now
                Log.warn("NSRunningApplication reports \(browser) not running, but its process \(call.pid) is alive; ignoring", "detect")
            }
            // Still on while the call's tab is in front, the browser holds the mic (unmuted), or the
            // meeting tab is open and the browser is playing the call's audio (muted, tab in background).
            refreshTitles(of: AudioApp(bundleID: browser, name: browser, pid: call.pid), maxAge: 3)
            refreshTabs(of: browser, maxAge: 5)
            let titleShowsCall = titleCache[browser].map { Self.titleMatch($0.titles, call.app) != nil } ?? false
            let holdsMic = activity.micUsers.contains { $0.bundleID == browser }
            let playing = activity.outputApps.contains { $0.bundleID == browser }
            var tabOpen = true  // unknown when tabs can't be read
            if let cached = tabCache[browser], now.timeIntervalSince(cached.at) < 15 {
                let match = BrowserTabs.meetingTab(in: cached.tabs, for: call.app)
                tabOpen = match != nil && (call.meetingCode == nil || match?.code == call.meetingCode)
            }
            stillOn = titleShowsCall || (tabOpen && (holdsMic || playing))
        } else {
            // A released mic alone doesn't end a call (some apps drop it on mute): the call app must
            // also have stopped playing the other people (heard within 10 s), and its in-call controls
            // (Zoom's "Meeting" menu, Slack's "Leave huddle") must be gone. Audio only counts while the
            // call app itself is playing, so a video after the call can't keep it alive.
            let candidate = Candidate(app: call.app, pid: call.pid, browserBundleID: nil, meetingCode: nil)
            let inCallUI = call.app.confirmation != .micOnly && confirmed(candidate) == true
            let appPlaying = activity.outputApps.contains { bundleIDs.contains($0.bundleID) }
            stillOn = activity.isUsingMic(bundleIDs: bundleIDs) || inCallUI || (appPlaying && remoteAudibleWithin(10))
        }
        if stillOn {
            endSince = nil
        } else {
            let since = endSince ?? now
            endSince = since
            if now.timeIntervalSince(since) >= grace { end(call, reason: "call ended") }
        }
    }

    private func end(_ call: Call, reason: String) {
        Log.info("Call ended (\(reason)): \(call.name)", "detect")
        current = nil
        endSince = nil
        goneSince = nil
        candidateSince.removeAll()
        onEnded?(call)
    }

    /// Forget the current call without reporting its end (e.g. the user stopped it and left).
    func reset() {
        current = nil
        endSince = nil
        goneSince = nil
        candidateSince.removeAll()
    }

    /// Whether a process exists (signal 0 probes without sending anything).
    nonisolated static func processAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Confirmation (AX, async + cached)

    private func confirmed(_ candidate: Candidate) -> Bool? {
        switch candidate.app.confirmation {
        case .micOnly, .webTab:
            return true
        case .zoomMeetingMenu, .slackHuddle:
            let key = candidate.key
            if let cached = confirmations[key], Date().timeIntervalSince(cached.at) < 3 { return cached.value }
            if !confirming.contains(key) {
                confirming.insert(key)
                let app = candidate.app, pid = candidate.pid
                work.async { [weak self] in
                    let value = Self.checkConfirmation(app: app, pid: pid)
                    Task { @MainActor in
                        self?.confirming.remove(key)
                        self?.confirmations[key] = (value, Date())
                    }
                }
            }
            return confirmations[key]?.value
        }
    }

    nonisolated private static func checkConfirmation(app: CallApp, pid: pid_t) -> Bool {
        guard AX.isTrusted else { return true }  // can't check without Accessibility; trust the mic signal
        let axApp = AX.application(pid)
        switch app.confirmation {
        case .zoomMeetingMenu:
            return AX.menuBarItems(axApp).contains { AX.string($0, kAXTitleAttribute) == "Meeting" }
        case .slackHuddle:
            AX.setFlag(axApp, "AXManualAccessibility", true)
            return AX.first(in: AX.windows(axApp), maxNodes: 6_000) { element, role in
                (role == "AXButton" || role == "AXCheckBox") && AX.allLabels(element).contains { $0.contains("leave huddle") }
            } != nil
        default:
            return true
        }
    }

    // MARK: - Browser window titles (Accessibility, async + cached)

    struct TitleMatch { let code: String? }

    static func titleMatch(_ titles: [String], _ app: CallApp) -> TitleMatch? {
        guard let pattern = app.titlePattern, let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for title in titles {
            guard let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else { continue }
            var code: String?
            if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: title) { code = String(title[r]) }
            return TitleMatch(code: code)
        }
        return nil
    }

    private func refreshTitles(of browser: AudioApp, maxAge: TimeInterval) {
        if let cached = titleCache[browser.bundleID], Date().timeIntervalSince(cached.at) < maxAge { return }
        guard !fetchingTitles.contains(browser.bundleID), AX.isTrusted else { return }
        fetchingTitles.insert(browser.bundleID)
        let bundleID = browser.bundleID
        let pid = runningPID(of: bundleID) ?? browser.pid
        work.async { [weak self] in
            let app = AX.application(pid)
            let titles = AX.windows(app).compactMap { AX.string($0, kAXTitleAttribute) }
            Task { @MainActor in
                self?.fetchingTitles.remove(bundleID)
                self?.titleCache[bundleID] = (titles, Date())
            }
        }
    }

    // MARK: - Browser tabs (AppleScript, async + cached)

    private func refreshTabs(of bundleID: String, maxAge: TimeInterval) {
        if let cached = tabCache[bundleID], Date().timeIntervalSince(cached.at) < maxAge { return }
        guard !fetchingTabs.contains(bundleID) else { return }
        fetchingTabs.insert(bundleID)
        work.async { [weak self] in
            let result = BrowserTabs.tabs(of: bundleID)
            Task { @MainActor in
                guard let self else { return }
                self.fetchingTabs.remove(bundleID)
                switch result {
                case .success(let tabs):
                    self.tabCache[bundleID] = (tabs, Date())
                    self.browserProblems[bundleID] = nil
                case .failure(let box):
                    switch box.reason {
                    case .notPermitted:
                        self.browserProblems[bundleID] = "Minutes isn't allowed to read \(AppCatalog.browsers[bundleID] ?? bundleID)'s tabs (System Settings › Privacy & Security › Automation)."
                    case .failed(let message):
                        self.browserProblems[bundleID] = message
                    case .notRunning:
                        self.tabCache[bundleID] = nil
                    }
                }
            }
        }
    }

    private func runningPID(of bundleID: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }
}
