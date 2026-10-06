import AVFAudio
import CoreAudio
import Foundation

nonisolated struct AudioCaptureError: LocalizedError {
    let message: String
    init(_ step: String, _ status: OSStatus) { message = "\(step) failed (OSStatus \(status))" }
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Captures everything apps play (the "Others" side of a call) through a Core Audio process tap
/// (macOS 14.2+). The tap is global, excludes Minutes itself, and is unmuted so the user keeps
/// hearing the call. It is attached to a private, tap-only aggregate device whose IO block runs
/// on our own queue.
nonisolated final class SystemAudioTap: @unchecked Sendable {
    /// Called on the tap queue with the tapped audio and the host time of its first sample.
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, UInt64) -> Void

    private let queue = DispatchQueue(label: "minutes.systemtap", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    /// The private aggregate device the tap feeds (to watch for it dying).
    var aggregateDevice: AudioObjectID { aggregateID }
    private var procID: AudioDeviceIOProcID?

    private(set) var sampleRate: Double = 0
    var isRunning: Bool { procID != nil }

    /// Not thread-safe: call start/stop from one control queue.
    /// - Parameter excludedProcesses: HAL process objects whose audio must not be captured
    ///   (Minutes itself is always excluded).
    func start(excludedProcesses: [AudioObjectID], handler: @escaping BufferHandler) throws {
        stop()

        var excluded = excludedProcesses
        if let own = CA.processObject(for: getpid()), !excluded.contains(own) { excluded.append(own) }

        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Minutes system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw AudioCaptureError("Creating the system audio tap", status) }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = CA.address(kAudioTapPropertyFormat)
        status = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw AudioCaptureError("Reading the tap format", status)
        }
        sampleRate = tapFormat.sampleRate

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Minutes System Audio",
            kAudioAggregateDeviceUIDKey: "com.refifauzan.minutes.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ] as [String: Any],
            ],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            stop()
            throw AudioCaptureError("Creating the aggregate device", status)
        }
        aggregateID = device
        // A new aggregate device can take a moment to come alive; starting it earlier can leave it silent.
        for _ in 0..<20 {
            let alive: UInt32 = CA.read(device, kAudioDevicePropertyDeviceIsAlive, default: 0)
            if alive != 0 { break }
            usleep(100_000)
        }

        // The IO block captures its format and handler so it never reads state that stop() mutates.
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, inputData, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            let time = inputTime.pointee
            handler(buffer, time.mFlags.contains(.hostTimeValid) ? time.mHostTime : HostClock.now)
        }
        guard status == noErr, let proc else {
            stop()
            throw AudioCaptureError("Creating the tap IO proc", status)
        }
        procID = proc

        // Starting the device is what triggers the "System Audio Recording" permission prompt the
        // first time; if permission is denied it still succeeds but delivers silence.
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            stop()
            throw AudioCaptureError("Starting the system audio tap", status)
        }
        Log.info("System audio tap running at \(Int(tapFormat.sampleRate)) Hz, \(tapFormat.channelCount) ch, excluding \(excluded.count) process(es)", "audio")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}
