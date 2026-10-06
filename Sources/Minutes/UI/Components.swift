import SwiftUI

/// A small horizontal level meter.
struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(level > 0.85 ? Color.orange : Color.green)
                        .frame(width: max(2, geo.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.15), value: level)
                }
            }
            .frame(height: 5)
        }
    }
}

/// A coloured pill for meeting status.
struct StatusBadge: View {
    let meeting: Meeting

    var body: some View {
        switch meeting.status {
        case .recording:
            badge("Recording", .red)
        case .transcribing:
            badge("Transcribing \(meeting.progressText ?? "")", .blue)
        case .summarizing:
            badge("Writing notes", .blue)
        case .failed:
            badge("Needs attention", .orange)
        case .done:
            if meeting.failedTrackCount > 0 { badge("Partial", .orange) } else { EmptyView() }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// A row explaining a problem, with a button to fix it.
struct ProblemRow: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action, action: perform).controlSize(.small)
        }
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded()))
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    static func cost(_ usd: Double) -> String {
        usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
    }
}
