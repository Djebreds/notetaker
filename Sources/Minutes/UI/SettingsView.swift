import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            PrivacySettings().tabItem { Label("Privacy & Storage", systemImage: "lock.shield") }
            PermissionsSettings().tabItem { Label("Permissions", systemImage: "checkmark.shield") }
            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .scenePadding()
        .frame(minWidth: 540, minHeight: 420)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Keyboard shortcuts") {
                LabeledContent("Start / stop taking notes") {
                    ShortcutRecorder(shortcut: $settings.toggleShortcut)
                }
                LabeledContent("Exclude / include my mic") {
                    ShortcutRecorder(shortcut: $settings.micShortcut)
                }
            }
            .onChange(of: settings.toggleShortcut) { model.registerHotKeys() }
            .onChange(of: settings.micShortcut) { model.registerHotKeys() }

            Section {
                Toggle("Start automatically when a call begins", isOn: $settings.autoDetect)
                ForEach(AppCatalog.apps) { app in
                    Picker(app.name, selection: Binding(
                        get: { settings.policy(for: app) },
                        set: { settings.setPolicy($0, for: app) })) {
                        ForEach(AppPolicy.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!settings.autoDetect)
                }
            } header: {
                Text("Calls")
            } footer: {
                Text("“Ask first” shows a notification and records nothing until you choose Record. Recording stops by itself when the call ends.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open Minutes at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI

@MainActor @Observable
final class ModelCatalog {
    private(set) var models: [ORModel] = []
    private(set) var error: String?
    private(set) var loading = false

    func load() async {
        guard models.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            models = try await OpenRouterClient.models()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Speech-to-text models first, then audio-capable chat models by price.
    var audioModels: [ORModel] {
        let stt = models.filter(\.isSpeechToText).sorted { $0.id < $1.id }
        let chat = models.filter { $0.acceptsAudio && $0.producesText && !$0.isSpeechToText && !$0.id.hasSuffix(":free") && !$0.id.hasPrefix("openrouter/") }
            .sorted { ($0.audioPrice > 0 ? $0.audioPrice : $0.promptPrice) < ($1.audioPrice > 0 ? $1.audioPrice : $1.promptPrice) }
        return stt + chat
    }

    var textModels: [ORModel] {
        models.filter { $0.producesText && $0.contextLength >= 128_000 && !$0.id.hasSuffix(":free") && !$0.id.hasPrefix("openrouter/") }
            .sorted { $0.completionPrice < $1.completionPrice }
    }

    func model(_ id: String) -> ORModel? { models.first { $0.id == id } }

    static func price(_ model: ORModel, audio: Bool) -> String {
        if model.isSpeechToText { return "speech-to-text, billed by audio length" }
        let input = audio && model.audioPrice > 0 ? model.audioPrice : model.promptPrice
        return String(format: "$%.2f in · $%.2f out per 1M", input, model.completionPrice)
    }
}

private struct AISettings: View {
    @Environment(AppModel.self) private var model
    @State private var catalog = ModelCatalog()
    @State private var key = ""
    @State private var keyStatus: String?
    @State private var testing = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                HStack {
                    SecureField(settings.hasOpenRouterKey ? "Saved in Keychain — paste to replace" : "sk-or-…", text: $key)
                    Button("Save") { saveKey() }.disabled(key.isEmpty)
                    Button(testing ? "Testing…" : "Test") { test() }.disabled(testing || (!settings.hasOpenRouterKey && key.isEmpty))
                }
                if let keyStatus { Text(keyStatus).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("OpenRouter API key")
            } footer: {
                Link("Create a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!).font(.caption)
            }

            Section {
                modelField("Transcription", value: $settings.transcriptionModel, options: catalog.audioModels, audio: true,
                           defaultID: AppSettings.defaultTranscriptionModel)
                modelField("Notes", value: $settings.notesModel, options: catalog.textModels, audio: false,
                           defaultID: AppSettings.defaultNotesModel)
            } header: {
                Text("Models")
            } footer: {
                Text("Transcription takes a speech-to-text model (MAI-Transcribe 2: precise timings and speakers) or an audio-capable chat model (Gemini Flash-Lite). Cost is shown on each meeting.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Your name", text: $settings.userName, prompt: Text("as people say it in calls, e.g. Refi"))
                TextField("Your role", text: $settings.userRole, prompt: Text("e.g. Backend software engineer"))
                TextField("Your focus", text: $settings.userFocus, prompt: Text("optional, e.g. payments API, mobile app, infrastructure"))
            } header: {
                Text("About you")
            } footer: {
                Text("The summary stays a general overview. Key points, decisions, action items and open questions are written for you, with your own tasks first. Use Regenerate Notes on a meeting to apply changes to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Recognise speakers by voice", isOn: $settings.recognizeSpeakers)
                if model.voices.profiles.isEmpty {
                    Text("No voices yet. Click a speaker's name in a transcript to name them.").foregroundStyle(.secondary)
                }
                ForEach(model.voices.profiles.sorted { $0.name < $1.name }) { person in
                    HStack {
                        Image(systemName: "person.wave.2").foregroundStyle(.secondary)
                        Text(person.name)
                        Text("\(person.samples) meeting\(person.samples == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { model.voices.delete(person.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Forget this voice")
                    }
                }
            } header: {
                Text("Speakers")
            } footer: {
                Text("Runs on your Mac after each meeting (FluidAudio speaker models, ~22 MB, downloaded once; CC-BY-4.0). Voices are stored only on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notes") {
                Toggle("Hide filler lines (Mm, Okay, Yeah…) in transcripts and exports", isOn: $settings.hideFillerLines)
                Picker("Write notes in", selection: $settings.notesLanguage) {
                    ForEach(NotesLanguage.allCases) { Text($0.label).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra instructions for the notes (optional)")
                    TextEditor(text: $settings.customInstructions)
                        .font(.body)
                        .frame(minHeight: 60)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    Text("For example: “Focus on engineering decisions and list blockers separately.”")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await catalog.load() }
    }

    private func modelField(_ title: String, value: Binding<String>, options: [ORModel], audio: Bool, defaultID: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                TextField("model id", text: value).textFieldStyle(.roundedBorder)
                Menu("Choose") {
                    Button("Recommended: \(defaultID)") { value.wrappedValue = defaultID }
                    Divider()
                    ForEach(options.prefix(60)) { option in
                        Button("\(option.id) — \(ModelCatalog.price(option, audio: audio))") { value.wrappedValue = option.id }
                    }
                }
                .fixedSize()
                .disabled(catalog.models.isEmpty)
            }
            if audio, !TranscriberFactory.labelsSpeakers(value.wrappedValue) {
                Text("This model can't tell speakers apart, and may invent words like “Thank you.” in silence. MAI-Transcribe 2 is recommended.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let info = catalog.model(value.wrappedValue) {
                Text(ModelCatalog.price(info, audio: audio)).font(.caption).foregroundStyle(.secondary)
            } else if !catalog.models.isEmpty {
                Text("Not found in OpenRouter's catalog.").font(.caption).foregroundStyle(.orange)
            } else if let error = catalog.error {
                Text("Couldn't load models: \(error)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveKey() {
        do {
            try model.settings.saveOpenRouterKey(key)
            key = ""
            keyStatus = "Saved in Keychain."
            test()
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    private func test() {
        let candidate = key.isEmpty ? nil : key.trimmingCharacters(in: .whitespacesAndNewlines)
        testing = true
        Task {
            defer { testing = false }
            do {
                let client = try candidate.map { OpenRouterClient(apiKey: $0) } ?? OpenRouterClient.fromKeychain()
                keyStatus = try await client.checkKey()
            } catch {
                keyStatus = error.localizedDescription
            }
        }
    }
}

// MARK: - Privacy & storage

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var storageUsed: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Only use providers that keep no data (zero data retention)", isOn: $settings.zeroDataRetention)
            } footer: {
                Text("Audio and transcripts are sent to OpenRouter only to be processed. With this on, requests go only to endpoints that don't store or train on them; some models are unavailable then.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Recordings", selection: $settings.audioRetention) {
                    ForEach(AudioRetention.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.audioRetention) { model.store.applyRetention(settings.audioRetention) }
                LabeledContent("Space used") { Text(storageUsed ?? "…") }
                Button("Show meetings folder in Finder") { NSWorkspace.shared.open(Paths.meetings) }
            } header: {
                Text("Storage")
            } footer: {
                Text("Notes and transcripts stay until you delete the meeting. Keeping audio lets you re-run a transcription.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            let bytes = await Task.detached { Self.folderSize(Paths.meetings) }.value
            storageUsed = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    nonisolated private static func folderSize(_ url: URL) -> Int64 {
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - Permissions

struct PermissionsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.permissions
        Form {
            Section {
                row("Microphone", "Records your side of the call.", p.microphone) {
                    if p.microphone == .notDetermined { Task { await p.requestMicrophone() } } else { p.open(.microphone) }
                }
                row("System audio recording", "Records what the other participants say.", p.systemAudio) {
                    if p.systemAudio == .notDetermined { Task { await p.requestSystemAudio() } } else { p.open(.systemAudio) }
                }
                row("Accessibility", "Reads the meeting app's mute button and call controls.", p.accessibility) {
                    p.requestAccessibility()
                }
                row("Notifications", "Tells you when notes are ready and asks before recording some apps.", p.notifications) {
                    if p.notifications == .notDetermined { Task { await p.requestNotifications() } } else { p.open(.notifications) }
                }
            }
            Section {
                if p.automation.isEmpty {
                    Text("Open your browser to set this up.").foregroundStyle(.secondary)
                }
                ForEach(p.automation.keys.sorted(), id: \.self) { browser in
                    row(AppCatalog.browsers[browser] ?? browser, "Reads open tabs to recognise Google Meet calls.", p.automation[browser] ?? .unknown) {
                        if p.automation[browser] == .notDetermined { Task { await p.requestAutomation(browser) } } else { p.open(.automation) }
                    }
                }
            } header: {
                Text("Browsers (Automation)")
            }
        }
        .formStyle(.grouped)
        .onAppear { p.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in p.refresh() }
    }

    private func row(_ title: String, _ detail: String, _ state: Permissions.State, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: state.isGranted ? "checkmark.circle.fill" : (state == .denied ? "xmark.circle.fill" : "circle.dashed"))
                .foregroundStyle(state.isGranted ? .green : (state == .denied ? .red : .secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !state.isGranted {
                Button(state == .notDetermined ? "Allow…" : "Open Settings", action: action).controlSize(.small)
            }
        }
    }
}
