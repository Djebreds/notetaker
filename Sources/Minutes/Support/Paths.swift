import Foundation

nonisolated enum Paths {
    static let bundleID = "com.refifauzan.minutes"

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minutes", isDirectory: true)
    }

    static var meetings: URL { appSupport.appendingPathComponent("meetings", isDirectory: true) }
    static var diagnostics: URL { appSupport.appendingPathComponent("diagnostics", isDirectory: true) }

    static var logs: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Minutes", isDirectory: true)
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
