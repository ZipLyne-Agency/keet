import CoreML
import FluidAudio
import Foundation

/// Parakeet Unified 0.6B (English) through FluidAudio's offline batch manager.
/// The encoder runs on the Neural Engine; decoding runs on the CPU.
public final class Transcriber: @unchecked Sendable {
    public static let sampleRate = 16_000

    public static let modelDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models/parakeet-unified-en-0.6b", isDirectory: true)

    // Weight files are written last (and only after a checksum passes), so their
    // presence means the bundle is complete. CoreML crashes on a partial bundle.
    private static let requiredFiles = [
        ModelNames.ParakeetUnified.offlineEncoderInt8File + "/weights/weight.bin",
        ModelNames.ParakeetUnified.decoderFile + "/weights/weight.bin",
        ModelNames.ParakeetUnified.jointDecisionFile + "/weights/weight.bin",
        ModelNames.ParakeetUnified.vocab,
    ]

    private let manager = UnifiedAsrManager()
    private let converter = AudioConverter()

    public init() {}

    public static var modelIsPresent: Bool {
        requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }
    }

    /// Loads the model from the local cache, downloading it first when it is missing.
    public func load() async throws {
        if Self.modelIsPresent {
            try await manager.loadModels(from: Self.modelDirectory)
        } else {
            try await manager.loadModels(to: nil, configuration: nil, progressHandler: nil)
        }
    }

    /// The first prediction compiles the Neural Engine plan, so run one at launch
    /// instead of making the first dictation of the day wait for it.
    public func warmUp() async throws {
        var noise = [Float](repeating: 0, count: Self.sampleRate)
        for i in noise.indices { noise[i] = Float.random(in: -1e-4...1e-4) }
        _ = try await manager.transcribe(noise)
    }

    /// Transcribes 16 kHz mono samples. `trailingPadMs` appends near-silence after the
    /// last sample. Measured on clips cut exactly at the end of the final word, padding
    /// made no difference (12/12 either way); what loses the last word is audio that
    /// stops before the word does, which the recorder's tail prevents. So it defaults to 0.
    public func transcribe(_ samples: [Float], trailingPadMs: Int = Transcriber.defaultTrailingPadMs) async throws -> String {
        guard samples.count >= Self.sampleRate / 10 else { return "" }
        var input = samples
        if trailingPadMs > 0 {
            input.append(contentsOf: Self.quietPad(ms: trailingPadMs))
        }
        let text = try await manager.transcribe(input)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static var defaultTrailingPadMs = 0

    /// Near-silent dither rather than exact zeros, so the per-feature mel
    /// normalization never sees a run of log(0).
    static func quietPad(ms: Int) -> [Float] {
        var pad = [Float](repeating: 0, count: sampleRate * ms / 1000)
        for i in pad.indices { pad[i] = Float.random(in: -3e-5...3e-5) }
        return pad
    }

    public func resample(_ samples: [Float], from rate: Double) throws -> [Float] {
        if rate == Double(Self.sampleRate) { return samples }
        return try converter.resample(samples, from: rate)
    }

    public func loadAudioFile(_ url: URL) throws -> [Float] {
        try converter.resampleAudioFile(url)
    }
}
