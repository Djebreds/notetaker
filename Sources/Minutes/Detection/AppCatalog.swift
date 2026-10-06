import Foundation

nonisolated enum AppPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto, ask, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Start automatically"
        case .ask: "Ask first"
        case .off: "Ignore"
        }
    }
}

/// How to read a meeting app's own mute control through Accessibility.
///
/// Labels are matched as lowercase prefixes. Most apps label the button with the action it
/// performs, so a visible "Unmute…" control means the user is currently muted.
nonisolated struct MuteRule: Sendable, Hashable {
    enum Scope: Sendable, Hashable {
        /// Items of a menu-bar menu (nil = every menu).
        case menu(String?)
        /// Anything inside the app's windows.
        case windows
        /// Only inside web areas whose title or URL contains one of these strings.
        case webArea([String])
    }

    var scope: Scope
    var roles: Set<String>
    var mutedPrefixes: [String] = []
    var unmutedPrefixes: [String] = []
    /// Toggles (exact label) whose AXValue == 1 means muted, e.g. Discord's "Mute"/"Deafen" switches.
    var mutedWhenChecked: [String] = []
    /// Menu items (exact label) that show a check mark while muted.
    var mutedWhenMarked: [String] = []
}

nonisolated struct CallApp: Sendable, Hashable, Identifiable {
    enum Confirmation: Sendable, Hashable {
        /// Holding the microphone is enough.
        case micOnly
        /// Zoom shows a "Meeting" menu only while in a meeting.
        case zoomMeetingMenu
        /// Slack shows a "Leave huddle" control only during a huddle.
        case slackHuddle
        /// A browser tab whose URL matches the meeting pattern.
        case webTab
    }

    let id: String
    let name: String
    /// Bundle IDs of the app owning the call (helper processes are mapped to their app first).
    var bundleIDs: [String] = []
    /// System processes that carry this app's call audio (FaceTime).
    var processBundleIDs: [String] = []
    /// Regex for meeting URLs when the app runs in a browser.
    var urlPattern: String?
    /// Regex for the browser window title while in a call (read through Accessibility, no prompt).
    var titlePattern: String?
    var defaultPolicy: AppPolicy
    var confirmation: Confirmation = .micOnly
    /// Apps that load their UI from the web need Electron's AXManualAccessibility switched on.
    var needsElectronAccessibility = false
    var muteRules: [MuteRule] = []

    var isWeb: Bool { urlPattern != nil }
}

nonisolated enum AppCatalog {
    static let apps: [CallApp] = [
        CallApp(
            id: "zoom", name: "Zoom", bundleIDs: ["us.zoom.xos"],
            defaultPolicy: .auto, confirmation: .zoomMeetingMenu,
            muteRules: [
                MuteRule(scope: .menu("Meeting"), roles: ["AXMenuItem"],
                         mutedPrefixes: ["unmute audio", "join audio"], unmutedPrefixes: ["mute audio"]),
                MuteRule(scope: .windows, roles: ["AXButton"],
                         mutedPrefixes: ["unmute my audio", "unmute"], unmutedPrefixes: ["mute my audio"]),
            ]),
        CallApp(
            id: "meet", name: "Google Meet",
            urlPattern: #"^https://meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})"#,
            titlePattern: #"^Meet\s*[-–—]\s*([a-z]{3}-[a-z]{4}-[a-z]{3})?"#,
            defaultPolicy: .auto, confirmation: .webTab,
            muteRules: [
                MuteRule(scope: .webArea(["meet.google.com", "meet -", "meet –", "google meet"]), roles: ["AXButton", "AXCheckBox"],
                         mutedPrefixes: ["turn on microphone"], unmutedPrefixes: ["turn off microphone"]),
            ]),
        CallApp(
            id: "teams", name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
            defaultPolicy: .auto, needsElectronAccessibility: true,
            muteRules: [
                MuteRule(scope: .windows, roles: ["AXButton", "AXCheckBox"],
                         mutedPrefixes: ["unmute mic", "unmute microphone", "unmute ("],
                         unmutedPrefixes: ["mute mic", "mute microphone", "mute ("]),
            ]),
        CallApp(
            id: "teams-web", name: "Microsoft Teams (web)",
            urlPattern: #"^https://teams\.(microsoft|live)\.com/"#,
            defaultPolicy: .auto, confirmation: .webTab),
        CallApp(
            id: "zoom-web", name: "Zoom (web)",
            urlPattern: #"^https://(app\.)?zoom\.us/wc/"#,
            defaultPolicy: .auto, confirmation: .webTab),
        CallApp(
            id: "slack", name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"],
            defaultPolicy: .auto, confirmation: .slackHuddle, needsElectronAccessibility: true,
            muteRules: [
                MuteRule(scope: .windows, roles: ["AXButton", "AXCheckBox"],
                         mutedPrefixes: ["unmute microphone", "unmute mic", "turn on microphone"],
                         unmutedPrefixes: ["mute microphone", "mute mic", "turn off microphone"]),
            ]),
        CallApp(
            id: "discord", name: "Discord", bundleIDs: ["com.hnc.Discord"],
            defaultPolicy: .ask, needsElectronAccessibility: true,
            muteRules: [
                MuteRule(scope: .windows, roles: ["AXCheckBox", "AXButton", "AXSwitch"],
                         mutedPrefixes: ["unmute", "undeafen"], mutedWhenChecked: ["mute", "deafen"]),
            ]),
        CallApp(
            id: "whatsapp", name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp"],
            defaultPolicy: .ask,
            muteRules: [
                MuteRule(scope: .windows, roles: ["AXButton", "AXCheckBox"],
                         mutedPrefixes: ["turn on mic", "unmute"], unmutedPrefixes: ["turn off mic", "mute"]),
            ]),
        CallApp(
            id: "telegram", name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram", "com.tdesktop.Telegram"],
            defaultPolicy: .ask),
        CallApp(
            id: "facetime", name: "FaceTime", bundleIDs: ["com.apple.FaceTime"],
            processBundleIDs: ["com.apple.avconferenced", "com.apple.TelephonyUtilities", "com.apple.FTConversationService"],
            defaultPolicy: .ask,
            muteRules: [
                MuteRule(scope: .menu(nil), roles: ["AXMenuItem"],
                         mutedPrefixes: ["unmute"], unmutedPrefixes: ["mute"], mutedWhenMarked: ["mute"]),
            ]),
    ]

    static func app(id: String) -> CallApp? { apps.first { $0.id == id } }

    /// The native call app owning `bundleID` (an app or one of its call processes).
    static func nativeApp(for bundleID: String) -> CallApp? {
        apps.first { $0.bundleIDs.contains(bundleID) || $0.processBundleIDs.contains(bundleID) }
    }

    static var webApps: [CallApp] { apps.filter(\.isWeb) }

    /// Browsers whose tabs Minutes can read (Chromium family and Safari).
    static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "com.apple.Safari": "Safari",
        "com.microsoft.edgemac": "Edge",
        "com.brave.Browser": "Brave",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
    ]

    /// Processes that use the microphone without being a call.
    static let ignoredProcesses: Set<String> = [
        Paths.bundleID,
        "com.apple.CoreSpeech", "com.apple.assistantd", "com.apple.Siri", "com.apple.SiriNCService",
        "com.apple.accessibility.heard", "com.apple.dictation", "com.apple.SpeechRecognitionCore.speechrecognitiond",
        "com.apple.VoiceMemos", "com.apple.controlcenter", "com.apple.systemsound",
    ]

    /// Apps never recorded as meeting audio (music playing in the background).
    static let excludedFromRecording: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.apple.podcasts",
    ]
}
