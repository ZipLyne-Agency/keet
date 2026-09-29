import AVFoundation
import Foundation
import KeetCore

// keet-bench transcribe <file>...          load time, warm-up time, per-file latency and text
// keet-bench lastword <dir>                 cut each clip at the end of its last word and
//                                           compare transcripts across trailing pads
// keet-bench tail <dir> [noise dB] [gain dB] release 40 ms before the last word ends, with room
//                                           noise mixed in, and see where the tail stops
// keet-bench noise <dir> [noise dB] [peak dB...]  word error rate by speech level over room noise
// keet-bench vocab <dir> <words.txt>        transcripts without and with a dictionary
// keet-bench mic <seconds>                  microphone start latency, then transcribe
// keet-bench recover                        start a microphone engine that gets no audio, as
//                                           after sleep, and check the rebuild brings it back
// keet-bench cleanup <history.json|lines.txt> [dictionary.json]
//                                           run the AI cleanup over real transcripts: what it
//                                           changed, what it refused, and how long it took

func now() -> Double { CFAbsoluteTimeGetCurrent() }
func ms(_ t: Double) -> String { String(format: "%.0f ms", t * 1000) }

func normalizeWords(_ s: String) -> [String] {
    s.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
        .filter { !$0.isEmpty }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("usage: keet-bench transcribe <file>... | lastword <dir> | mic <seconds>")
    exit(2)
}

if command == "speakers" {
    // Mutes the default output the way a dictation does, checks, then restores.
    func mutedNow() -> String {
        let out = Process()
        out.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        out.arguments = ["-e", "output muted of (get volume settings)"]
        let pipe = Pipe(); out.standardOutput = pipe
        try? out.run(); out.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }
    let mute = SpeakerMute()
    print("before: muted \(mutedNow())")
    print("mute(): \(mute.mute())")
    print("during: muted \(mutedNow())")
    usleep(500_000)
    mute.restore()
    print("after: muted \(mutedNow())")
    exit(0)
}

if command == "recover" {
    let recorder = AudioRecorder()
    AudioRecorder.dropAudioOnNextBuild = true
    try recorder.start()
    let started = now()
    while recorder.capturedCount == 0 && now() - started < recorder.firstAudioTimeout { usleep(5_000) }
    print("deaf engine: \(recorder.capturedCount) samples after \(ms(now() - started))")
    let rebuilt = now()
    try recorder.rebuildAndRestart()
    while recorder.capturedCount == 0 && now() - rebuilt < 2 { usleep(1_000) }
    let first = now() - rebuilt
    usleep(300_000)
    let captured = recorder.capturedCount
    print("after rebuild: first audio \(ms(first)), \(captured) samples in the next 300 ms at \(Int(recorder.sampleRate)) Hz on \(recorder.activeDeviceName ?? "?")")
    _ = recorder.stop()
    exit(captured == 0 ? 1 : 0)
}

if command == "cleanup" {
    try await runCleanup(Array(args.dropFirst()))
    exit(0)
}

let transcriber = Transcriber()
var t0 = now()
try await transcriber.load()
print("load: \(ms(now() - t0))")
t0 = now()
try await transcriber.warmUp()
print("warm-up (first prediction): \(ms(now() - t0))")

