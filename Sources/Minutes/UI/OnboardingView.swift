import AppKit
import SwiftUI

/// First-run setup: permissions, API key, and a short audio check.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var keyMessage: String?
    @State private var check = AudioCheck()

    var body: some View {
        let p = model.permissions
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 44)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Minutes takes notes of your calls").font(.title2.weight(.semibold))
                        Text("Zoom, Google Meet, Slack huddles, Discord and more. No bots, no browser extensions.")
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("1 · Permissions") {
                    VStack(alignment: .leading, spacing: 10) {
                        permission("Microphone", "Your side of the call.", p.microphone) {
                            Task { p.microphone == .notDetermined ? await p.requestMicrophone() : p.open(.microphone) }
                        }
                        permission("System audio recording", "What the others say. macOS asks the first time audio is captured — the check below triggers it.", p.systemAudio) {
                            Task { p.systemAudio == .notDetermined ? await p.requestSystemAudio() : p.open(.systemAudio) }
                        }
                        permission("Accessibility", "Reads the meeting app's mute button and call controls.", p.accessibility) {
                            p.requestAccessibility()
                        }
                        permission("Notifications", "“Notes ready”, and asking before recording some apps.", p.notifications) {
                            Task { p.notifications == .notDetermined ? await p.requestNotifications() : p.open(.notifications) }
                        }
                        Text("Browsers ask separately (Automation) the first time Minutes looks for a Google Meet tab.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("2 · OpenRouter API key") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SecureField(model.settings.hasOpenRouterKey ? "Saved — paste to replace" : "sk-or-…", text: $key)
                            Button("Save") { saveKey() }.disabled(key.isEmpty)
                        }
                        if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
                        Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!).font(.caption)
                    }
                    .padding(6)
                }

                GroupBox("3 · Check audio") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Records 8 seconds (nothing is saved). Say something, and Minutes plays a chime to test meeting audio.")
                            .font(.callout).foregroundStyle(.secondary)
                        LevelMeter(label: "Me", level: check.me)
                        LevelMeter(label: "Others", level: check.others)
                        HStack {
                            Button(check.phase == .running ? "Listening…" : "Run check") { Task { await check.run() } }
                                .disabled(check.phase == .running)
                            if check.phase == .done {
                                result("Your mic", check.heardMe)
                                result("Meeting audio", check.heardOthers)
                            }
                        }
                        if let error = check.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        if check.phase == .done, !check.heardOthers {
                            Text("No meeting audio was heard. Allow Minutes under System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only, then run the check again.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(6)
                }

                GroupBox("4 · How to use it") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Join a call — notes start by themselves (or press \(model.settings.toggleShortcut?.display ?? "the menu-bar button")).", systemImage: "phone")
                        Label("Muted in the call? Your voice is left out. \(model.settings.micShortcut?.display ?? "") excludes your mic by hand.", systemImage: "mic.slash")
                        Label("When the call ends, notes appear in History — download any of them as .md.", systemImage: "doc.text")
                    }
                    .padding(6)
                }

                HStack {
                    Spacer()
                    Button("Done") {
                        model.settings.onboardingDone = true
                        WindowManager.shared.close("onboarding")
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                }
            }
            .padding(24)
        }
        .onAppear { p.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in p.refresh() }
    }

    private func permission(_ title: String, _ detail: String, _ state: Permissions.State, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: state.isGranted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(state.isGranted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !state.isGranted { Button(state == .notDetermined ? "Allow…" : "Open Settings", action: action).controlSize(.small) }
        }
    }

    private func result(_ label: String, _ ok: Bool) -> some View {
        Label(label, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? .green : .orange)
    }

    private func saveKey() {
        do {
            try model.settings.saveOpenRouterKey(key)
            key = ""
            keyMessage = "Checking…"
            Task {
                do {
                    keyMessage = try await OpenRouterClient.fromKeychain().checkKey()
                } catch {
                    keyMessage = error.localizedDescription
                }
            }
        } catch {
            keyMessage = error.localizedDescription
        }
    }
}

/// Records a few seconds into a throwaway folder to show both capture paths work.
@MainActor @Observable
final class AudioCheck {
    enum Phase { case idle, running, done }

    private(set) var phase = Phase.idle
    private(set) var me: Float = 0
    private(set) var others: Float = 0
    private(set) var heardMe = false
    private(set) var heardOthers = false
    private(set) var error: String?

    func run() async {
        phase = .running
        heardMe = false
        heardOthers = false
        error = nil
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-check-\(UUID().uuidString)")
        let recorder = Recorder(meetingFolder: folder, sessionStartHost: HostClock.now, excludedBundleIDs: [],
                                mask: { _, _ in [] }, onChunk: { _ in }, onHealth: { _ in })
        do {
            try await recorder.start()
        } catch {
            self.error = error.localizedDescription
            phase = .done
            return
        }
        for step in 0..<40 {
            if step == 10 || step == 22 { Self.playChime() }
            try? await Task.sleep(for: .milliseconds(200))
            let levels = recorder.takeLevels()
            me = max(levels.me * 3, me * 0.7)
            others = max(levels.others * 3, others * 0.7)
            if levels.me > 0.02 { heardMe = true }
            if levels.others > 0.02 { heardOthers = true }
        }
        await recorder.stop()
        try? FileManager.default.removeItem(at: folder)
        me = 0
        others = 0
        phase = .done
    }

    /// Played by another process: Minutes never records its own sound.
    private static func playChime() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = ["/System/Library/Sounds/Glass.aiff"]
        try? process.run()
    }
}
