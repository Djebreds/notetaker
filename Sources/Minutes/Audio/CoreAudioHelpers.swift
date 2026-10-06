import CoreAudio
import Foundation

/// Thin, typed wrappers over the Core Audio HAL property API.
nonisolated enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        default value: T) -> T {
        var addr = address(selector, scope: scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? result : value
    }

    static func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             of type: T.Type) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr else { return [] }
        let typed = pointer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static var defaultOutputDevice: AudioDeviceID? {
        let id: AudioDeviceID = read(system, kAudioHardwarePropertyDefaultOutputDevice, default: kAudioObjectUnknown)
        return id == kAudioObjectUnknown ? nil : id
    }

    static var defaultInputDevice: AudioDeviceID? {
        let id: AudioDeviceID = read(system, kAudioHardwarePropertyDefaultInputDevice, default: kAudioObjectUnknown)
        return id == kAudioObjectUnknown ? nil : id
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? { readString(device, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ device: AudioDeviceID) -> String? { readString(device, kAudioObjectPropertyName) }

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        read(device, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }

    /// The HAL process object for a PID, or nil if the process has not done any audio I/O yet.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var inPID = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &inPID, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static var processObjects: [AudioObjectID] {
        readArray(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    }
}

/// Keeps a Core Audio property listener alive; removes it on `cancel()` or deinit.
nonisolated final class CAListener: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var active = false

    init?(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        self.object = object
        self.address = CA.address(selector, scope: scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
        active = true
    }

    func cancel() {
        guard active else { return }
        active = false
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }

    deinit { cancel() }
}

/// Host-clock helpers (mach absolute time ⇄ seconds).
nonisolated enum HostClock {
    static var now: UInt64 { mach_absolute_time() }

    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        guard end > start else { return -Double(AudioConvertHostTimeToNanos(start - end)) / 1e9 }
        return Double(AudioConvertHostTimeToNanos(end - start)) / 1e9
    }

    static func ticks(seconds: Double) -> UInt64 {
        AudioConvertNanosToHostTime(UInt64(max(0, seconds) * 1e9))
    }
}

/// Maps helper processes (browser renderers, WebKit GPU, Electron helpers) to the app responsible for them.
nonisolated enum ProcessInfoLookup {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let fn = responsibleFn else { return pid }
        let r = fn(pid)
        return r > 0 ? r : pid
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
