import SwiftUI

/// Past meetings: a searchable list grouped by day, with the selected meeting's notes and transcript.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(groups, id: \.day) { group in
                    Section(group.day) {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting).tag(meeting.id)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search meetings")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
            .overlay {
                if model.store.meetings.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                           description: Text("Notes appear here after your first call."))
                } else if groups.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } detail: {
            if let selection, model.store.meeting(selection) != nil {
                MeetingDetailView(meetingID: selection).id(selection)
            } else {
                ContentUnavailableView("Select a meeting", systemImage: "doc.text")
            }
        }
        .onAppear { applyPendingSelection() }
        .onChange(of: model.historySelection) { applyPendingSelection() }
    }

    private func applyPendingSelection() {
        if let pending = model.historySelection {
            selection = pending
            model.historySelection = nil
        } else if selection == nil {
            selection = model.store.meetings.first?.id
        }
    }

    private var groups: [(day: String, meetings: [Meeting])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = model.store.meetings.filter { meeting in
            guard !query.isEmpty else { return true }
            if meeting.title.lowercased().contains(query) || (meeting.appName ?? "").lowercased().contains(query) { return true }
            return model.store.notesText(meeting.id).lowercased().contains(query)
        }
        let calendar = Calendar.current
        var result: [(day: String, meetings: [Meeting])] = []
        for meeting in filtered {
            let day: String
            if calendar.isDateInToday(meeting.startedAt) {
                day = "Today"
            } else if calendar.isDateInYesterday(meeting.startedAt) {
                day = "Yesterday"
            } else {
                day = meeting.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            }
            if result.last?.day == day {
                result[result.count - 1].meetings.append(meeting)
            } else {
                result.append((day, [meeting]))
            }
        }
        return result
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).lineLimit(2)
            HStack(spacing: 6) {
                Text(meeting.startedAt.formatted(date: .omitted, time: .shortened))
                Text("·")
                Text(Format.minutes(meeting.duration))
                if let app = meeting.appName {
                    Text("·")
                    Text(app).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            StatusBadge(meeting: meeting)
        }
        .padding(.vertical, 2)
    }
}

extension MeetingStore {
    /// Notes text for searching (cached by file modification would be nicer; meetings are few).
    func notesText(_ id: UUID) -> String {
        guard let notes = notes(id) else { return "" }
        return ([notes.title, notes.summary] + notes.keyPoints + notes.decisions + notes.actionItems.map(\.task)
                + notes.openQuestions + notes.participants).joined(separator: " ")
    }
}
