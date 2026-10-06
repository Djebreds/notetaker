import SwiftUI

/// The popover under the menu-bar icon.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let session = model.session

        VStack(alignment: .leading, spacing: 12) {
            header

            if !model.settings.onboardingDone {
                Button {
                    WindowManager.shared.showOnboarding()
                } label: {
                    Label("Finish setup…", systemImage: "checklist").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            if session.isRecording {
                recordingPanel
            } else if let ask = session.pendingAsk {
                askPanel(ask)
            }

            controls

            Toggle("Start automatically when a call begins", isOn: $settings.autoDetect)
                .toggleStyle(.switch)
                .controlSize(.small)

            problems

            Divider()
            recent
            Divider()

            HStack {
                Button("History…") { WindowManager.shared.showHistory() }
                Button("Settings…") { WindowManager.shared.showSettings() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 330)
        .onAppear { model.permissions.refresh() }
    }

    // MARK: Sections

    private var header: some View {
        let session = model.session
        return HStack(spacing: 8) {
            Circle()
                .fill(session.isRecording ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.isRecording {
                Text(Format.duration(session.elapsed))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        let session = model.session
        switch session.phase {
        case .starting: return "Starting…"
        case .stopping: return "Saving…"
        case .recording: return "Taking notes" + (session.active?.call.map { " · \($0.app.name)" } ?? "")
        case .idle:
            if let processing = model.store.meetings.first(where: \.isProcessing) {
                return processing.status == .summarizing ? "Writing notes…" : "Transcribing \(processing.progressText ?? "")…"
            }
            return "Minutes"
        }
    }

    private var subtitle: String {
        let session = model.session
        if session.isRecording {
            return session.active?.trigger == .auto ? "Stops by itself when the call ends" : "Started manually"
        }
        if let call = model.detector.current { return "In a call on \(call.name)" }
        return model.settings.autoDetect ? "Listening for calls" : "Auto-start is off"
    }

    private var recordingPanel: some View {
        let session = model.session
        let mute = model.mute
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: mute.micExcluded ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(mute.micExcluded ? .red : .green)
                Text(micText).font(.callout)
                Spacer()
                Button(mute.manualExclude ? "Include mic" : "Exclude mic") { session.toggleMicExclusion() }
                    .controlSize(.small)
                    .help("Leave your voice out of the transcript (\(model.settings.micShortcut?.display ?? "no shortcut"))")
            }
            LevelMeter(label: "Me", level: mute.micExcluded ? 0 : session.meterMe)
            LevelMeter(label: "Others", level: session.meterOthers)
            if let problem = session.health.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if session.health.systemAudio == .restarting || session.health.microphone == .restarting {
                Label("Reconnecting audio…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var micText: String {
        let mute = model.mute
        if mute.manualExclude { return "Your mic is excluded (manual)" }
        switch mute.state {
        case .muted(let source): return "Muted — \(source)"
        case .unmuted(let source): return "Unmuted — \(source)"
        case .unknown: return model.session.active?.call == nil ? "Recording your mic" : "Mute state unknown — mic included"
        }
    }

    private func askPanel(_ call: CallDetector.Call) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Take notes for this \(call.app.name) call?").font(.callout.weight(.medium))
            HStack {
                Button("Record") { model.session.answerAsk(record: true) }.keyboardShortcut(.defaultAction)
                Button("Always for \(call.app.name)") { model.session.answerAsk(record: true, always: true) }
                Button("Not now") { model.session.answerAsk(record: false) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        let session = model.session
        return HStack {
            if session.isRecording {
                Button {
                    session.stop(discard: false)
                } label: {
                    Label("Stop & Save", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("Discard") { session.stop(discard: true) }
            } else {
                Button {
                    session.startManual()
                } label: {
                    Label("Start taking notes", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.phase != .idle)
            }
        }
        .controlSize(.large)
        .overlay(alignment: .bottomTrailing) {
            if let shortcut = model.settings.toggleShortcut {
                Text(shortcut.display).font(.caption2).foregroundStyle(.secondary).offset(y: 14)
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private var problems: some View {
        let permissions = model.permissions
        VStack(alignment: .leading, spacing: 6) {
            if permissions.microphone == .denied {
                ProblemRow(text: "Microphone access is off.", action: "Fix") { permissions.open(.microphone) }
            }
            if permissions.systemAudio == .denied {
                ProblemRow(text: "System audio recording is off.", action: "Fix") { permissions.open(.systemAudio) }
            }
            if permissions.accessibility == .denied {
                ProblemRow(text: "Accessibility is off, so mute detection can't work.", action: "Fix") { permissions.requestAccessibility() }
            }
            if !model.settings.hasOpenRouterKey {
                ProblemRow(text: "Add your OpenRouter API key to get transcripts.", action: "Add") { WindowManager.shared.showSettings() }
            } else if let problem = model.processing.lastProblem {
                ProblemRow(text: problem, action: "Settings") { WindowManager.shared.showSettings() }
            }
            ForEach(Array(model.detector.browserProblems.values).sorted(), id: \.self) { problem in
                ProblemRow(text: problem, action: "Fix") { permissions.open(.automation) }
            }
        }
    }

    private var recent: some View {
        let meetings = Array(model.store.meetings.prefix(5))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if meetings.isEmpty {
                Text("No meetings yet. Join a call, or press \(model.settings.toggleShortcut?.display ?? "Start").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(meetings) { meeting in
                Button {
                    WindowManager.shared.showHistory(select: meeting.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meeting.title).lineLimit(1)
                            Text(meeting.startedAt.formatted(.relative(presentation: .named)) + " · " + Format.minutes(meeting.duration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(meeting: meeting)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
