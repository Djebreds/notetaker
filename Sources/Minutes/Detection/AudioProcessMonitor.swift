import AppKit
import CoreAudio
import Foundation

/// An app (helper processes already mapped to their owner) doing audio I/O.
nonisolated struct AudioApp: Sendable, Hashable {
    let bundleID: String
    let name: String
    let pid: pid_t
}

nonisolated struct AudioActivity: Sendable, Equatable {
    /// Apps capturing a microphone right now (excluding Minutes, Siri and dictation).
    var micUsers: [AudioApp] = []
    /// Apps playing audio right now.
    var outputApps: [AudioApp] = []

    func isUsingMic(bundleIDs: [String]) -> Bool { micUsers.contains { bundleIDs.contains($0.bundleID) } }
}

/// Watches Core Audio's per-process objects (macOS 14+, no permission needed) to see which apps hold
/// the microphone. Listeners give quick updates; a 2 s poll backs them up because the per-process
/// IsRunningInput listener does not fire on macOS 27.
nonisolated final class AudioProcessMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "minutes.processmonitor")
    private var timer: DispatchSourceTimer?
    private var listListener: CAListener?
    private var processListeners: [AudioObjectID: [CAListener]] = [:]
    private var refreshScheduled = false
    private var appCache: [pid_t: AudioApp] = [:]
    private var onChange: (@Sendable (AudioActivity) -> Void)?
    private let snapshotLock = NSLock()
    private var latest = AudioActivity()

    var current: AudioActivity { snapshotLock.withLock { latest } }

    func start(onChange: @escaping @Sendable (AudioActivity) -> Void) {
        queue.async { [self] in
            self.onChange = onChange
            listListener = CAListener(CA.system, kAudioHardwarePropertyProcessObjectList, queue: queue) { [weak self] in
                self?.scheduleRefresh()
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2)
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            listListener = nil
            processListeners.removeAll()
            onChange = nil
        }
    }

    /// Re-reads immediately (e.g. right after a state change elsewhere).
    func refreshNow() { queue.async { [weak self] in self?.refresh() } }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        let own = getpid()
        let objects = CA.processObjects
        var mic: [AudioApp] = []
        var output: [AudioApp] = []
        var livePIDs = Set<pid_t>()

        for object in objects {
            let pid: pid_t = CA.read(object, kAudioProcessPropertyPID, default: -1)
            guard pid > 0, pid != own else { continue }
            livePIDs.insert(pid)
            let processBundle = CA.readString(object, kAudioProcessPropertyBundleID) ?? ""
            if AppCatalog.ignoredProcesses.contains(processBundle) { continue }
            let input: UInt32 = CA.read(object, kAudioProcessPropertyIsRunningInput, default: 0)
            let playing: UInt32 = CA.read(object, kAudioProcessPropertyIsRunningOutput, default: 0)
            guard input != 0 || playing != 0 else { continue }
            let app = resolve(pid: pid, processBundle: processBundle)
            if AppCatalog.ignoredProcesses.contains(app.bundleID) { continue }
            if input != 0 {
                // Siri's CoreSpeech reports input with no device; real captures list their input device.
                let devices = CA.readArray(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput, of: AudioObjectID.self)
                if !devices.isEmpty, !mic.contains(app) { mic.append(app) }
            }
            if playing != 0, !output.contains(app) { output.append(app) }
        }

        appCache = appCache.filter { livePIDs.contains($0.key) }
        updateProcessListeners(objects)

        let activity = AudioActivity(micUsers: mic, outputApps: output)
        let changed = snapshotLock.withLock { () -> Bool in
            defer { latest = activity }
            return latest != activity
        }
        if changed { onChange?(activity) }
    }

    /// Maps a (helper) process to the app responsible for it.
    private func resolve(pid: pid_t, processBundle: String) -> AudioApp {
        if let cached = appCache[pid] { return cached }
        let owner = ProcessInfoLookup.responsiblePID(for: pid)
        let app: AudioApp
        if let running = NSRunningApplication(processIdentifier: owner), let bundle = running.bundleIdentifier {
            app = AudioApp(bundleID: bundle, name: running.localizedName ?? bundle, pid: owner)
        } else {
            let name = ProcessInfoLookup.executablePath(pid).map { URL(fileURLWithPath: $0).lastPathComponent } ?? processBundle
            app = AudioApp(bundleID: processBundle.isEmpty ? name : processBundle, name: name, pid: pid)
        }
        appCache[pid] = app
        return app
    }

    /// Per-process listeners for quick reaction: IsRunning (global) and Devices (input scope) fire when
    /// an app starts or stops audio, or opens the mic while already playing.
    private func updateProcessListeners(_ objects: [AudioObjectID]) {
        let live = Set(objects)
        processListeners = processListeners.filter { live.contains($0.key) }
        for object in objects where processListeners[object] == nil {
            processListeners[object] = [
                CAListener(object, kAudioProcessPropertyIsRunning, queue: queue) { [weak self] in self?.scheduleRefresh() },
                CAListener(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput, queue: queue) { [weak self] in
                    self?.scheduleRefresh()
                },
            ].compactMap { $0 }
        }
    }
}
