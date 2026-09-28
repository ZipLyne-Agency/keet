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

    private let converter = AudioConverter()
    private let lock = NSLock()
    private var _manager = UnifiedAsrManager()
    private var ctcModels: CtcModels?
    private var vocabularyActive = false

    /// Swapped out when the dictionary is cleared (FluidAudio can't switch boosting off).
    private var manager: UnifiedAsrManager {
        get { lock.lock(); defer { lock.unlock() }; return _manager }
        set { lock.lock(); _manager = newValue; lock.unlock() }
    }

    public init() {}

    /// A word the model should prefer, with what it tends to hear instead.
    public struct VocabularyWord: Sendable, Equatable {
        public let text: String
        public let heardAs: [String]

        public init(text: String, heardAs: [String] = []) {
            self.text = text
            self.heardAs = heardAs
        }
    }

    /// How alike a heard word must be to a dictionary word (or one of its "heard as"
    /// spellings) before it can be replaced. FluidAudio's default (about 0.5) let
    /// "headline" become "HotLyne" through the alias "hotline"; 0.7 kept every real fix
    /// in testing and removed both false ones. KEET_VOCAB_MINSIM overrides it.
    static let termMinSimilarity: Float = 0.7
    /// Short words are one letter away from common English: at 0.7, "Keet" replaced
    /// every "keep" and "meet". Up to five letters, a heard word must match the
    /// dictionary word or one of its "heard as" spellings exactly (0.85 rules out any
    /// single-letter difference at that length).
    static let shortTermMinSimilarity: Float = 0.85

    static func minSimilarity(for term: String) -> Float {
        if let override = ProcessInfo.processInfo.environment["KEET_VOCAB_MINSIM"].flatMap(Float.init) { return override }
        return term.count <= 5 ? shortTermMinSimilarity : termMinSimilarity
    }

    /// Whether the word-spotting model the Dictionary needs is on disk.
    public static var dictionaryModelIsPresent: Bool {
        CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory())
    }

    /// Makes the model prefer these words. The first call loads (or downloads, about
    /// 100 MB) Parakeet CTC 110M, which spots the words in the audio; a transcript word
    /// is replaced only when the audio supports the dictionary word better.
    public func setVocabulary(_ words: [VocabularyWord]) async throws {
        if words.isEmpty {
            guard vocabularyActive else { return }
            let fresh = UnifiedAsrManager()
            try await fresh.loadModels(from: Self.modelDirectory)
            manager = fresh
            vocabularyActive = false
            return
        }
        if ctcModels == nil {
            let directory = CtcModels.defaultCacheDirectory()
            ctcModels = CtcModels.modelsExist(at: directory)
                ? try await CtcModels.load(from: directory)
                : try await CtcModels.downloadAndLoad()
        }
        guard let ctcModels else { return }
        let context = CustomVocabularyContext(terms: words.map {
            CustomVocabularyTerm(
                text: $0.text, aliases: $0.heardAs.isEmpty ? nil : $0.heardAs,
                minSimilarity: Self.minSimilarity(for: $0.text))
        })
        try await manager.configureVocabularyBoosting(vocabulary: context, ctcModels: ctcModels)
        vocabularyActive = true
    }

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
