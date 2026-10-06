import AppKit
import Foundation

/// Reads the open tabs of a running browser through AppleScript (Automation permission, asked once per
/// browser). Runs `osascript` as a child process so it never blocks the main thread.
nonisolated enum BrowserTabs {
    struct Tab: Sendable, Hashable {
        let url: String
        let title: String
    }

    enum Failure: Sendable, Equatable {
        case notRunning, notPermitted, failed(String)
    }

    static func tabs(of bundleID: String) -> Result<[Tab], FailureBox> {
        // `tell application id …` would launch a browser that is not running.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            return .failure(FailureBox(.notRunning))
        }
        let titleProperty = bundleID == "com.apple.Safari" ? "name" : "title"
        let script = """
        tell application id "\(bundleID)"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set output to output & (URL of t) & tab & (\(titleProperty) of t) & linefeed
                end repeat
            end repeat
            return output
        end tell
        """
        let result = run(script)
        guard result.status == 0 else {
            if result.error.contains("-1743") || result.error.localizedCaseInsensitiveContains("not allowed") {
                return .failure(FailureBox(.notPermitted))
            }
            return .failure(FailureBox(.failed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))))
        }
        let tabs = result.output.split(separator: "\n").compactMap { line -> Tab? in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let url = parts.first, !url.isEmpty, url != "missing value" else { return nil }
            return Tab(url: String(url), title: parts.count > 1 ? String(parts[1]) : "")
        }
        return .success(tabs)
    }

    /// The first tab matching a web meeting app, with the regex's first capture group (e.g. the Meet code).
    static func meetingTab(in tabs: [Tab], for app: CallApp) -> (tab: Tab, code: String?)? {
        guard let pattern = app.urlPattern, let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for tab in tabs {
            let range = NSRange(tab.url.startIndex..., in: tab.url)
            guard let match = regex.firstMatch(in: tab.url, range: range) else { continue }
            var code: String?
            if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: tab.url) { code = String(tab.url[r]) }
            return (tab, code)
        }
        return nil
    }

    /// Automation permission state for a browser without prompting (true = allowed).
    static func automationAllowed(_ bundleID: String, ask: Bool) -> Bool? {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return nil }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return true
        case OSStatus(errAEEventNotPermitted): return false
        default: return nil   // not determined yet, or the browser is not running
        }
    }

    private static func run(_ script: String) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        // Drain both pipes while the script runs; a long tab list would otherwise fill the pipe buffer.
        let output = PipeReader(out), errors = PipeReader(err)
        let group = DispatchGroup()
        output.start(group)
        errors.start(group)
        if group.wait(timeout: .now() + 4) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 1)
            return (-1, "", "timed out")
        }
        process.waitUntilExit()
        return (process.terminationStatus, output.text, errors.text)
    }
}

private nonisolated final class PipeReader: @unchecked Sendable {
    private let pipe: Pipe
    private var data = Data()
    init(_ pipe: Pipe) { self.pipe = pipe }
    func start(_ group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
    }
    var text: String { String(data: data, encoding: .utf8) ?? "" }
}

/// `Result` needs an Error; this wraps the failure reason.
nonisolated struct FailureBox: Error, Sendable, Equatable {
    let reason: BrowserTabs.Failure
    init(_ reason: BrowserTabs.Failure) { self.reason = reason }
}
