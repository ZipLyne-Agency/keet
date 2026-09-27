import AVFoundation

/// A short, soft two-note chime played when a hold becomes a dictation, so you know
/// Keet is listening before you start talking. Synthesized in code, so there's no
/// sound file to ship. Tested leaking into the microphone at a level louder than
/// speech: the model ignores it.
@MainActor
final class StartSound {
    private let player: AVAudioPlayer?

    init() {
        player = try? AVAudioPlayer(data: Self.makeWAV())
        player?.volume = 0.35
        player?.prepareToPlay()
    }

    func play() {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    private static func makeWAV() -> Data {
        let rate = 44_100
        var samples: [Int16] = []
        // D6 then G6, each with a 4 ms attack and a quick exponential fade.
        for (frequency, duration) in [(1174.66, 0.045), (1567.98, 0.06)] {
            let count = Int(Double(rate) * duration)
            for i in 0..<count {
                let t = Double(i) / Double(rate)
                let envelope = min(1, t / 0.004) * exp(-t / (duration / 3.2))
                samples.append(Int16(sin(2 * .pi * frequency * t) * envelope * 0.8 * Double(Int16.max)))
            }
        }
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(payload))
        for s in samples { put(s) }
        return data
    }
}