switch command {
case "transcribe":
    for path in args.dropFirst() {
        let samples = try transcriber.loadAudioFile(URL(fileURLWithPath: path))
        let start = now()
        let text = try await transcriber.transcribe(samples)
        let secs = Double(samples.count) / 16_000
        print(String(format: "[%.1fs audio, %@] %@", secs, ms(now() - start), text))
    }

case "lastword":
    let dir = URL(fileURLWithPath: args[1])
    let wavs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    // (label, cut offset from end of speech in ms, pad ms)
    let variants: [(String, Int, Int)] = [
        ("cut+0 pad0", 0, 0), ("cut+0 pad150", 0, 150), ("cut+0 pad300", 0, 300), ("cut+0 pad500", 0, 500),
        ("cut-40 pad0", -40, 0), ("cut-40 pad300", -40, 300),
        ("cut+80 pad0", 80, 0),
    ]
    var hits = [String: Int]()
    var wordErrors = [String: Int]()
    for wav in wavs {
        let expected = try String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        let expectedWords = normalizeWords(expected)
        let samples = try transcriber.loadAudioFile(wav)
        var tracker = EnergyTracker(sampleRate: 16_000)
        tracker.consume(samples)
        let threshold = tracker.peakDb - 40
        let lastSpeechFrame = tracker.framesDb.lastIndex { $0 >= threshold } ?? (tracker.framesDb.count - 1)
        let speechEnd = (lastSpeechFrame + 1) * 160
        print("\n\(wav.lastPathComponent): expect \"\(expected.trimmingCharacters(in: .whitespacesAndNewlines))\"  (speech ends \(speechEnd * 1000 / 16_000) ms)")
        for (label, offset, pad) in variants {
            let end = min(samples.count, max(0, speechEnd + offset * 16))
            let clip = Array(samples[0..<end])
            let start = now()
            let text = try await transcriber.transcribe(clip, trailingPadMs: pad)
            let elapsed = now() - start
            let got = normalizeWords(text)
            let ok = got.last == expectedWords.last
            if ok { hits[label, default: 0] += 1 }
            let missing = expectedWords.filter { !got.contains($0) }.count
            wordErrors[label, default: 0] += missing
            print("  \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(ok ? "OK  " : "MISS") \(ms(elapsed).padding(toLength: 7, withPad: " ", startingAt: 0)) \(text)")
        }
    }
    print("\nlast word correct / \(wavs.count) clips, plus missing words overall:")
    for (label, _, _) in variants {
        print("  \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(hits[label, default: 0])  missing \(wordErrors[label, default: 0])")
    }

case "tail":
    // Replays each clip with room noise mixed in, releases the key 40 ms before the
    // last word ends, and runs the recorder's tail rule to see where capture stops.
    let dir = URL(fileURLWithPath: args[1])
    let noiseDb = Float(args.count > 2 ? args[2] : "-55") ?? -55
    let gain = pow(10, (Float(args.count > 3 ? args[3] : "0") ?? 0) / 20)  // speech level change, dB
    let noiseAmp = pow(10, noiseDb / 20) * 1.7  // uniform noise with this RMS
    let wavs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let policy = TailPolicy()
    var tails: [Int] = []
    var lastWordKept = 0
    for wav in wavs {
        let expected = try String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        var clip = try transcriber.loadAudioFile(wav).map { $0 * gain }
        // 80 ms of room before speech (reaction time) and 1 s after it.
        clip = [Float](repeating: 0, count: 1280) + clip + [Float](repeating: 0, count: 16_000)
        // Find where speech ends on the clean clip, before any room noise is added.
        var probe = EnergyTracker(sampleRate: 16_000)
        probe.consume(clip)
        let loud = probe.peakDb - 40
        let speechEnd = ((probe.framesDb.lastIndex { $0 >= loud } ?? 0) + 1) * 160
        for i in clip.indices { clip[i] += Float.random(in: -noiseAmp...noiseAmp) }
        let release = speechEnd - 640  // 40 ms early
        var tracker = EnergyTracker(sampleRate: 16_000)
        tracker.consume(Array(clip[0..<release]))
        var elapsed = 0
        var position = release
        while !policy.shouldStop(elapsedMs: elapsed, trailingQuietMs: tracker.trailingQuietMs) {
            tracker.consume(Array(clip[position..<(position + 160)]))
            position += 160
            elapsed += 10
        }
        let text = try await transcriber.transcribe(Array(clip[0..<position]))
        let kept = normalizeWords(text).last == normalizeWords(expected).last
        if kept { lastWordKept += 1 }
        tails.append(elapsed)
        print("\(wav.lastPathComponent): tail \(elapsed) ms (speech ended \((speechEnd - release) / 16) ms after release), noise \(Int(tracker.noiseFloorDb)) dB, threshold \(Int(tracker.speechThresholdDb)) dB, last word \(kept ? "kept" : "LOST"): \(text)")
    }
    tails.sort()
    print("\nroom noise \(Int(noiseDb)) dB: last word kept \(lastWordKept)/\(wavs.count), tail median \(tails[tails.count / 2]) ms, max \(tails.last ?? 0) ms")

case "noise":
    // Word error rate over the clips when speech sits at a given level over room noise,
    // transcribed as recorded and with the level raised to a -3 dB peak first.
    // Clips 00 and 10 (the robotic voice) are skipped.
    let dir = URL(fileURLWithPath: args[1])
    let noiseDb = Float(args.count > 2 ? args[2] : "-54") ?? -54
    let peaks = args.count > 3 ? args[3...].compactMap(Float.init) : [-12, -24, -30, -36, -42]
    let wavs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" && !["00.wav", "10.wav"].contains($0.lastPathComponent) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    func wordErrors(_ ref: [String], _ hyp: [String]) -> Int {
        var d = Array(0...hyp.count)
        for (i, r) in ref.enumerated() {
            var prev = d[0]; d[0] = i + 1
            for (j, h) in hyp.enumerated() {
                let cur = min(d[j + 1] + 1, d[j] + 1, prev + (r == h ? 0 : 1)); prev = d[j + 1]; d[j + 1] = cur
            }
        }
        return d[hyp.count]
    }
    func norm(_ s: String) -> [String] {
        normalizeWords(s.lowercased().replacingOccurrences(of: "ten thirty", with: "10 30")
            .replacingOccurrences(of: "standup", with: "stand up"))
    }
    let noiseAmp = pow(10, noiseDb / 20) * 1.7
    for peak in peaks {
        var total = 0, errorsRaw = 0, errorsBoosted = 0
        for wav in wavs {
            let ref = norm(try String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8))
            var clip = try transcriber.loadAudioFile(wav)
            let clipPeak = clip.map(abs).max() ?? 1
            let scale = pow(10, peak / 20) / clipPeak
            clip = [Float](repeating: 0, count: 3200) + clip.map { $0 * scale } + [Float](repeating: 0, count: 3200)
            for i in clip.indices { clip[i] += Float.random(in: -noiseAmp...noiseAmp) }
            let boost = pow(10, Float(-3) / 20) / (clip.map(abs).max() ?? 1)
            let raw = norm(try await transcriber.transcribe(clip))
            let boosted = norm(try await transcriber.transcribe(clip.map { $0 * boost }))
            total += ref.count
            errorsRaw += wordErrors(ref, raw)
            errorsBoosted += wordErrors(ref, boosted)
        }
        print(String(format: "speech peak %4.0f dB over %3.0f dB noise (%2.0f dB apart): %4.1f%% word errors as recorded, %4.1f%% boosted",
                     peak, noiseDb, peak - noiseDb, 100 * Double(errorsRaw) / Double(total), 100 * Double(errorsBoosted) / Double(total)))
    }

