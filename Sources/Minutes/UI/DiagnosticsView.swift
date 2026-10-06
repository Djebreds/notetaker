import AppKit
import SwiftUI

/// What the detectors see right now, plus tools to fix detection rules when an app changes its UI.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var dumpTarget = ""
    @State private var dumpStatus: String?

    var body: some View {
        let detector = model.detector
        let session = model.session
        Form {
            Section("Audio right now") {
                LabeledContent("Using the microphone") {
                    Text(detector.activity.micUsers.map(\.name).joined(separator: ", ").nilIfBlank ?? "nobody")
                }
                LabeledContent("Playing sound") {
                    Text(detector.activity.outputApps.map(\.name).joined(separator: ", ").nilIfBlank ?? "nothing")
                        .lineLimit(2)
                }
                LabeledContent("Detected call") {
                    Text(detector.current.map { "\($0.name)\($0.meetingCode.map { " (\($0))" } ?? "")" } ?? "none")
                }
            }
            Section("Recording") {
                LabeledContent("State") { Text(String(describing: session.phase)) }
                LabeledContent("Mute") { Text(muteText) }
                LabeledContent("System audio") { Text(session.health.systemAudio.rawValue + (session.health.outputDevice.map { " · \($0)" } ?? "")) }
                LabeledContent("Microphone") { Text(session.health.microphone.rawValue + (session.health.micDevice.map { " · \($0)" } ?? "")) }
                if let problem = session.health.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            }
            Section {
                HStack {
                    Picker("App", selection: $dumpTarget) {
                        Text("Choose…").tag("")
                        ForEach(runningCallApps, id: \.self) { bundleID in
                            Text(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID)
                                .tag(bundleID)
                        }
                    }
                    Button("Save Accessibility Tree") { dump() }.disabled(dumpTarget.isEmpty)
                }
                if let dumpStatus { Text(dumpStatus).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Detection rules")
            } footer: {
                Text("If mute detection stops working after an app update, join a call in that app, save its tree, and look for the mute button's label.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Open Log Folder") { NSWorkspace.shared.open(Paths.logs) }
            }
        }
        .formStyle(.grouped)
    }

    private var muteText: String {
        if model.mute.manualExclude { return "mic excluded (manual)" }
        switch model.mute.state {
        case .muted(let s): return "muted · \(s)"
        case .unmuted(let s): return "unmuted · \(s)"
        case .unknown: return "unknown"
        }
    }

    private var runningCallApps: [String] {
        let ids = AppCatalog.apps.flatMap(\.bundleIDs) + Array(AppCatalog.browsers.keys)
        return ids.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }.sorted()
    }

    private func dump() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: dumpTarget).first else { return }
        let pid = app.processIdentifier
        let name = app.localizedName ?? dumpTarget
        let electron = AppCatalog.nativeApp(for: dumpTarget)?.needsElectronAccessibility ?? false
        dumpStatus = "Reading \(name)…"
        Task.detached {
            let axApp = AX.application(pid, timeout: 2)
            if electron { AX.setFlag(axApp, "AXManualAccessibility", true) }
            var text = "Accessibility tree of \(name) (pid \(pid)) at \(Date())\n\n== Menu bar ==\n"
            for item in AX.menuBarItems(axApp) { text += AX.dump(item, maxNodes: 400) + "\n" }
            text += "\n== Windows ==\n"
            for window in AX.windows(axApp) { text += AX.dump(window, maxNodes: 8_000) + "\n\n" }
            let url = Paths.ensure(Paths.diagnostics).appendingPathComponent("ax-\(name)-\(Int(Date().timeIntervalSince1970)).txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            await MainActor.run {
                dumpStatus = "Saved \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}
