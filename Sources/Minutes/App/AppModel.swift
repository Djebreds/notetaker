import AppKit
import Observation

/// Owns the app's long-lived objects.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings()
    let store = MeetingStore()
    let permissions = Permissions()
    let detector = CallDetector()
    let mute = MuteMonitor()
    let voices = VoiceProfiles()
    let processing: ProcessingCenter
    let session: SessionController

    /// Meeting to select when the history window opens.
    var historySelection: UUID?

    @ObservationIgnored private var retentionTimer: Timer?

    private init() {
        processing = ProcessingCenter(store: store, settings: settings, voices: voices)
        session = SessionController(store: store, settings: settings, permissions: permissions,
                                    detector: detector, mute: mute, processing: processing)
        processing.onNotesReady = { meeting in Notifier.shared.notesReady(meetingID: meeting.id, title: meeting.title) }
        processing.onProblem = { message in Notifier.shared.problem(message) }
    }

    func launch() {
        Log.info("Minutes \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") launched")
        Notifier.shared.setUp()
        permissions.refresh()
        registerHotKeys()
        detector.start()
        processing.resumeUnfinished()
        store.applyRetention(settings.audioRetention)
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self.map { $0.store.applyRetention($0.settings.audioRetention) } }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.macWillSleep() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.macDidWake() }
        }
        if !settings.onboardingDone {
            // After launch completes, so the window isn't created mid-launch and left off screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { WindowManager.shared.showOnboarding() }
            }
        }
    }

    func registerHotKeys() {
        HotKeyCenter.shared.register(1, settings.toggleShortcut) { [weak self] in self?.session.toggle() }
        HotKeyCenter.shared.register(2, settings.micShortcut) { [weak self] in self?.session.toggleMicExclusion() }
    }

    /// The first thing that stops Minutes from working, if any.
    var blockingProblem: String? {
        if permissions.microphone == .denied { return "Microphone access is off." }
        if permissions.systemAudio == .denied { return "System audio recording is off." }
        if !settings.hasOpenRouterKey { return "Add your OpenRouter API key to get transcripts." }
        return nil
    }
}
