import Foundation
import os

/// Logs to the unified log and to ~/Library/Logs/Minutes/minutes.log (rotated at 5 MB).
nonisolated enum Log {
    private static let logger = Logger(subsystem: "com.refifauzan.minutes", category: "app")
    private static let file = LogFile()

    static func info(_ message: String, _ category: String = "app") {
        logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        file.write("INFO", category, message)
    }

    static func warn(_ message: String, _ category: String = "app") {
        logger.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        file.write("WARN", category, message)
    }

    static func error(_ message: String, _ category: String = "app") {
        logger.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        file.write("ERROR", category, message)
    }

    static func debug(_ message: String, _ category: String = "app") {
        logger.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
    }
}

private nonisolated final class LogFile: @unchecked Sendable {
    private let queue = DispatchQueue(label: "minutes.log")
    private var handle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func write(_ level: String, _ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level) [\(category)] \(message)\n"
        queue.async { [self] in
            guard let data = line.data(using: .utf8) else { return }
            if handle == nil { open() }
            handle?.write(data)
        }
    }

    private func open() {
        let dir = Paths.logs
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("minutes.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > 5_000_000 {
            let old = dir.appendingPathComponent("minutes.1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
}
