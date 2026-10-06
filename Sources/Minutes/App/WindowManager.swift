import AppKit
import SwiftUI

/// Opens the app's windows from anywhere (menu, notifications, hotkeys). While a window is open,
/// Minutes shows in the Dock and the app switcher; it goes back to being menu-bar-only afterwards.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func showHistory(select meetingID: UUID? = nil) {
        if let meetingID { AppModel.shared.historySelection = meetingID }
        show(id: "history", title: "Minutes", size: NSSize(width: 980, height: 660), minSize: NSSize(width: 720, height: 460)) {
            HistoryView()
        }
    }

    func showSettings() {
        show(id: "settings", title: "Minutes Settings", size: NSSize(width: 640, height: 560), minSize: NSSize(width: 560, height: 440),
             resizable: true) {
            SettingsView()
        }
    }

    func showOnboarding() {
        show(id: "onboarding", title: "Welcome to Minutes", size: NSSize(width: 560, height: 600), minSize: NSSize(width: 520, height: 540)) {
            OnboardingView()
        }
    }

    func close(_ id: String) { windows[id]?.close() }

    private func show<Content: View>(id: String, title: String, size: NSSize, minSize: NSSize, resizable: Bool = true,
                                     @ViewBuilder content: () -> Content) {
        NSApp.setActivationPolicy(.regular)
        if let window = windows[id] {
            bringToFront(window)
            return
        }
        let host = NSHostingController(rootView: content().environment(AppModel.shared))
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable]
        window.setContentSize(size)
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        // Open in the Space the user is in (macOS switches away from a full-screen app's Space).
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.setFrameAutosaveName("Minutes.\(id)")
        if !window.setFrameUsingName("Minutes.\(id)") { window.center() }
        windows[id] = window
        bringToFront(window)
    }

    /// Activation is cooperative on recent macOS, so a menu-bar app also has to order its window
    /// in explicitly or it can stay hidden behind the frontmost app.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
