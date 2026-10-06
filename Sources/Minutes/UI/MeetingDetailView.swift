import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    let meetingID: UUID
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.notes
    @State private var title = ""
    @State private var notes: MeetingNotes?
    @State private var transcript: [TranscriptSegment] = []
    @State private var speakers: SpeakerAnalysis?
    @State private var confirmDelete = false
    @State private var copied = false

    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes", transcript = "Transcript"
        var id: String { rawValue }
    }

    var body: some View {
        if let meeting = model.store.meeting(meetingID) {
            VStack(alignment: .leading, spacing: 0) {
                header(meeting)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case .notes: notesContent(meeting)
                        case .transcript:
                            TranscriptView(segments: model.settings.hideFillerLines
                                           ? transcript.filter { !TranscriptMerger.isFillerOnly($0.text) } : transcript,
                                           meeting: meeting, speakers: speakers)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toolbar { toolbar(meeting) }
            .onAppear { reload(meeting) }
            .onChange(of: model.store.lastChange) { reload(meeting) }
            .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { model.store.delete(meetingID) }
            } message: {
                Text("Its notes, transcript and audio are moved to the Trash.")
            }
        }
    }

    // MARK: Header

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .onSubmit {
                    let new = title.trimmingCharacters(in: .whitespaces)
                    guard !new.isEmpty else { return }
                    model.store.update(meetingID) { m in
                        m.title = new
                        m.titleEdited = true
                    }
                }
            HStack(spacing: 6) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(Format.minutes(meeting.duration))
                if let app = meeting.appName {
                    Text("·")
                    Text(app)
                }
                if meeting.costUSD > 0 {
                    Text("·")
                    Text(Format.cost(meeting.costUSD)).help(modelsHelp(meeting))
                }
                if meeting.audioDeleted {
                    Text("·")
                    Text("audio deleted")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            statusBanner(meeting)
            if meeting.notesOutdated == true, meeting.status == .done {
                HStack(spacing: 8) {
                    Label("Speaker names changed since these notes were written.", systemImage: "person.2.badge.gearshape")
                        .foregroundStyle(.secondary)
                    Button("Update notes") { model.processing.regenerateNotes(meetingID) }
                }
            }
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                if let speakers, !meeting.audioDeleted {
                    Menu {
                        Button("Automatic") { model.processing.reidentify(meetingID, count: nil) }
                        Divider()
                        ForEach(1...8, id: \.self) { n in
                            Button("\(n) voice\(n == 1 ? "" : "s")") { model.processing.reidentify(meetingID, count: n) }
                        }
                    } label: {
                        Label("\(speakers.speakers.count) voices" + (speakers.expectedCount == nil ? "" : " (set)"),
                              systemImage: "person.wave.2")
                    }
                    .fixedSize()
                    .disabled(meeting.isProcessing)
                    .help("Run speaker recognition again with a set number of voices (other people only)")
                }
            }
        }
    }

    private func modelsHelp(_ meeting: Meeting) -> String {
        "Transcription: \(meeting.transcriptionModel ?? "–")\nNotes: \(meeting.notesModel ?? "–")"
    }

    @ViewBuilder private func statusBanner(_ meeting: Meeting) -> some View {
        switch meeting.status {
        case .recording:
            Label(model.session.active?.meetingID == meetingID ? "Recording now — the transcript fills in every few minutes."
                                                                : "Recording was interrupted; it will be recovered.",
                  systemImage: "record.circle").foregroundStyle(.red)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing \(meeting.progressText ?? "")…")
            }
            .foregroundStyle(.secondary)
        case .summarizing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing notes…")
            }
            .foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 8) {
                Label(meeting.statusDetail ?? "Something went wrong.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Retry") { retry(meeting) }
            }
        case .done:
            if let detail = meeting.statusDetail {
                HStack(spacing: 8) {
                    Label(detail, systemImage: "info.circle").foregroundStyle(.secondary)
                    if meeting.failedTrackCount > 0, !meeting.audioDeleted { Button("Retry") { model.processing.retryFailed(meetingID) } }
                }
            }
        }
    }

    // MARK: Notes

    @ViewBuilder private func notesContent(_ meeting: Meeting) -> some View {
        if let notes {
            NotesView(notes: notes)
        } else if meeting.status == .done || meeting.status == .failed {
            ContentUnavailableView("No notes", systemImage: "doc.text",
                                   description: Text(transcript.isEmpty ? "No speech was transcribed." : "Use Regenerate Notes to write them."))
        } else {
            ContentUnavailableView("Notes are on their way", systemImage: "hourglass",
                                   description: Text("They're written as soon as the transcript is complete."))
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private func toolbar(_ meeting: Meeting) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                download(meeting)
            } label: {
                Label("Download .md", systemImage: "square.and.arrow.down")
            }
            .help("Save these notes as a Markdown file")

            Button {
                let md = MarkdownExporter.markdown(meeting: meeting, notes: notes, transcript: transcript, includeTranscript: tab == .transcript,
                                                  hideFillers: model.settings.hideFillerLines)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(md, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy Markdown", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy as Markdown")

            Menu {
                Button("Regenerate Notes") { model.processing.regenerateNotes(meetingID) }
                    .disabled(meeting.isProcessing || meeting.status == .recording || transcript.isEmpty)
                Button("Re-transcribe with \(model.settings.transcriptionModel)") { model.processing.retranscribe(meetingID) }
                    .disabled(meeting.audioDeleted || meeting.isProcessing || meeting.status == .recording)
                Button("Retry Failed Parts") { model.processing.retryFailed(meetingID) }
                    .disabled(meeting.failedTrackCount == 0 || meeting.audioDeleted || meeting.isProcessing)
                Divider()
                Button("Show in Finder") { model.store.revealInFinder(meetingID) }
                Button("Delete Audio") { model.store.deleteAudio(meetingID) }
                    .disabled(meeting.audioDeleted || meeting.status != .done)
                Divider()
                Button("Delete Meeting…", role: .destructive) { confirmDelete = true }
                    .disabled(meeting.status == .recording)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func retry(_ meeting: Meeting) {
        if meeting.failedTrackCount > 0, !meeting.audioDeleted {
            model.processing.retryFailed(meetingID)
        } else {
            model.processing.regenerateNotes(meetingID)
        }
    }

    private func reload(_ meeting: Meeting) {
        title = model.store.meeting(meetingID)?.title ?? meeting.title
        notes = model.store.notes(meetingID)
        transcript = model.store.transcript(meetingID)
        speakers = model.store.speakers(meetingID)
    }

    /// Save panel with an "Include transcript" option.
    private func download(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = MarkdownExporter.fileName(meeting: meeting, title: notes?.title ?? meeting.title)
        panel.canCreateDirectories = true
        let include = NSButton(checkboxWithTitle: "Include transcript", target: nil, action: nil)
        include.state = .on
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 34))
        include.frame.origin = NSPoint(x: 10, y: 8)
        accessory.addSubview(include)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let md = MarkdownExporter.markdown(meeting: meeting, notes: notes, transcript: transcript,
                                           includeTranscript: include.state == .on, hideFillers: model.settings.hideFillerLines)
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// The structured notes, laid out natively.
struct NotesView: View {
    let notes: MeetingNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !notes.summary.isEmpty {
                section("Summary") {
                    Text(notes.summary).fixedSize(horizontal: false, vertical: true)
                }
            }
            bullets("Key points", notes.keyPoints)
            bullets("Decisions", notes.decisions, symbol: "checkmark.seal")
            if !notes.actionItems.isEmpty {
                section("Action items") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes.actionItems, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "square").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.task)
                                    let meta = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }
                                    if !meta.isEmpty {
                                        Text(meta.joined(separator: " · "))
                                            .font(.callout)
                                            .foregroundStyle(item.owner == "Me" ? Color.accentColor : .secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            bullets("Open questions", notes.openQuestions, symbol: "questionmark.circle")
            if let discussion = notes.discussion, !discussion.isEmpty {
                section("Discussion") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(discussion, id: \.self) { topic in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(topic.topic).font(.subheadline.weight(.semibold))
                                ForEach(topic.points, id: \.self) { point in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary).frame(width: 14)
                                        Text(point).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !notes.participants.isEmpty {
                section("Participants") {
                    Text(notes.participants.joined(separator: ", ")).foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func bullets(_ title: String, _ items: [String], symbol: String = "circle.fill") -> some View {
        if !items.isEmpty {
            section(title) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: symbol)
                                .font(symbol == "circle.fill" ? .system(size: 5) : .callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Text(item).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

/// Timestamped transcript with speakers coloured and muted stretches marked.
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let meeting: Meeting
    var speakers: SpeakerAnalysis?
    @State private var naming: String?

    private enum Row: Identifiable {
        case line(TranscriptSegment)
        case muted(MuteInterval)
        var id: String {
            switch self {
            case .line(let s): s.id
            case .muted(let m): "muted-\(m.start)"
            }
        }
    }

    var body: some View {
        if segments.isEmpty {
            ContentUnavailableView(meeting.isProcessing || meeting.status == .recording ? "Transcribing…" : "No transcript",
                                   systemImage: "text.alignleft",
                                   description: Text(meeting.isProcessing || meeting.status == .recording
                                                     ? "Lines appear here as each part of the call is transcribed."
                                                     : "No speech was transcribed in this recording."))
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    switch row {
                    case .line(let segment):
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Timecode.format(segment.start))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 62, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                speakerLabel(segment)
                                Text(segment.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    case .muted(let interval):
                        Label("You were muted \(Timecode.format(interval.start))–\(Timecode.format(interval.end ?? meeting.duration))",
                              systemImage: "mic.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 74)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private func speakerLabel(_ segment: TranscriptSegment) -> some View {
        let label = Text(segment.speaker)
            .font(.callout.weight(.semibold))
            .foregroundStyle(color(for: segment.speaker))
        if let id = segment.speakerID, let speaker = speakers?.speaker(id), !meeting.isProcessing {
            Button { naming = segment.id } label: {
                HStack(spacing: 4) {
                    label
                    if speaker.name == nil, let suggestion = speaker.suggestion {
                        Text("\(suggestion)?").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Name this voice")
            .popover(isPresented: Binding(get: { naming == segment.id }, set: { if !$0 { naming = nil } })) {
                NameSpeakerView(meetingID: meeting.id, speaker: speaker, label: segment.speaker) { naming = nil }
            }
        } else {
            label
        }
    }

    private var rows: [Row] {
        let muted = meeting.mute.filter { ($0.end ?? meeting.duration) - $0.start >= 3 }
        var rows: [Row] = []
        var m = 0
        for segment in segments {
            while m < muted.count, muted[m].start <= segment.start {
                rows.append(.muted(muted[m]))
                m += 1
            }
            rows.append(.line(segment))
        }
        return rows
    }

    private func color(for speaker: String) -> Color {
        if speaker == "Me" { return .accentColor }
        let palette: [Color] = [.orange, .purple, .teal, .pink, .indigo, .brown, .mint, .cyan]
        let hash = speaker.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}