case "vocab":
    // Transcribes clips without and then with a dictionary. The dictionary file has one
    // word per line, optionally followed by "|" and comma-separated things it's heard as.
    let dir = URL(fileURLWithPath: args[1])
    let words = try String(contentsOfFile: args[2], encoding: .utf8)
        .split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { line -> Transcriber.VocabularyWord in
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let heard = parts.count > 1 ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : []
            return Transcriber.VocabularyWord(text: parts[0], heardAs: heard)
        }
    let wavs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var plain: [String] = [], plainMs: [Double] = []
    for wav in wavs {
        let t = now()
        plain.append(try await transcriber.transcribe(try transcriber.loadAudioFile(wav)))
        plainMs.append(now() - t)
    }
    let t0 = now()
    try await transcriber.setVocabulary(words)
    print("dictionary of \(words.count) words loaded in \(ms(now() - t0))")
    _ = try await transcriber.transcribe(try transcriber.loadAudioFile(wavs[0]))  // warm the word spotter
    for (i, wav) in wavs.enumerated() {
        let t = now()
        let boosted = try await transcriber.transcribe(try transcriber.loadAudioFile(wav))
        let elapsed = now() - t
        let expected = (try? String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) ?? ""
        print("\n\(wav.lastPathComponent)  said:    \(expected.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("  without dictionary (\(ms(plainMs[i]))): \(plain[i])")
        print("  with dictionary    (\(ms(elapsed))): \(boosted)")
    }

case "mic":
    let seconds = Double(args.count > 1 ? args[1] : "3") ?? 3
    let recorder = AudioRecorder()
    var start = now()
    try recorder.prepare()
    print("engine prepare: \(ms(now() - start))")
    for round in 1...3 {
        start = now()
        try recorder.start()
        let started = now()
        while recorder.capturedCount == 0 && now() - start < 2 { usleep(500) }
        print("round \(round): start() \(ms(started - start)), first audio \(ms(now() - start)), device rate \(Int(recorder.sampleRate))")
        usleep(UInt32(seconds * 1_000_000))
        let samples = recorder.stop()
        let pcm = try transcriber.resample(samples, from: recorder.sampleRate)
        let t = now()
        let text = try await transcriber.transcribe(pcm)
        print("  \(String(format: "%.1f", Double(pcm.count) / 16_000))s, transcribe \(ms(now() - t)): \(text)")
    }

default:
    print("unknown command \(command)")
    exit(2)
}

func runCleanup(_ args: [String]) async throws {
    guard let input = args.first else {
        print("usage: keet-bench cleanup <history.json|lines.txt> [dictionary.json]")
        exit(2)
    }
    func jsonTexts(_ path: String) throws -> [String] {
        let items = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]]
        return (items ?? []).compactMap { $0["text"] as? String }
    }
    let texts = input.hasSuffix(".json")
        ? try jsonTexts(input)
        : try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let terms = args.count > 1 ? try jsonTexts(args[1]) : []
    let cleanup = Cleanup()
    print("availability: \(cleanup.availability), \(texts.count) texts, \(terms.count) dictionary words")
    guard cleanup.availability == .ready else { return }

    var notes: [String: Int] = [:]
    var modelMs: [Int] = []
    for text in texts {
        // As in the app: warm the model when the key goes down, then speak.
        cleanup.prepare()
        try await Task.sleep(for: .milliseconds(600))
        let result = await cleanup.clean(text, protecting: terms)
        notes[result.note, default: 0] += 1
        if !result.note.hasPrefix("skipped") { modelMs.append(result.ms) }
        guard result.changed || result.note.hasPrefix("rejected") || result.note.hasPrefix("model") || result.note == "timed out"
        else { continue }
        print("\n[\(result.ms) ms, \(result.note)]")
        print("  raw: \(text)")
        if result.changed { print("  out: \(result.text)") }
    }
    print("\n" + notes.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
    let sorted = modelMs.sorted()
    if !sorted.isEmpty {
        print("model calls: \(sorted.count), median \(sorted[sorted.count / 2]) ms, p90 \(sorted[sorted.count * 9 / 10]) ms, max \(sorted.last!) ms")
    }
}
