import Foundation
import Observation

/// A person the user has named, remembered by voice across meetings.
nonisolated struct VoiceProfile: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// L2-normalised voiceprint (running blend of the meetings it was confirmed in).
    var embedding: [Float]
    var samples: Int
    var model: String
    var updatedAt: Date
}

/// Known voices, stored in Application Support/Minutes/voices.json.
@MainActor @Observable
final class VoiceProfiles {
    /// A voice this close to a known person is named automatically…
    static let autoThreshold: Float = 0.70
    /// …this close is offered as a suggestion…
    static let suggestThreshold: Float = 0.55
    /// …and only when the next best person is clearly further away.
    static let tieMargin: Float = 0.03

    private(set) var profiles: [VoiceProfile] = []
    @ObservationIgnored private var url: URL { Paths.appSupport.appendingPathComponent("voices.json") }

    init() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        profiles = (try? decoder.decode([VoiceProfile].self, from: data)) ?? []
    }

    struct Match {
        let profile: VoiceProfile
        let score: Float
        let confident: Bool
    }

    func match(_ embedding: [Float], model: String) -> Match? {
        let scored = profiles.filter { $0.model == model }
            .map { ($0, Voiceprint.similarity($0.embedding, embedding)) }
            .sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= Self.suggestThreshold else { return nil }
        let second = scored.dropFirst().first?.1 ?? -1
        return Match(profile: best.0, score: best.1, confident: best.1 >= Self.autoThreshold && best.1 - second >= Self.tieMargin)
    }

    /// Adds a voice sample under a name: updates the person with that name, or creates them.
    @discardableResult
    func learn(name: String, embedding: [Float], model: String) -> VoiceProfile {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame && $0.model == model }) {
            profiles[i].embedding = Voiceprint.blend(profiles[i].embedding, embedding)
            profiles[i].samples += 1
            profiles[i].updatedAt = Date()
            save()
            return profiles[i]
        }
        let profile = VoiceProfile(id: UUID(), name: key, embedding: embedding, samples: 1, model: model, updatedAt: Date())
        profiles.append(profile)
        save()
        Log.info("Learned a new voice: \(key)", "speakers")
        return profile
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
    }

    /// Names (or suggests names for) a meeting's voices from the known people. Names the user confirmed
    /// in this meeting are kept; one person never names two voices of the same meeting.
    func apply(to analysis: inout SpeakerAnalysis) {
        var taken = Set(analysis.speakers.filter(\.confirmed).compactMap(\.profileID))
        let order = analysis.speakers.indices
            .filter { !analysis.speakers[$0].confirmed }
            .map { i in (i, match(analysis.speakers[i].embedding, model: analysis.model)) }
            .sorted { ($0.1?.score ?? -1) > ($1.1?.score ?? -1) }
        for (i, match) in order {
            analysis.speakers[i].name = nil
            analysis.speakers[i].profileID = nil
            analysis.speakers[i].suggestion = nil
            guard let match, !taken.contains(match.profile.id) else { continue }
            if match.confident {
                analysis.speakers[i].name = match.profile.name
                analysis.speakers[i].profileID = match.profile.id
                taken.insert(match.profile.id)
            } else {
                analysis.speakers[i].suggestion = match.profile.name
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(profiles).write(to: Paths.ensure(Paths.appSupport).appendingPathComponent("voices.json"), options: .atomic)
        } catch {
            Log.error("Saving voices failed: \(error.localizedDescription)", "speakers")
        }
    }
}

/// Puts speaker recognition's voices onto transcript lines.
nonisolated enum SpeakerAssigner {
    /// Each others-track line gets the voice whose turns overlap it most, or the nearest turn within 10 s
    /// (turns shorter than a second are dropped by the diarizer); a line with no voice near it is
    /// "Unknown voice", never the transcription model's own label. Unnamed voices are numbered in order
    /// of appearance.
    static func assign(_ segments: [TranscriptSegment], analysis: SpeakerAnalysis) -> [TranscriptSegment] {
        let turns = analysis.turns
        guard !turns.isEmpty else { return segments }
        var assigned = segments.map { segment -> TranscriptSegment in
            guard segment.track == .others else { return segment }
            let lo = segment.start, hi = max(segment.end, segment.start + 0.5)
            var overlaps: [String: Double] = [:]
            for turn in turns where turn.end > lo && turn.start < hi {
                overlaps[turn.speaker, default: 0] += min(hi, turn.end) - max(lo, turn.start)
            }
            var id = overlaps.max { $0.value < $1.value }?.key
            if id == nil {
                let mid = (lo + hi) / 2
                func distance(_ t: SpeakerTurn) -> Double { mid < t.start ? t.start - mid : (mid > t.end ? mid - t.end : 0) }
                if let nearest = turns.min(by: { distance($0) < distance($1) }), distance(nearest) <= 10 { id = nearest.speaker }
            }
            var copy = segment
            copy.speakerID = id
            return copy
        }
        var numbers: [String: Int] = [:]
        for segment in assigned.sorted(by: { $0.start < $1.start }) {
            guard let id = segment.speakerID, numbers[id] == nil, analysis.speaker(id)?.name == nil else { continue }
            numbers[id] = numbers.count + 1
        }
        for i in assigned.indices where assigned[i].track == .others {
            guard let id = assigned[i].speakerID else {
                assigned[i].speaker = "Unknown voice"
                continue
            }
            assigned[i].speaker = analysis.speaker(id)?.name ?? numbers[id].map { "Speaker \($0)" } ?? "Unknown voice"
        }
        return assigned
    }
}
