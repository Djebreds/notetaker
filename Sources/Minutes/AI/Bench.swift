import AVFAudio
import Foundation

/// Command-line model bake-off:
///
///     Minutes --bench <dir> [--models a,b] [--notes-models x,y] [--urgent] [--no-zdr]
///
/// Transcribes every <name>.flac in <dir> with each model and scores it against <name>.txt / <name>.json
/// (word error rate, start-time error, words invented in silence, cost, latency). Then writes notes for
/// the code-switching clip with each notes model, for side-by-side reading. Results go to <dir>/output.
nonisolated enum Bench {
    static let defaultModels = [
        "google/gemini-3.8-flash", "microsoft/mai-transcribe-2", "google/gemini-3.1-flash-lite",
    ]
    static let defaultNotesModels = [
        "openai/gpt-6-luna", "google/gemini-3.8-flash", "google/gemini-3.5-flash-lite", "deepseek/deepseek-v4.1-flash",
    ]

    struct Reference: Decodable { let start: Double; let speaker: String; let text: String }

    struct Row {
        let model: String
        let file: String
        let wer: Double
        let startError: Double?
        let inventedWords: Int
        let cost: Double
        let seconds: Double
        let audioSeconds: Double
        let note: String
    }

    static func run(_ args: [String]) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)  // show progress line by line even when redirected
        guard let dirIndex = args.firstIndex(of: "--bench"), dirIndex + 1 < args.count else {
            print("usage: Minutes --bench <dir> [--models a,b] [--notes-models x,y] [--urgent] [--no-zdr]")
            return 2
        }
        let dir = URL(fileURLWithPath: args[dirIndex + 1])
        let models = list(args, "--models") ?? defaultModels
        let notesModels = list(args, "--notes-models") ?? defaultNotesModels
        let urgent = args.contains("--urgent")
        let zdr = !args.contains("--no-zdr")
        guard let client = try? OpenRouterClient.fromKeychain() else {
            print("No OpenRouter key. Save it in the app's Settings, or run with OPENROUTER_API_KEY=… set.")
            return 1
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "flac" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            print("No .flac files in \(dir.path). Generate some with scripts/make-bench-audio.py.")
            return 1
        }
        let output = Paths.ensure(dir.appendingPathComponent("output"))
        print("Transcription bench: \(files.count) clips × \(models.count) models (zdr: \(zdr), urgent: \(urgent))\n")

        var rows: [Row] = []
        var transcripts: [String: [RawSegment]] = [:]
        for model in models {
            for file in files {
                let row = await transcribe(file: file, model: model, client: client, zdr: zdr, urgent: urgent, output: output)
                rows.append(row.row)
                if let segments = row.segments { transcripts["\(model)|\(file.lastPathComponent)"] = segments }
                print(format(row.row))
            }
        }

        print("\nPer model (mean WER, mean start error, invented words, est. cost per meeting-hour with both tracks):")
        for model in models {
            let mine = rows.filter { $0.model.hasPrefix(model) && $0.note.isEmpty }
            guard !mine.isEmpty else {
                print("  \(model.padding(toLength: 34, withPad: " ", startingAt: 0)) failed: \(rows.first { $0.model.hasPrefix(model) }?.note ?? "")")
                continue
            }
            let wer = mine.map(\.wer).reduce(0, +) / Double(mine.count)
            let errors = mine.compactMap(\.startError)
            let startError = errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count)
            let invented = mine.map(\.inventedWords).reduce(0, +)
            let audio = mine.map(\.audioSeconds).reduce(0, +)
            let perHour = audio > 0 ? mine.map(\.cost).reduce(0, +) / audio * 3600 * 2 : 0
            print(String(format: "  %-34@ WER %5.1f%%  Δstart %4.1fs  invented %2d  ~$%.3f/h  %@",
                         model as NSString, wer * 100, startError, invented, perHour,
                         (mine.count < files.count ? "(some clips failed)" : "") as NSString))
        }

        // Notes comparison on the code-switching clip, using the best transcript we got for it.
        let notesSource = transcripts.filter { $0.key.hasSuffix("mixed-codeswitch.flac") }
            .min { werFor($0.key, rows) < werFor($1.key, rows) }
        if let notesSource {
            let segments = notesSource.value.map {
                TranscriptSegment(start: $0.start, end: $0.start + 3, speaker: $0.speaker, text: $0.text, track: .others)
            }
            print("\nNotes bench on mixed-codeswitch (transcript from \(notesSource.key.split(separator: "|")[0])):")
            for model in notesModels {
                let generator = NotesGenerator(client: client, model: model, zeroRetention: zdr)
                let started = Date()
                do {
                    let result = try await generator.generate(transcript: segments, context: .init(
                        date: Date(), appName: "Google Meet", duration: 25, language: .english, customInstructions: ""))
                    let meeting = Meeting(id: UUID(), folder: "", title: result.notes.title, trigger: .manual,
                                          startedAt: Date(), endedAt: Date().addingTimeInterval(25), status: .done)
                    let md = MarkdownExporter.markdown(meeting: meeting, notes: result.notes, transcript: [], includeTranscript: false)
                    let url = output.appendingPathComponent("notes-\(safe(model)).md")
                    try? md.write(to: url, atomically: true, encoding: .utf8)
                    print(String(format: "  %-34@ $%.5f  %4.1fs  → %@", model as NSString, result.cost,
                                 Date().timeIntervalSince(started), url.lastPathComponent as NSString))
                } catch {
                    print("  \(model): \(error.localizedDescription)")
                }
            }
        }
        print("\nOutputs written to \(output.path)")
        return 0
    }

    private static func transcribe(file: URL, model: String, client: OpenRouterClient, zdr: Bool, urgent: Bool,
                                   output: URL) async -> (row: Row, segments: [RawSegment]?) {
        let name = file.deletingPathExtension().lastPathComponent
        let track: Track = name.hasSuffix("-me") ? .me : .others
        let references = (try? JSONDecoder().decode([Reference].self,
                                                    from: Data(contentsOf: file.deletingPathExtension().appendingPathExtension("json")))) ?? []
        let referenceText = (try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) ?? ""
        let duration = audioDuration(file)

        var zeroRetention = zdr
        var note = ""
        for attempt in 0..<2 {
            do {
                let transcriber = TranscriberFactory.make(model: model, client: client, zeroRetention: zeroRetention)
                let result = try await Retry.run { try await transcriber.transcribe(TranscriptionJob(
                    audioURL: file, track: track, duration: duration, knownSpeakers: [], previousLines: [], urgent: urgent)) }
                let hypothesis = result.segments.map(\.text).joined(separator: " ")
                let wer = wordErrorRate(reference: referenceText, hypothesis: hypothesis)
                let firstSpeech = references.first?.start ?? 0
                let invented = result.segments.filter { $0.start < firstSpeech - 1.5 }
                    .reduce(0) { $0 + TranscriptMerger.words($1.text).count }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                let modelDir = Paths.ensure(output.appendingPathComponent(safe(model)))
                try? encoder.encode(result.segments).write(to: modelDir.appendingPathComponent("\(name).json"))
                let row = Row(model: model + (zeroRetention ? "" : " (no ZDR)"), file: name, wer: wer,
                              startError: startError(references, result.segments), inventedWords: invented,
                              cost: result.cost, seconds: result.seconds, audioSeconds: duration,
                              note: "")
                return (row, result.segments)
            } catch {
                note = error.localizedDescription
                // Models without zero-data-retention endpoints fail with ZDR on; measure them anyway.
                if attempt == 0, zeroRetention, note.lowercased().contains("endpoint") || note.lowercased().contains("provider") || note.lowercased().contains("data policy") {
                    zeroRetention = false
                    continue
                }
                break
            }
        }
        return (Row(model: model, file: name, wer: 1, startError: nil, inventedWords: 0, cost: 0, seconds: 0,
                    audioSeconds: duration, note: note), nil)
    }

    /// Mean |Δ| between each reference utterance's start and the start of the predicted segment that
    /// shares the most words with it.
    private static func startError(_ references: [Reference], _ segments: [RawSegment]) -> Double? {
        guard !references.isEmpty, !segments.isEmpty else { return nil }
        var total = 0.0
        for reference in references {
            let words = Set(TranscriptMerger.words(reference.text))
            guard let best = segments.max(by: {
                Set(TranscriptMerger.words($0.text)).intersection(words).count < Set(TranscriptMerger.words($1.text)).intersection(words).count
            }) else { continue }
            total += abs(best.start - reference.start)
        }
        return total / Double(references.count)
    }

    /// Writes notes for an existing meeting with a given profile and prints them (nothing is saved):
    ///     Minutes --notes-preview <meeting-folder> [--name X] [--role Y] [--focus Z] [--model M]
    static func notesPreview(_ args: [String]) async -> Int32 {
        guard let i = args.firstIndex(of: "--notes-preview"), i + 1 < args.count else { return 2 }
        let folder = URL(fileURLWithPath: args[i + 1])
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let client = try? OpenRouterClient.fromKeychain(),
              let meeting = try? decoder.decode(Meeting.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json"))),
              let transcript = try? decoder.decode([TranscriptSegment].self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json"))) else {
            print("Needs an API key and a meeting folder with meeting.json and transcript.json")
            return 1
        }
        let profile = ReaderProfile(name: value("--name") ?? "", role: value("--role") ?? "", focus: value("--focus") ?? "")
        let generator = NotesGenerator(client: client, model: value("--model") ?? AppSettings.defaultNotesModel, zeroRetention: true)
        do {
            let result = try await generator.generate(transcript: transcript, context: .init(
                date: meeting.startedAt, appName: meeting.appName, duration: meeting.duration, language: .english,
                customInstructions: "", profile: profile))
            print(MarkdownExporter.markdown(meeting: meeting, notes: result.notes, transcript: [], includeTranscript: false))
            print(String(format: "(cost $%.4f)", result.cost))
            return 0
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Runs the bleed detector on a mic file and a system-audio file (any format, any rate):
    ///     Minutes --bleed-test <mic-file> <system-file>
    static func bleedTest(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--bleed-test"), i + 2 < args.count,
              let mic = loadMono16k(URL(fileURLWithPath: args[i + 1])),
              let system = loadMono16k(URL(fileURLWithPath: args[i + 2])) else {
            print("usage: Minutes --bleed-test <mic-file> <system-file>")
            return 2
        }
        let started = Date()
        let maxLag = args.firstIndex(of: "--max-lag").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 400
        let result = BleedDetector.detect(mic: mic, system: system, muted: [], maxLagMs: maxLag)
        print(String(format: "delay: %@ · windows: bleed %d, double talk %d, local %d · silenced %.1f s of %.1f s · %.2f s",
                     result.delayMs.map { String(format: "%.1f ms", $0) } ?? "none (no echo path)",
                     result.bleedWindows, result.doubleTalkWindows, result.localWindows, result.bleedSeconds,
                     Double(mic.count) / 16_000, Date().timeIntervalSince(started)))
        for r in result.ranges { print(String(format: "  silence %7.2f – %7.2f s", r.lowerBound, r.upperBound)) }
        return 0
    }

    static func loadMono16k(_ url: URL) -> [Int16]? {
        guard let file = try? AVAudioFile(forReading: url),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil else { return nil }
        let resampler = Resampler()
        guard let converted = resampler.convert(input), let channel = converted.floatChannelData?[0] else { return nil }
        return (0..<Int(converted.frameLength)).map { Int16(max(-1, min(1, channel[$0])) * 32767) }
    }

    /// Runs speaker recognition on a meeting folder's others track and prints the voices (nothing saved):
    ///     Minutes --speakers <meeting-folder> [--count N]
    static func speakersTest(_ args: [String]) async -> Int32 {
        guard let i = args.firstIndex(of: "--speakers"), i + 1 < args.count else { return 2 }
        let folder = URL(fileURLWithPath: args[i + 1])
        let count = args.firstIndex(of: "--count").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let meeting = try? decoder.decode(Meeting.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json"))) else {
            print("No meeting.json in \(folder.path)")
            return 1
        }
        let chunks = meeting.chunks.compactMap { c in c.others.file.map { (start: c.start, url: folder.appendingPathComponent($0)) } }
        let duration = meeting.chunks.map { $0.start + $0.duration }.max() ?? 0
        let started = Date()
        do {
            let analysis = try await SpeakerIdentifier.shared.analyze(chunks: chunks, duration: duration, expectedSpeakers: count)
            print(String(format: "%d voices, %d turns, %.1f s for %.0f min", analysis.speakers.count, analysis.turns.count,
                         Date().timeIntervalSince(started), duration / 60))
            for s in analysis.speakers {
                let others = analysis.speakers.filter { $0.id != s.id }
                    .map { String(format: "%@ %.2f", $0.id, Voiceprint.similarity(s.embedding, $0.embedding)) }
                print(String(format: "  %@: %5.1f min  (similarity to others: %@)", s.id, s.seconds / 60, others.joined(separator: ", ")))
            }
            return 0
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }

    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let r = TranscriptMerger.words(reference), h = TranscriptMerger.words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var previous = Array(0...h.count)
        for i in 1...r.count {
            var current = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[h.count]) / Double(r.count)
    }

    private static func audioDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private static func werFor(_ key: String, _ rows: [Row]) -> Double {
        let parts = key.split(separator: "|").map(String.init)
        return rows.first { $0.model.hasPrefix(parts[0]) && parts[1].hasPrefix($0.file) }?.wer ?? 1
    }

    private static func format(_ row: Row) -> String {
        if !row.note.isEmpty {
            return "  \(row.model.padding(toLength: 34, withPad: " ", startingAt: 0)) \(row.file.padding(toLength: 24, withPad: " ", startingAt: 0)) FAILED: \(row.note.prefix(140))"
        }
        return String(format: "  %-34@ %-24@ WER %5.1f%%  Δstart %@  invented %d  $%.5f  %4.1fs",
                      row.model as NSString, row.file as NSString, row.wer * 100,
                      (row.startError.map { String(format: "%4.1fs", $0) } ?? "  n/a") as NSString,
                      row.inventedWords, row.cost, row.seconds)
    }

    private static func list(_ args: [String], _ flag: String) -> [String]? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func safe(_ model: String) -> String {
        model.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }
}
