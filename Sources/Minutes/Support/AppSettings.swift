import Foundation
import Observation
import ServiceManagement

nonisolated enum AudioRetention: String, Codable, Sendable, CaseIterable, Identifiable {
    case afterNotes, days7, days30, forever
    var id: String { rawValue }
    var label: String {
        switch self {
        case .afterNotes: "Delete once notes are ready"
        case .days7: "Keep 7 days"
        case .days30: "Keep 30 days"
        case .forever: "Keep forever"
        }
    }
    /// Days to keep audio; nil = forever, 0 = right after notes.
    var days: Int? {
        switch self {
        case .afterNotes: 0
        case .days7: 7
        case .days30: 30
        case .forever: nil
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor @Observable
final class AppSettings {
    nonisolated static let defaultTranscriptionModel = "google/gemini-3.8-flash"
    nonisolated static let defaultNotesModel = "openai/gpt-6-luna"

    @ObservationIgnored private let defaults = UserDefaults.standard

    var autoDetect: Bool { didSet { defaults.set(autoDetect, forKey: "autoDetect") } }
    var policies: [String: AppPolicy] { didSet { save(policies, "policies") } }
    var transcriptionModel: String { didSet { defaults.set(transcriptionModel, forKey: "transcriptionModel") } }
    var notesModel: String { didSet { defaults.set(notesModel, forKey: "notesModel") } }
    var notesLanguage: NotesLanguage { didSet { defaults.set(notesLanguage.rawValue, forKey: "notesLanguage") } }
    var customInstructions: String { didSet { defaults.set(customInstructions, forKey: "customInstructions") } }
    /// About the reader, for personalised notes.
    var userName: String { didSet { defaults.set(userName, forKey: "userName") } }
    var userRole: String { didSet { defaults.set(userRole, forKey: "userRole") } }
    var userFocus: String { didSet { defaults.set(userFocus, forKey: "userFocus") } }
    var zeroDataRetention: Bool { didSet { defaults.set(zeroDataRetention, forKey: "zeroDataRetention") } }
    /// Hide lines that are only "Mm", "Okay", "Yeah"… in transcripts and exports.
    var hideFillerLines: Bool { didSet { defaults.set(hideFillerLines, forKey: "hideFillerLines") } }
    /// On-device speaker recognition (FluidAudio) after each meeting.
    var recognizeSpeakers: Bool { didSet { defaults.set(recognizeSpeakers, forKey: "recognizeSpeakers") } }
    var audioRetention: AudioRetention { didSet { defaults.set(audioRetention.rawValue, forKey: "audioRetention") } }
    var toggleShortcut: Shortcut? { didSet { save(toggleShortcut, "toggleShortcut") } }
    var micShortcut: Shortcut? { didSet { save(micShortcut, "micShortcut") } }
    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    /// Cached so views don't hit the keychain on every redraw.
    private(set) var hasOpenRouterKey = false

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.error("Launch at login: \(error.localizedDescription)")
            }
        }
    }

    init() {
        defaults.register(defaults: ["autoDetect": true, "zeroDataRetention": true, "hideFillerLines": true, "recognizeSpeakers": true])
        autoDetect = defaults.bool(forKey: "autoDetect")
        policies = Self.load([String: AppPolicy].self, "policies", defaults) ?? [:]
        transcriptionModel = defaults.string(forKey: "transcriptionModel") ?? Self.defaultTranscriptionModel
        notesModel = defaults.string(forKey: "notesModel") ?? Self.defaultNotesModel
        notesLanguage = defaults.string(forKey: "notesLanguage").flatMap(NotesLanguage.init) ?? .english
        customInstructions = defaults.string(forKey: "customInstructions") ?? ""
        userName = defaults.string(forKey: "userName") ?? ""
        userRole = defaults.string(forKey: "userRole") ?? ""
        userFocus = defaults.string(forKey: "userFocus") ?? ""
        zeroDataRetention = defaults.bool(forKey: "zeroDataRetention")
        hideFillerLines = defaults.bool(forKey: "hideFillerLines")
        recognizeSpeakers = defaults.bool(forKey: "recognizeSpeakers")
        audioRetention = defaults.string(forKey: "audioRetention").flatMap(AudioRetention.init) ?? .days30
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        toggleShortcut = defaults.object(forKey: "toggleShortcut") == nil
            ? Shortcut.defaultToggle : Self.load(Shortcut.self, "toggleShortcut", defaults)
        micShortcut = defaults.object(forKey: "micShortcut") == nil
            ? Shortcut.defaultMic : Self.load(Shortcut.self, "micShortcut", defaults)
        hasOpenRouterKey = Keychain.openRouterKey != nil
    }

    func saveOpenRouterKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.set(trimmed.isEmpty ? nil : trimmed, account: Keychain.openRouterAccount)
        hasOpenRouterKey = !trimmed.isEmpty
    }

    var readerProfile: ReaderProfile { ReaderProfile(name: userName, role: userRole, focus: userFocus) }

    func policy(for app: CallApp) -> AppPolicy { policies[app.id] ?? app.defaultPolicy }

    func setPolicy(_ policy: AppPolicy, for app: CallApp) { policies[app.id] = policy }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        // An explicit JSON "null" remembers that the user cleared a shortcut.
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
