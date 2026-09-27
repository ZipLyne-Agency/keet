import Foundation

/// Tracks 10 ms frame loudness for a mono stream so the recorder can tell
/// whether the speaker is still mid-word when the hotkey is released.
public struct EnergyTracker {
    public let frameSize: Int
    public private(set) var framesDb: [Float] = []
    public private(set) var peakDb: Float = -140
    private var sumSquares: Float = 0
    private var filled = 0
    /// 1 dB bins from -140 to 0 dBFS, so percentiles cost the same at any length.
    private var histogram = [Int](repeating: 0, count: 141)

    public init(sampleRate: Double) {
        frameSize = max(1, Int(sampleRate / 100))
        framesDb.reserveCapacity(6000)
    }

    public mutating func consume(_ samples: UnsafeBufferPointer<Float>) {
        for s in samples {
            sumSquares += s * s
            filled += 1
            if filled == frameSize {
                let rms = (sumSquares / Float(frameSize)).squareRoot()
                let db = max(-140, min(0, 20 * log10(max(rms, 1e-7))))
                framesDb.append(db)
                peakDb = max(peakDb, db)
                histogram[Int((db + 140).rounded(.down))] += 1
                sumSquares = 0
                filled = 0
            }
        }
    }

    public mutating func consume(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { consume($0) }
    }

    /// Room noise estimate: the lower of a low percentile of everything heard and
    /// the first 80 ms after the key went down, which is almost always before the
    /// speaker starts talking.
    public var noiseFloorDb: Float {
        guard framesDb.count >= 5 else { return -70 }
        let target = Int(Float(framesDb.count - 1) * 0.15)
        var seen = 0
        var percentile: Float = -70
        for (bin, n) in histogram.enumerated() {
            seen += n
            if seen > target {
                percentile = Float(bin) - 140
                break
            }
        }
        guard framesDb.count >= 8 else { return percentile }
        let lead = framesDb.prefix(8).sorted()
        return min(percentile, lead[4])
    }

    /// Frames above this count as speech: about 9 dB over the room noise, pulled
    /// down toward the loudest speech so quiet word endings still count, but never
    /// within 4 dB of the noise itself (or the room would never read as quiet).
    public var speechThresholdDb: Float {
        let floor = noiseFloorDb
        let preferred = min(max(floor + 9, -62), peakDb - 18)
        return max(preferred, floor + 4)
    }

    /// Milliseconds of continuous non-speech at the end of the stream.
    public var trailingQuietMs: Int {
        let threshold = speechThresholdDb
        var quiet = 0
        for db in framesDb.reversed() {
            if db >= threshold { break }
            quiet += 1
        }
        return quiet * 10
    }

    /// Current loudness mapped to 0...1 for the on-screen meter: silent room reads 0,
    /// ordinary speech moves between roughly 0.3 and 0.9.
    public var meterLevel: Float {
        guard let recent = framesDb.suffix(3).max() else { return 0 }
        let floor = max(noiseFloorDb + 6, -58)
        let x = max(0, min(1, (recent - floor) / (-14 - floor)))
        return pow(x, 1.4)
    }
}

/// How long to keep listening after the hotkey comes up.
public struct TailPolicy: Sendable {
    /// Always wait this long so audio already in flight from the device lands.
    public var minimumMs = 40
    /// Stop once this much continuous quiet has been heard. Soft word endings
    /// ("off", "tests") can sit under the speech threshold, so this also serves as
    /// the margin that keeps them: capture runs this long past the last loud frame.
    public var quietMs = 150
    /// Never keep the microphone open longer than this after release.
    public var maximumMs = 600

    public init() {}

    public func shouldStop(elapsedMs: Int, trailingQuietMs: Int) -> Bool {
        if elapsedMs < minimumMs { return false }
        if elapsedMs >= maximumMs { return true }
        return trailingQuietMs >= quietMs
    }
}
