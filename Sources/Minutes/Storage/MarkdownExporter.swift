import Foundation

nonisolated enum MarkdownExporter {
    static func markdown(meeting: Meeting, notes: MeetingNotes?, transcript: [TranscriptSegment], includeTranscript: Bool,
                         hideFillers: Bool = false) -> String {
        let transcript = hideFillers ? transcript.filter { !TranscriptMerger.isFillerOnly($0.text) } : transcript
        var md: [String] = []
        md.append("# \(notes?.title ?? meeting.title)")
        md.append("")

        let start = meeting.startedAt.formatted(date: .complete, time: .shortened)
        let end = meeting.endedAt.map { $0.formatted(date: .omitted, time: .shortened) }
        let minutes = Int((meeting.duration / 60).rounded())
        var meta = ["**Date:** \(start)" + (end.map { "–\($0)" } ?? "") + " (\(minutes) min)"]
        if let app = meeting.appName { meta.append("**App:** \(app)") }
        if let participants = notes?.participants, !participants.isEmpty {
            meta.append("**Participants:** \(participants.joined(separator: ", "))")
        }
        md.append(meta.joined(separator: "  \n"))

        if let notes {
            section(&md, "Summary", body: notes.summary)
            list(&md, "Key points", notes.keyPoints)
            list(&md, "Decisions", notes.decisions)
            if !notes.actionItems.isEmpty {
                md.append("")
                md.append("## Action items")
                md.append("")
                for item in notes.actionItems {
                    var line = "- [ ] "
                    if let owner = item.owner { line += "**\(owner):** " }
                    line += item.task
                    if let due = item.due { line += " _(due \(due))_" }
                    md.append(line)
                }
            }
            list(&md, "Open questions", notes.openQuestions)
            if let discussion = notes.discussion, !discussion.isEmpty {
                md.append("")
                md.append("## Discussion")
                for topic in discussion {
                    md.append("")
                    md.append("### \(topic.topic)")
                    md.append("")
                    md.append(contentsOf: topic.points.map { "- \($0)" })
                }
            }
        } else {
            section(&md, "Notes", body: "_Notes have not been generated for this meeting._")
        }

        if includeTranscript, !transcript.isEmpty {
            md.append("")
            md.append("---")
            md.append("")
            md.append("## Transcript")
            md.append("")
            let muted = meeting.mute.filter { ($0.end ?? meeting.duration) - $0.start >= 3 }
            var mutedIndex = 0
            for segment in transcript {
                while mutedIndex < muted.count, muted[mutedIndex].start <= segment.start {
                    let m = muted[mutedIndex]
                    md.append("_— you were muted \(Timecode.format(m.start))–\(Timecode.format(m.end ?? meeting.duration)) —_")
                    md.append("")
                    mutedIndex += 1
                }
                md.append("**[\(Timecode.format(segment.start))] \(segment.speaker):** \(segment.text)")
                md.append("")
            }
        }
        return md.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// "2026-10-06 Sprint planning.md", safe for the file system.
    static func fileName(meeting: Meeting, title: String) -> String {
        let day = meeting.startedAt.formatted(.iso8601.year().month().day())
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return "\(day) \(safe.prefix(80)).md"
    }

    private static func section(_ md: inout [String], _ title: String, body: String) {
        guard !body.isEmpty else { return }
        md.append("")
        md.append("## \(title)")
        md.append("")
        md.append(body)
    }

    private static func list(_ md: inout [String], _ title: String, _ items: [String]) {
        guard !items.isEmpty else { return }
        md.append("")
        md.append("## \(title)")
        md.append("")
        md.append(contentsOf: items.map { "- \($0)" })
    }
}
