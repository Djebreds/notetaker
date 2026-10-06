import AppKit
import AVFAudio
import CoreAudio
import Foundation

nonisolated struct RecorderHealth: Sendable, Equatable {
    enum State: String, Sendable {
        case starting, ok, restarting, silent, failed
    }
    var systemAudio: State = .starting
    var microphone: State = .starting
    var micDevice: String?
    var outputDevice: String?
    var problem: String?

    var isHealthy: Bool { systemAudio == .ok && microphone == .ok }
}

/// Records the two sides of a call into aligned ~5-minute chunks.
///
/// - "others": a global Core Audio process tap (everything apps play, minus Minutes and excluded apps)
/// - "me": the default microphone
///
/// A watchdog rebuilds a capture that stops delivering audio, goes silent while apps are playing,
/// or loses its device (e.g. AirPods switching to call mode). Each closed chunk is masked (mute
/// timeline), encoded to FLAC and reported once both tracks of that chunk are ready.
nonisolated final class Recorder: @unchecked Sendable {
    static let minChunkSeconds = 270.0
    static let maxChunkSeconds = 330.0
    static let quietLevel: Float = -45

    let meetingFolder: URL
    let sessionStartHost: UInt64
    /// Seconds between the meeting's start and this recording's start (non-zero when resuming).
    let timeOffset: Double

    private let audioFolder: URL
    private let control = DispatchQueue(label: "minutes.recorder")
    private let encoder = DispatchQueue(label: "minutes.encoder", qos: .utility)
    private let encodeGroup = DispatchGroup()
    private var tap = SystemAudioTap()
    private let mic = MicCapture()
    private let tapResampler = Resampler()
    private let micResampler = Resampler()
    private let me: TrackWriter
    private let others: TrackWriter
    private let stamps = CallbackStamps()

    private let excludedBundleIDs: Set<String>
    private let mask: @Sendable (Double, Double) -> [ClosedRange<Double>]
    private let onChunk: @Sendable (ChunkRecord) -> Void
    private let onHealth: @Sendable (RecorderHealth) -> Void

    // Control-queue state
    private var health = RecorderHealth()
    private var timer: DispatchSourceTimer?
    private var listeners: [CAListener] = []
    private var outputRateListener: CAListener?
    private var aggregateListener: CAListener?
    private var tapGeneration = 0
    private var pendingTapRestart: DispatchWorkItem?
    private var requestedCut: Int64?
    private var lastTapStart: UInt64 = 0
    private var lastQuietWarning: UInt64 = 0
    private var silentStrikes = 0
    private var pending: [Int: [Track: ChunkEncoder.Output]] = [:]
    private var closedPairs: [Int: [Track: ClosedChunk]] = [:]
    private var bleedByChunk: [Int: Double] = [:]
    private var emitted = 0
    private var stopped = false

    /// - Parameters:
    ///   - mask: muted ranges (seconds from session start) overlapping the given window; applied to "me".
    ///   - onChunk: a chunk with both tracks encoded (called on a background queue).
    init(meetingFolder: URL,
         sessionStartHost: UInt64,
         firstChunkIndex: Int = 1,
         timeOffset: Double = 0,
         excludedBundleIDs: Set<String>,
         mask: @escaping @Sendable (Double, Double) -> [ClosedRange<Double>],
         onChunk: @escaping @Sendable (ChunkRecord) -> Void,
         onHealth: @escaping @Sendable (RecorderHealth) -> Void) {
        self.meetingFolder = meetingFolder
        self.sessionStartHost = sessionStartHost
        self.timeOffset = timeOffset
        self.audioFolder = Paths.ensure(meetingFolder.appendingPathComponent("audio", isDirectory: true))
        self.excludedBundleIDs = excludedBundleIDs
        self.mask = mask
        self.onChunk = onChunk
        self.onHealth = onHealth
        let relay = ClosedChunkRelay()
        self.me = TrackWriter(track: .me, folder: audioFolder, sessionStartHost: sessionStartHost,
                              firstIndex: firstChunkIndex) { relay.forward($0) }
        self.others = TrackWriter(track: .others, folder: audioFolder, sessionStartHost: sessionStartHost,
                                  firstIndex: firstChunkIndex) { relay.forward($0) }
        relay.target = self
    }

    // MARK: - Lifecycle

    /// Starts both captures. Throws only if neither side could be captured.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async {
                do {
                    try self.startOnControlQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops capturing, closes the final chunk and waits until every chunk has been encoded.
    /// Returns how many chunks were reported through `onChunk` in total.
    @discardableResult
    func stop() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            control.async {
                self.stopped = true
                self.stamps.stopping = true
                self.timer?.cancel()
                self.timer = nil
                self.listeners.removeAll()
                self.outputRateListener = nil
                self.aggregateListener = nil
                self.pendingTapRestart?.cancel()
                self.mic.stop()
                self.tap.stop()
                let end = max(self.me.currentPosition, self.others.currentPosition)
                self.me.finish(padTo: end)
                self.others.finish(padTo: end)
                self.encodeGroup.notify(queue: self.control) { continuation.resume(returning: self.emitted) }
            }
        }
    }

    /// Seconds since the other participants were last audible on the system-audio track.
    func secondsSinceOthersAudible() -> Double {
        HostClock.seconds(from: others.lastAudibleHost, to: HostClock.now)
    }

    /// Peak levels since the last call (0…1), for meters.
    func takeLevels() -> (me: Float, others: Float) {
        (me.takePeak(), others.takePeak())
    }

    private func startOnControlQueue() throws {
        var errors: [String] = []
        // Mic first: it gives Minutes a HAL process object, so the tap can exclude it.
        do { try startMic() } catch {
            health.microphone = .failed
            errors.append(error.localizedDescription)
        }
        do { try startTap() } catch {
            health.systemAudio = .failed
            errors.append(error.localizedDescription)
        }
        if health.microphone == .failed && health.systemAudio == .failed {
            throw AudioCaptureError(errors.joined(separator: "; "))
        }
        health.problem = errors.isEmpty ? nil : errors.joined(separator: "; ")
        installListeners()
        startTimer()
        report()
    }

    // MARK: - Captures

    private func startMic() throws {
        try mic.start(handler: { [weak self] buffer, host in
            guard let self, let converted = self.micResampler.convert(buffer) else { return }
            self.me.append(converted, hostTime: host)
            self.stamps.mic = HostClock.now
        }, onConfigurationChange: { [weak self] in
            guard let self else { return }
            self.control.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.restartMic("input device changed") }
        })
        stamps.mic = HostClock.now
        health.microphone = .ok
        health.micDevice = mic.deviceName
    }

    /// Builds and starts a tap whose audio only reaches the writer while it is the active one, so a
    /// replacement can start before the old tap stops without doubling audio.
    private func makeTap() throws -> (SystemAudioTap, Int) {
        tapGeneration += 1
        let generation = tapGeneration
        let newTap = SystemAudioTap()
        try newTap.start(excludedProcesses: excludedProcessObjects()) { [weak self] buffer, host in
            guard let self, self.stamps.activeTap == generation,
                  let converted = self.tapResampler.convert(buffer) else { return }
            self.others.append(converted, hostTime: host)
            self.stamps.tap = HostClock.now
        }
        return (newTap, generation)
    }

    private func startTap() throws {
        let (newTap, generation) = try makeTap()
        stamps.activeTap = generation
        tap = newTap
        tapStarted()
    }

    private func tapStarted() {
        lastTapStart = HostClock.now
        stamps.tap = lastTapStart
        health.systemAudio = .ok
        health.outputDevice = CA.defaultOutputDevice.flatMap(CA.deviceName)
        if let output = CA.defaultOutputDevice {
            outputRateListener = CAListener(output, kAudioDevicePropertyNominalSampleRate, queue: control) { [weak self] in
                self?.scheduleTapRestart("output sample rate changed")
            }
        }
        aggregateListener = CAListener(tap.aggregateDevice, kAudioDevicePropertyDeviceIsAlive, queue: control) { [weak self] in
            self?.scheduleTapRestart("capture device stopped")
        }
    }

    private func restartMic(_ reason: String) {
        guard !stopped else { return }
        Log.info("Restarting microphone: \(reason)", "audio")
        health.microphone = .restarting
        report()
        mic.stop()
        do {
            try startMic()
            if health.systemAudio != .failed { health.problem = nil }
        } catch {
            health.microphone = .failed
            health.problem = error.localizedDescription
            Log.error("Microphone restart failed: \(error.localizedDescription)", "audio")
        }
        report()
    }

    private func restartTap(_ reason: String) {
        guard !stopped else { return }
        Log.info("Restarting system audio tap: \(reason)", "audio")
        do {
            // The old tap keeps capturing until the new one runs: no gap for a capture that still worked.
            let (newTap, generation) = try makeTap()
            stamps.activeTap = generation
            aggregateListener = nil
            tap.stop()
            tap = newTap
            tapStarted()
            if health.microphone != .failed { health.problem = nil }
        } catch {
            if !tap.isRunning {
                health.systemAudio = .failed
                health.problem = error.localizedDescription
            }
            Log.error("System audio restart failed: \(error.localizedDescription)", "audio")
        }
        report()
    }

    private func scheduleTapRestart(_ reason: String) {
        pendingTapRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartTap(reason) }
        pendingTapRestart = work
        control.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func installListeners() {
        listeners = [
            CAListener(CA.system, kAudioHardwarePropertyDefaultOutputDevice, queue: control) { [weak self] in
                self?.scheduleTapRestart("output device changed")
            },
            CAListener(CA.system, kAudioHardwarePropertyServiceRestarted, queue: control) { [weak self] in
                guard let self else { return }
                self.scheduleTapRestart("Core Audio restarted")
                self.control.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.restartMic("Core Audio restarted") }
            },
        ].compactMap { $0 }
    }

    /// Process objects of apps that should never be recorded (music players), plus Minutes.
    private func excludedProcessObjects() -> [AudioObjectID] {
        guard !excludedBundleIDs.isEmpty else { return [] }
        return CA.processObjects.filter { object in
            let pid: pid_t = CA.read(object, kAudioProcessPropertyPID, default: -1)
            guard pid > 0 else { return false }
            let owner = ProcessInfoLookup.responsiblePID(for: pid)
            let bundle = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier
                ?? CA.readString(object, kAudioProcessPropertyBundleID)
            return bundle.map(excludedBundleIDs.contains) ?? false
        }
    }

    // MARK: - Timer: chunking + watchdog

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard !stopped else { return }
        let now = HostClock.now

        // Keep both tracks moving on the timeline even if one capture stalls.
        let padTarget = now - HostClock.ticks(seconds: 1.2)
        me.padSilence(upTo: padTarget)
        others.padSilence(upTo: padTarget)

        maybeCutChunk()

        // Watchdog: no callbacks.
        if HostClock.seconds(from: stamps.tap, to: now) > 3, health.systemAudio != .restarting {
            if health.systemAudio != .failed || HostClock.seconds(from: lastTapStart, to: now) > 15 {
                restartTap("no audio callbacks for 3 s")
            }
        }
        if HostClock.seconds(from: stamps.mic, to: now) > 3, health.microphone != .restarting {
            restartMic("no audio callbacks for 3 s")
        }

        // Watchdog: silence while other apps are playing sound. A tap that has never produced sound
        // usually means the System Audio Recording permission is missing (it fails silently); a tap
        // that worked and then went quiet for a long time gets a quiet rebuild (quiet calls are normal).
        guard health.systemAudio != .failed, health.systemAudio != .restarting else { return }
        let sinceStart = HostClock.seconds(from: lastTapStart, to: now)
        if others.lastAudibleHost > lastTapStart {
            silentStrikes = 0
            if health.systemAudio == .silent {
                health.systemAudio = .ok
                health.problem = nil
                report()
            }
            // A capture that worked and went quiet is left alone (calls go quiet; a rebuild loses audio).
            let silentFor = HostClock.seconds(from: others.lastAudibleHost, to: now)
            if silentFor > 180, HostClock.seconds(from: lastQuietWarning, to: now) > 300, otherAppsArePlaying() {
                lastQuietWarning = now
                Log.warn("Meeting audio has been silent for \(Int(silentFor)) s while apps are playing", "audio")
            }
        } else if sinceStart > 15, otherAppsArePlaying() {
            silentStrikes += 1
            if silentStrikes <= 2 || health.systemAudio == .silent && sinceStart > 60 {
                let wasSilent = health.systemAudio == .silent
                restartTap("no sound captured while apps are playing")
                if wasSilent { health.systemAudio = .silent; report() }
            } else if health.systemAudio != .silent {
                health.systemAudio = .silent
                health.problem = "Meeting audio is silent although apps are playing sound. Check System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only."
                Log.warn("System audio tap is silent while apps play audio (permission?)", "audio")
                report()
            }
        }
    }

    private func maybeCutChunk() {
        let mePos = me.currentPosition, othersPos = others.currentPosition
        if let cut = requestedCut {
            // Wait until both tracks have actually started their next chunk.
            if me.currentChunkStart >= cut && others.currentChunkStart >= cut { requestedCut = nil }
            return
        }
        let elapsed = Double(min(mePos - me.currentChunkStart, othersPos - others.currentChunkStart)) / TrackWriter.sampleRate
        guard elapsed >= Self.minChunkSeconds else { return }
        let quiet = me.recentLevel(frames: 20) < Self.quietLevel && others.recentLevel(frames: 20) < Self.quietLevel
        guard quiet || elapsed >= Self.maxChunkSeconds else { return }
        let cut = max(mePos, othersPos) + 4_000
        requestedCut = cut
        me.requestCut(at: cut)
        others.requestCut(at: cut)
    }

    private func otherAppsArePlaying() -> Bool {
        let own = getpid()
        return CA.processObjects.contains { object in
            let pid: pid_t = CA.read(object, kAudioProcessPropertyPID, default: -1)
            guard pid > 0, pid != own else { return false }
            let output: UInt32 = CA.read(object, kAudioProcessPropertyIsRunningOutput, default: 0)
            guard output != 0 else { return false }
            let bundle = NSRunningApplication(processIdentifier: ProcessInfoLookup.responsiblePID(for: pid))?.bundleIdentifier
            return !(bundle.map(excludedBundleIDs.contains) ?? false)
        }
    }

    private func report() {
        let snapshot = health
        onHealth(snapshot)
    }

    // MARK: - Chunk pipeline

    fileprivate func chunkClosed(_ chunk: ClosedChunk) {
        encodeGroup.enter()
        control.async { [self] in
            closedPairs[chunk.index, default: [:]][chunk.track] = chunk
            guard let pair = closedPairs[chunk.index], let me = pair[.me], let others = pair[.others] else { return }
            closedPairs[chunk.index] = nil
            // Give the mute monitor a moment to register a mute that happened right at the chunk's end.
            let delay: Double = stamps.stopping ? 0 : 2
            encoder.asyncAfter(deadline: .now() + delay) { [self] in
                let outputs = encodePair(me: me, others: others)
                control.async { [self] in
                    outputs.forEach(collect)
                    encodeGroup.leave()
                    encodeGroup.leave()
                }
            }
        }
    }

    /// Both tracks of a chunk: silence muted stretches and speaker bleed on the mic, then encode both.
    private func encodePair(me: ClosedChunk, others: ClosedChunk) -> [ChunkEncoder.Output] {
        let start = Double(me.startSample) / TrackWriter.sampleRate
        let end = start + Double(me.sampleCount) / TrackWriter.sampleRate
        let muted = mask(start, end).map { ($0.lowerBound - start)...($0.upperBound - start) }
        let micSamples = try? ChunkEncoder.readPCM(me.pcmURL)
        let systemSamples = try? ChunkEncoder.readPCM(others.pcmURL)

        var bleed: [ClosedRange<Double>] = []
        if let micSamples, let systemSamples {
            let started = Date()
            let result = BleedDetector.detect(mic: micSamples, system: systemSamples, muted: muted)
            bleed = result.ranges
            bleedByChunk[me.index] = result.bleedSeconds
            Log.info(String(format: "Chunk %d bleed: %.1f s silenced (delay %@, windows bleed %d / double talk %d / local %d) in %.2f s",
                            me.index, result.bleedSeconds, result.delayMs.map { String(format: "%.0f ms", $0) } ?? "none",
                            result.bleedWindows, result.doubleTalkWindows, result.localWindows, Date().timeIntervalSince(started)), "audio")
        }
        return [(me, micSamples, muted + bleed), (others, systemSamples, [])].map { chunk, samples, ranges in
            do {
                return try ChunkEncoder.finalize(chunk, samples: samples, mask: ranges, meetingFolder: meetingFolder)
            } catch {
                Log.error("Encoding chunk \(chunk.index) (\(chunk.track.rawValue)) failed: \(error.localizedDescription)", "audio")
                let s = Double(chunk.startSample) / TrackWriter.sampleRate
                return ChunkEncoder.Output(track: chunk.track, index: chunk.index, start: s,
                                           duration: Double(chunk.sampleCount) / TrackWriter.sampleRate,
                                           file: "", speechSeconds: 0, islands: [])
            }
        }
    }

    private func collect(_ output: ChunkEncoder.Output) {
        pending[output.index, default: [:]][output.track] = output
        guard let pair = pending[output.index], let m = pair[.me], let o = pair[.others] else { return }
        pending[output.index] = nil
        let bleedSeconds = bleedByChunk.removeValue(forKey: output.index)
        func trackChunk(_ x: ChunkEncoder.Output) -> TrackChunk {
            TrackChunk(track: x.track, file: x.file.isEmpty ? nil : x.file, speechSeconds: x.speechSeconds,
                       islands: x.islands, state: x.file.isEmpty ? .failed : .pending,
                       error: x.file.isEmpty ? "Audio could not be encoded" : nil,
                       bleedSeconds: x.track == .me ? bleedSeconds : nil)
        }
        emitted += 1
        onChunk(ChunkRecord(index: output.index, start: timeOffset + min(m.start, o.start), duration: max(m.duration, o.duration),
                            me: trackChunk(m), others: trackChunk(o)))
    }
}

/// Last-callback host times, written from capture threads and read by the watchdog.
private nonisolated final class CallbackStamps: @unchecked Sendable {
    private let lock = NSLock()
    private var _tap: UInt64 = HostClock.now
    private var _mic: UInt64 = HostClock.now
    private var _stopping = false
    private var _activeTap = 0
    var tap: UInt64 {
        get { lock.withLock { _tap } }
        set { lock.withLock { _tap = newValue } }
    }
    var mic: UInt64 {
        get { lock.withLock { _mic } }
        set { lock.withLock { _mic = newValue } }
    }
    var stopping: Bool {
        get { lock.withLock { _stopping } }
        set { lock.withLock { _stopping = newValue } }
    }
    /// Which tap generation may write (the others are being replaced or stopped).
    var activeTap: Int {
        get { lock.withLock { _activeTap } }
        set { lock.withLock { _activeTap = newValue } }
    }
}

/// Lets the writers (created in the recorder's init) call back into the recorder.
private nonisolated final class ClosedChunkRelay: @unchecked Sendable {
    weak var target: Recorder?
    func forward(_ chunk: ClosedChunk) { target?.chunkClosed(chunk) }
}
