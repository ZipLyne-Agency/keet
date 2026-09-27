import Foundation
import Testing
@testable import KeetCore

/// Builds 16 kHz test audio from (level in dBFS, milliseconds) segments. Each segment
/// is a 220 Hz tone at that RMS, plus a little noise so no frame is digital silence.
private func audio(_ segments: [(db: Float, ms: Int)]) -> [Float] {
    var out: [Float] = []
    var phase: Float = 0
    for segment in segments {
        let amplitude = pow(Float(10), segment.db / 20) * Float(2).squareRoot()
        for _ in 0..<(segment.ms * 16) {
            out.append(amplitude * sin(phase) + Float.random(in: -1e-5...1e-5))
            phase += 2 * .pi * 220 / 16_000
        }
    }
    return out
}

/// Runs the tail rule from `releaseMs` into the audio; returns where capture stops (ms).
private func tailStop(_ samples: [Float], releaseMs: Int, policy: TailPolicy = TailPolicy()) -> Int {
    var tracker = EnergyTracker(sampleRate: 16_000)
    tracker.consume(Array(samples[0..<(releaseMs * 16)]))
    var elapsed = 0
    var position = releaseMs * 16
    while !policy.shouldStop(elapsedMs: elapsed, trailingQuietMs: tracker.trailingQuietMs),
          position + 160 <= samples.count {
        tracker.consume(Array(samples[position..<(position + 160)]))
        position += 160
        elapsed += 10
    }
    return position / 16
}

@Test func tailWaitsForASoftWordEnding() {
    // Speech, then a quiet fricative ("ff") that trails 120 ms past the key release.
    let samples = audio([(-60, 100), (-20, 1500), (-50, 120), (-62, 1000)])
    let speechEnds = 100 + 1500 + 120
    let stop = tailStop(samples, releaseMs: 1600)
    #expect(stop >= speechEnds)
    #expect(stop <= speechEnds + TailPolicy().quietMs + 20)
}

@Test func tailIsShortWhenSpeakerAlreadyStopped() {
    let samples = audio([(-60, 100), (-20, 1500), (-62, 1500)])
    // Released 400 ms after the last word: nothing left to wait for.
    let stop = tailStop(samples, releaseMs: 2000)
    #expect(stop - 2000 == TailPolicy().minimumMs)
}

@Test func tailNeverExceedsTheCap() {
    let samples = audio([(-60, 100), (-20, 4000)])
    let stop = tailStop(samples, releaseMs: 1000)
    #expect(stop - 1000 <= TailPolicy().maximumMs + 10)
}

@Test func roomWithoutSpeechStillReadsAsQuiet() {
    // A stray press with nothing said. The threshold must stay above the room
    // noise, or the tail runs to its cap (the 700 ms tails seen on real mics).
    let samples = audio([(-52, 600), (-52, 1000)])
    var tracker = EnergyTracker(sampleRate: 16_000)
    tracker.consume(Array(samples[0..<(600 * 16)]))
    #expect(tracker.speechThresholdDb >= tracker.noiseFloorDb + 6)
    #expect(tailStop(samples, releaseMs: 600) - 600 < 100)
}

@Test func noiseFloorComesFromTheLeadIn() {
    // Talking over nearly the whole hold: the percentile alone would land on speech.
    var tracker = EnergyTracker(sampleRate: 16_000)
    tracker.consume(audio([(-58, 90), (-22, 3000)]))
    #expect(tracker.noiseFloorDb < -50)
}

@Test func loneNoiseSpikesDontHoldTheTailOpen() {
    // A quiet microphone: speech only 18 dB over the room, then a room with clicks.
    var segments: [(db: Float, ms: Int)] = [(-56, 100), (-38, 1500)]
    for _ in 0..<40 { segments += [(-56, 20), (-46, 10)] }  // a 10 ms spike every 30 ms
    let samples = audio(segments)
    let stop = tailStop(samples, releaseMs: 1600)
    #expect(stop - 1600 < TailPolicy().maximumMs)
}
