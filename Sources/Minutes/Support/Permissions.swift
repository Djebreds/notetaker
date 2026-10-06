import AppKit
import AVFAudio
import AVFoundation
import Observation
import UserNotifications

/// Checks and requests the permissions Minutes needs.
@MainActor @Observable
final class Permissions {
    enum State: Equatable {
        case granted, denied, notDetermined, unknown
        var isGranted: Bool { self == .granted }
    }

    private(set) var microphone: State = .unknown
    private(set) var systemAudio: State = .unknown
    private(set) var accessibility: State = .unknown
    private(set) var notifications: State = .unknown
    /// Automation (reading tabs) per running browser.
    private(set) var automation: [String: State] = [:]

    var essentialsGranted: Bool { microphone.isGranted && systemAudio != .denied }

    func refresh() {
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
        systemAudio = SystemAudioPermission.status
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notifications = switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: .granted
            case .denied: .denied
            case .notDetermined: .notDetermined
            @unknown default: .unknown
            }
        }
        refreshAutomation()
    }

    func refreshAutomation() {
        let browsers = AppCatalog.browsers.keys.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        Task.detached {
            var states: [String: State] = [:]
            for browser in browsers {
                states[browser] = switch BrowserTabs.automationAllowed(browser, ask: false) {
                case true: .granted
                case false: .denied
                default: .notDetermined
                }
            }
            await MainActor.run { self.automation = states }
        }
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    func requestSystemAudio() async {
        _ = await SystemAudioPermission.request()
        refresh()
    }

    func requestAccessibility() {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt (a mutable C global in Swift 6).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // The user grants it in System Settings; poll for a while so the UI updates by itself.
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                if AXIsProcessTrusted() { break }
            }
            refresh()
        }
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        refresh()
    }

    func requestAutomation(_ bundleID: String) async {
        await Task.detached { _ = BrowserTabs.automationAllowed(bundleID, ask: true) }.value
        refresh()
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case systemAudio = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
        case automation = "Privacy_Automation"
        case notifications
    }

    func open(_ pane: Pane) {
        let url: URL
        if pane == .notifications {
            url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Paths.bundleID)")!
        } else {
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        }
        NSWorkspace.shared.open(url)
    }
}

/// The "System Audio Recording Only" permission (kTCCServiceAudioCapture) has no public API, so this
/// uses the TCC framework's preflight/request functions, as the open-source AudioCap sample does.
nonisolated enum SystemAudioPermission {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @Sendable (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Permissions.State {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(symbol, to: Preflight.self)
        return switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: .granted
        case 1: .denied
        default: .notDetermined
        }
    }

    static func request() async -> Bool {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return false }
        let request = unsafeBitCast(symbol, to: Request.self)
        return await withCheckedContinuation { continuation in
            request("kTCCServiceAudioCapture" as CFString, nil) { granted in continuation.resume(returning: granted) }
        }
    }
}
