import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(nsImage: MenuBarIcon.image(state))
            .accessibilityLabel("Minutes")
    }

    private var state: MenuBarIcon.State {
        let session = model.session
        if session.isRecording { return model.mute.micExcluded ? .muted : .recording }
        if session.phase == .stopping || model.store.meetings.contains(where: \.isProcessing) { return .busy }
        if model.blockingProblem != nil { return .problem }
        return .idle
    }
}

enum MenuBarIcon {
    enum State { case idle, recording, muted, busy, problem }

    static func image(_ state: State) -> NSImage {
        let size = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        switch state {
        case .idle: return symbol("waveform", size)
        case .busy: return symbol("ellipsis.circle", size)
        case .problem: return symbol("exclamationmark.triangle", size)
        case .recording: return symbol("record.circle.fill", size.applying(.init(paletteColors: [.systemRed])), template: false)
        case .muted: return symbol("mic.slash.circle.fill", size.applying(.init(paletteColors: [.systemRed])), template: false)
        }
    }

    private static func symbol(_ name: String, _ config: NSImage.SymbolConfiguration, template: Bool = true) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Minutes")?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = template
        return image
    }
}
