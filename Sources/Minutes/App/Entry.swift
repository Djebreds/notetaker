import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--bench") {
            exit(runBlocking { await Bench.run(arguments) })
        }
        if arguments.contains("--speakers") {
            exit(runBlocking { await Bench.speakersTest(arguments) })
        }
        if arguments.contains("--bleed-test") {
            exit(Bench.bleedTest(arguments))
        }
        if arguments.contains("--notes-preview") {
            exit(runBlocking { await Bench.notesPreview(arguments) })
        }
        MinutesApp.main()
    }

    private static func runBlocking(_ operation: @escaping @Sendable () async -> Int32) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ResultBox()
        Task.detached {
            result.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return result.value
    }

    private final class ResultBox: @unchecked Sendable { var value: Int32 = 0 }
}

struct MinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(AppModel.shared)
        } label: {
            MenuBarLabel()
                .environment(AppModel.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.launch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let session = AppModel.shared.session
        guard session.isRecording else { return .terminateNow }
        // Close the recording properly; transcription resumes on next launch.
        Task { @MainActor in
            await session.stopAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
