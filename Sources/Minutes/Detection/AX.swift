import AppKit
import ApplicationServices

/// Accessibility helpers. Use only from one background queue; AX calls block while the target app is busy,
/// so every application element gets a short messaging timeout.
nonisolated enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func application(_ pid: pid_t, timeout: Float = 0.4) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func number(_ element: AXUIElement, _ attribute: String) -> Int? {
        (value(element, attribute) as? NSNumber)?.intValue
    }

    static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] {
        (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func url(_ element: AXUIElement) -> String? {
        guard let raw = value(element, kAXURLAttribute) else { return nil }
        if let url = raw as? URL { return url.absoluteString }
        return raw as? String
    }

    /// Description, title and help joined, lowercased and whitespace-normalised.
    static func label(_ element: AXUIElement) -> String {
        let parts = [string(element, kAXDescriptionAttribute), string(element, kAXTitleAttribute),
                     string(element, kAXHelpAttribute)].compactMap { $0 }.filter { !$0.isEmpty }
        return normalize(parts.first ?? "")
    }

    static func allLabels(_ element: AXUIElement) -> [String] {
        [string(element, kAXDescriptionAttribute), string(element, kAXTitleAttribute), string(element, kAXHelpAttribute)]
            .compactMap { $0 }.filter { !$0.isEmpty }.map(normalize)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    @discardableResult
    static func setFlag(_ element: AXUIElement, _ attribute: String, _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!) == .success
    }

    /// Breadth-first search, bounded by node count and depth.
    static func first(in roots: [AXUIElement], maxNodes: Int = 4_000, maxDepth: Int = 40,
                      where match: (AXUIElement, String) -> Bool) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = roots.map { ($0, 0) }
        var head = 0
        var visited = 0
        while head < queue.count, visited < maxNodes {
            let (element, depth) = queue[head]
            head += 1
            visited += 1
            let role = AX.role(element) ?? ""
            if match(element, role) { return element }
            if depth < maxDepth {
                for child in children(element) { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }

    /// Web areas (rendered pages) inside the given windows, without descending into them.
    static func webAreas(in windows: [AXUIElement], maxNodes: Int = 2_500) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = windows.map { ($0, 0) }
        var head = 0
        while head < queue.count, head < maxNodes {
            let (element, depth) = queue[head]
            head += 1
            if role(element) == "AXWebArea" {
                found.append(element)
                continue
            }
            if depth < 30 { for child in children(element) { queue.append((child, depth + 1)) } }
        }
        return found
    }

    static func menuBarItems(_ app: AXUIElement) -> [AXUIElement] {
        guard let bar = value(app, kAXMenuBarAttribute) else { return [] }
        return children(bar as! AXUIElement)
    }

    /// The items of a menu-bar menu (titles exactly as shown), without opening it.
    static func menuItems(_ app: AXUIElement, menu title: String?) -> [AXUIElement] {
        var items: [AXUIElement] = []
        for barItem in menuBarItems(app) {
            if let title, string(barItem, kAXTitleAttribute) != title { continue }
            for menu in children(barItem) { items.append(contentsOf: children(menu)) }
        }
        return items
    }

    /// Text dump of an element tree for diagnosing rules.
    static func dump(_ root: AXUIElement, maxNodes: Int = 6_000) -> String {
        var lines: [String] = []
        var count = 0
        func visit(_ element: AXUIElement, _ depth: Int) {
            guard count < maxNodes, depth < 60 else { return }
            count += 1
            var parts = [role(element) ?? "?"]
            if let sub = string(element, kAXSubroleAttribute) { parts.append("[\(sub)]") }
            for (key, attr) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("help", kAXHelpAttribute)] {
                if let s = string(element, attr), !s.isEmpty { parts.append("\(key)=\"\(s.prefix(120))\"") }
            }
            if let v = value(element, kAXValueAttribute) {
                let text = "\(v)".replacingOccurrences(of: "\n", with: " ")
                if !text.isEmpty { parts.append("value=\"\(text.prefix(80))\"") }
            }
            if let u = url(element) { parts.append("url=\(u.prefix(120))") }
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
            for child in children(element) { visit(child, depth + 1) }
        }
        visit(root, 0)
        if count >= maxNodes { lines.append("… truncated at \(maxNodes) elements") }
        return lines.joined(separator: "\n")
    }
}
