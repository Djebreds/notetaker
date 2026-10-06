import Foundation

/// Builds the meeting transcript from per-chunk, per-track results.
nonisolated enum TranscriptMerger {
    /// - Parameter mute: the meeting's mute intervals; text on the user's track while muted can't be real.
    static func merge(chunks: [ChunkRecord], raw: [Int: [Track: [RawSegment]]], mute: [MuteInterval] = [],
                      speakers: SpeakerAnalysis? = nil) -> [TranscriptSegment] {
        let muteTimeline = MuteTimeline(mute)
        var all: [TranscriptSegment] = []
        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            let muted = muteTimeline.mask(from: chunk.start, to: chunk.start + chunk.duration)
            for track in Track.allCases {
                guard let segments = raw[chunk.index]?[track], !segments.isEmpty else { continue }
                all += place(segments, chunk: chunk, track: track, muted: track == .me ? muted : [])
            }
        }
        let others = all.filter { $0.track == .others }
        all.removeAll { $0.track == .me && isEcho($0, among: others) }
        all.sort { $0.start != $1.start ? $0.start < $1.start : $0.track == .others }
        if let speakers { all = SpeakerAssigner.assign(all, analysis: speakers) }
        return joinFragments(all)
    }

    /// Converts chunk-relative times to meeting times, snapping each start to the nearest burst of
    /// speech we detected locally (model timestamps can drift), keeping order within the track.
    ///
    /// Lines with no detected sound around them are dropped when they are short (models invent
    /// "Thank you." and "Okay." in silence) or fall where the user's mic was muted (silenced audio).
    /// Any line is dropped when the sound within 4 s of it (the drift snapping allows) covers less than
    /// about a quarter of the time its words take to say: models also invent whole sentences around a
    /// cough or a join chime.
    private static func place(_ segments: [RawSegment], chunk: ChunkRecord, track: Track,
                              muted: [ClosedRange<Double>]) -> [TranscriptSegment] {
        let islands = chunk[track].islands
        var placed: [TranscriptSegment] = []
        var lastStart = 0.0
        for segment in segments {
            var t = min(max(0, segment.start), chunk.duration)
            if let mute = muted.first(where: { $0.contains(chunk.start + t) }) {
                // Placed inside a muted stretch, where the audio is silence: the words came right after it
                // (model timestamps are only to the second).
                let resumed = mute.upperBound - chunk.start
                t = islands.first { $0.start >= resumed - 0.5 && $0.start <= resumed + 6 }?.start ?? resumed
            } else {
                let nearby = islands.filter { $0.start >= t - 4 && $0.start <= t + 2 && $0.start >= lastStart }
                if let island = nearby.min(by: { abs($0.start - t) < abs($1.start - t) }) { t = island.start }
            }
            let wordCount = words(segment.text).count
            let spokenEnd = t + Double(wordCount) / 2.5 + 1
            let heard = islands.contains { $0.end >= t - 1.5 && $0.start <= spokenEnd + 1.5 }
            if !heard {
                let inMute = muted.contains { $0.contains(chunk.start + t) }
                if inMute || wordCount <= 8 { continue }
            }
            let sound = islands.reduce(0.0) { $0 + max(0, min(spokenEnd + 4, $1.end) - max(t - 4, $1.start)) }
            if sound < Double(wordCount) / 10 - 0.5 { continue }
            t = max(t, lastStart)
            lastStart = t
            placed.append(TranscriptSegment(start: chunk.start + t, end: 0, speaker: segment.speaker,
                                            text: segment.text, track: track))
        }
        let chunkEnd = chunk.start + chunk.duration
        for i in placed.indices {
            let next = i + 1 < placed.count ? placed[i + 1].start : chunkEnd
            let spoken = placed[i].start + Double(words(placed[i].text).count) / 2.5 + 1
            placed[i].end = max(placed[i].start, min(next, spoken, chunkEnd))
        }
        return placed
    }

    /// A "Me" line that repeats what another participant said at the same moment is the mic hearing the
    /// laptop speakers, not the user.
    private static func isEcho(_ me: TranscriptSegment, among others: [TranscriptSegment]) -> Bool {
        let mine = words(me.text)
        guard !mine.isEmpty else { return false }
        let mineSet = Set(mine)
        // Short lines ("Okay.", "Mm.", "Yeah, yeah.") are echoes when someone else said those words at that moment.
        if mine.count <= 3 {
            return others.contains { other in
                abs(other.start - me.start) <= 2 && mineSet.isSubset(of: Set(words(other.text)).union(fillerWords))
            }
        }
        for other in others where abs(other.start - me.start) <= 4 || (other.start <= me.end && me.start <= other.end) {
            let theirs = Set(words(other.text))
            guard !theirs.isEmpty else { continue }
            let shared = Double(mineSet.intersection(theirs).count)
            let jaccard = shared / Double(mineSet.union(theirs).count)
            let containment = shared / Double(mineSet.count)
            if jaccard >= 0.6 || containment >= 0.8 { return true }
        }
        return false
    }

    /// Joins consecutive lines of the same speaker separated by less than a second.
    private static func joinFragments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for segment in segments {
            if var last = result.last, last.speaker == segment.speaker, last.track == segment.track,
               segment.start - last.end < 1.0, words(last.text).count < 120 {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }

    /// Backchannel words: a line made only of these carries no content.
    static let fillerWords: Set<String> = [
        "mm", "mhm", "hmm", "hm", "uh", "um", "ah", "eh", "oh", "huh", "okay", "ok", "oke", "yeah", "yep", "yup",
        "yes", "ya", "right", "alright", "correct", "sure", "cool", "nice", "noted",
    ]

    /// "Mm.", "Okay, okay.", "Yeah, correct." — nothing but backchannel.
    static func isFillerOnly(_ text: String) -> Bool {
        let w = words(text)
        return !w.isEmpty && w.count <= 4 && w.allSatisfy { fillerWords.contains($0) }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// "[HH:MM:SS] Speaker: text" lines, as sent to the notes model, with "[audio missing …]" lines where
    /// a part of the recording could not be transcribed.
    static func plainText(_ segments: [TranscriptSegment], gaps: [ClosedRange<Double>] = []) -> String {
        var lines = segments.map { (start: $0.start, text: "[\(Timecode.format($0.start))] \($0.speaker): \($0.text)") }
        lines += gaps.map { (start: $0.lowerBound, text: "[audio missing \(Timecode.format($0.lowerBound))–\(Timecode.format($0.upperBound))]") }
        return lines.sorted { $0.start < $1.start }.map(\.text).joined(separator: "\n")
    }

    /// Stretches whose audio could not be transcribed (failed chunk tracks).
    static func gaps(in chunks: [ChunkRecord]) -> [ClosedRange<Double>] {
        chunks.filter { $0.me.state == .failed || $0.others.state == .failed }
            .map { $0.start...($0.start + $0.duration) }
    }
}
