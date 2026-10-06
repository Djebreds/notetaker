import Foundation

/// When the user's mic must be left out, in seconds from session start. Written by the mute monitor
/// (main thread), read by the recorder's encoder (background) — hence the lock.
nonisolated final class MuteTimeline: @unchecked Sendable {
    /// Typical delay between the user clicking mute/unmute and Minutes noticing.
    static let detectionLag = 0.6
    /// Extra margin before a mute so speech right after clicking mute never leaks.
    static let leadMargin = 0.2

    private let lock = NSLock()
    private var detected: [MuteInterval] = []
    private var manual: [MuteInterval] = []

    init(_ intervals: [MuteInterval] = []) {
        detected = intervals.filter { $0.source != .manual }
        manual = intervals.filter { $0.source == .manual }
    }

    func setDetected(muted: Bool, at time: Double, source: MuteSource) {
        lock.withLock { Self.toggle(&detected, on: muted, at: time, source: source) }
    }

    func setManual(_ on: Bool, at time: Double) {
        lock.withLock { Self.toggle(&manual, on: on, at: time, source: .manual) }
    }

    func closeAll(at time: Double) {
        lock.withLock {
            Self.toggle(&detected, on: false, at: time, source: .app)
            Self.toggle(&manual, on: false, at: time, source: .manual)
        }
    }

    var intervals: [MuteInterval] {
        lock.withLock { (detected + manual).sorted { $0.start < $1.start } }
    }

    /// Ranges to silence within [from, to]. Detected intervals are shifted earlier by the detection lag
    /// (and start a little earlier still); manual ones are exact.
    func mask(from: Double, to: Double) -> [ClosedRange<Double>] {
        let (detected, manual) = lock.withLock { (self.detected, self.manual) }
        var ranges: [ClosedRange<Double>] = []
        for i in detected {
            let lo = i.start - Self.detectionLag - Self.leadMargin
            let hi = (i.end ?? .infinity) - Self.detectionLag
            if hi > lo { ranges.append(lo...hi) }
        }
        for i in manual { ranges.append(i.start...(i.end ?? .infinity)) }
        let clipped = ranges.compactMap { r -> ClosedRange<Double>? in
            let lo = max(r.lowerBound, from), hi = min(r.upperBound, to)
            return hi > lo ? lo...hi : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for r in clipped {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    private static func toggle(_ list: inout [MuteInterval], on: Bool, at time: Double, source: MuteSource) {
        let open = list.last.map { $0.end == nil } ?? false
        if on, !open {
            list.append(MuteInterval(start: time, end: nil, source: source))
        } else if !on, open {
            list[list.count - 1].end = max(time, list[list.count - 1].start)
        }
    }
}
