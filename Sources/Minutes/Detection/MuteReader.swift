import ApplicationServices
import Foundation

nonisolated enum MuteReading: Sendable, Equatable {
    case muted, unmuted, unknown
}

/// Reads one meeting app's mute control through Accessibility, following the app's `MuteRule`s.
/// The matching element is cached and re-read cheaply; a full (bounded) scan only happens when it is
/// lost, with backoff. Use from a single background queue.
nonisolated final class MuteReader: @unchecked Sendable {
    let app: CallApp
    let pid: pid_t
    private let axApp: AXUIElement
    private var cached: (element: AXUIElement, rule: MuteRule)?
    private var nextScan = Date.distantPast
    private var failedScans = 0
    private var electronEnabled = false

    init(app: CallApp, pid: pid_t) {
        self.app = app
        self.pid = pid
        self.axApp = AX.application(pid, timeout: 0.25)
    }

    /// The control's current meaning, or `.unknown` when it cannot be found (e.g. a hidden browser tab).
    func read() -> MuteReading {
        guard !app.muteRules.isEmpty, AX.isTrusted else { return .unknown }
        if let cached, let reading = Self.evaluate(cached.element, cached.rule) {
            return reading
        }
        cached = nil
        guard Date() >= nextScan else { return .unknown }
        if app.needsElectronAccessibility, !electronEnabled {
            // Electron only builds its accessibility tree when asked to; no visible side effects.
            electronEnabled = AX.setFlag(axApp, "AXManualAccessibility", true)
        }
        for rule in app.muteRules {
            if let element = scan(rule), let reading = Self.evaluate(element, rule) {
                cached = (element, rule)
                failedScans = 0
                return reading
            }
        }
        failedScans += 1
        nextScan = Date().addingTimeInterval(min(10, 1.5 * Double(failedScans)))
        return .unknown
    }

    /// A short description of where the reading came from, for the UI.
    var sourceDescription: String {
        guard let cached else { return app.name }
        if case .menu = cached.rule.scope { return "\(app.name) menu" }
        return "\(app.name) button"
    }

    private func scan(_ rule: MuteRule) -> AXUIElement? {
        switch rule.scope {
        case .menu(let title):
            return AX.menuItems(axApp, menu: title).first { Self.evaluate($0, rule) != nil }
        case .windows:
            return AX.first(in: AX.windows(axApp), maxNodes: 4_000) { element, role in
                rule.roles.contains(role) && Self.evaluate(element, rule) != nil
            }
        case .webArea(let hints):
            let areas = AX.webAreas(in: AX.windows(axApp)).filter { area in
                let haystack = ([AX.url(area)] + AX.allLabels(area).map { Optional($0) })
                    .compactMap { $0?.lowercased() }.joined(separator: " ")
                return hints.contains { haystack.contains($0) }
            }
            return AX.first(in: areas, maxNodes: 5_000) { element, role in
                rule.roles.contains(role) && Self.evaluate(element, rule) != nil
            }
        }
    }

    /// What a control says about the mute state, or nil if it is not (or no longer) a mute control.
    static func evaluate(_ element: AXUIElement, _ rule: MuteRule) -> MuteReading? {
        let labels = AX.allLabels(element)
        guard !labels.isEmpty else { return nil }
        for label in labels {
            if rule.mutedWhenChecked.contains(label) {
                guard let value = AX.number(element, kAXValueAttribute) else { continue }
                return value != 0 ? .muted : .unmuted
            }
            if rule.mutedWhenMarked.contains(label) {
                let mark = AX.string(element, kAXMenuItemMarkCharAttribute) ?? ""
                return mark.isEmpty ? .unmuted : .muted
            }
        }
        for label in labels {
            if rule.mutedPrefixes.contains(where: { label.hasPrefix($0) }) { return .muted }
            if rule.unmutedPrefixes.contains(where: { label.hasPrefix($0) }) { return .unmuted }
        }
        return nil
    }
}
