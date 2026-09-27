import AVFoundation
import Foundation
import KeetCore

// keet-bench transcribe <file>...          load time, warm-up time, per-file latency and text
// keet-bench lastword <dir>                 cut each clip at the end of its last word and
//                                           compare transcripts across trailing pads
// keet-bench tail <dir> [noise dB]          release 40 ms before the last word ends, with room
//                                           noise mixed in, and see where the tail stops
// keet-bench mic <seconds>                  microphone start latency, then transcribe

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
    let noiseAmp = pow(10, noiseDb / 20) * 1.7  // uniform noise with this RMS
    let wavs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let policy = TailPolicy()
    var tails: [Int] = []
    var lastWordKept = 0
    for wav in wavs {
        let expected = try String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
        var clip = try transcriber.loadAudioFile(wav)
        // 80 ms of room before speech (reaction time) and 1 s after it.
        clip = [Float](repeating: 0, count: 1280) + clip + [Float](repeating: 0, count: 16_000)
        for i in clip.indices { clip[i] += Float.random(in: -noiseAmp...noiseAmp) }
        var probe = EnergyTracker(sampleRate: 16_000)
        probe.consume(clip)
        let loud = probe.peakDb - 40
        let speechEnd = ((probe.framesDb.lastIndex { $0 >= loud } ?? 0) + 1) * 160
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
