import AVFAudio
import Foundation

/// Captures the system default input (the mic the meeting app uses) with a plain AVAudioEngine.
/// Voice processing is deliberately off: it ducks other apps' audio and disturbs process taps.
nonisolated final class MicCapture: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, UInt64) -> Void

    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    private(set) var deviceName: String?
    var isRunning: Bool { engine?.isRunning ?? false }

    /// Not thread-safe: call start/stop from one control queue.
    /// - Parameter onConfigurationChange: called when the input device or its format changes; the
    ///   engine has stopped itself by then and must be rebuilt with `start` again.
    func start(handler: @escaping BufferHandler, onConfigurationChange: @escaping @Sendable () -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError("No microphone is available")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            handler(buffer, when.isHostTimeValid ? when.hostTime : HostClock.now)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError("Starting the microphone: \(error.localizedDescription)")
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in onConfigurationChange() }
        self.engine = engine
        deviceName = CA.defaultInputDevice.flatMap(CA.deviceName)
        Log.info("Microphone running: \(deviceName ?? "unknown") at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch", "audio")
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    deinit { stop() }
}

/// Converts any PCM buffer to 16 kHz mono Float32, keeping converter state across buffers.
nonisolated final class Resampler {
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if inputFormat == nil || inputFormat! != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.outputFormat)
            converter?.downmix = true
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            inputFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
