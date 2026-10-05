import CryptoKit
import Foundation
import os
import whisper

private let log = Logger(subsystem: "agency.ziplyne.keet", category: "hebrew")

/// ivrit.ai's Hebrew fine-tune of Whisper Large v3 Turbo, run by whisper.cpp on the GPU.
///
/// On ivrit.ai's Hebrew leaderboard it is level with the best cloud service and within a
/// few tenths of a point of ivrit.ai's full Large v3. On an M5 Max it encodes in about
/// 135 ms and writes a token in about 1.6 ms, so a few seconds of speech take 200 to
/// 350 ms. The same weights converted to Core ML ran 2 to 4 times slower through
/// WhisperKit and got more words wrong (see docs/REMAKE.md, "Hebrew").
public final class HebrewTranscriber: @unchecked Sendable {
    /// ivrit-ai/whisper-large-v3-turbo-ggml, pinned to one revision and checked by SHA-256.
    public static let repository = "ivrit-ai/whisper-large-v3-turbo-ggml"
    public static let revision = "2130c78e4a9cb4914cc4df91a1c3031407789705"
    static let fileName = "ggml-model.bin"
    static let modelBytes: Int64 = 1_624_555_275
    static let modelSHA256 = "c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1"

    public static let modelDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Keet/Models/ivrit-ai-whisper-large-v3-turbo", isDirectory: true)
    static var modelFile: URL { modelDirectory.appendingPathComponent(fileName) }

    /// A file of the right size is in place. Keet and fetch-model.sh only move it there
    /// after checking its SHA-256; `verifyModel()` checks the hash again.
    public static var modelIsPresent: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelFile.path)[.size] as? NSNumber)?.int64Value
        return size == modelBytes
    }

    /// The model on disk is whole and unaltered: right size and right SHA-256. A file
    /// that fails is deleted, so the next attempt downloads it again. Reads the whole
    /// file, so call it off the main thread.
    public static func verifyModel() -> Bool {
        guard modelIsPresent else { return false }
        if (try? sha256(of: modelFile)) == modelSHA256 { return true }
        log.error("hebrew model failed its checksum; deleting it")
        try? FileManager.default.removeItem(at: modelFile)
        return false
    }

    /// whisper.cpp contexts aren't thread safe; every call runs here, one at a time.
    private let queue = DispatchQueue(label: "keet.hebrew", qos: .userInitiated)
    private var context: OpaquePointer?

    public init() {
        Self.silenceLibraryLogs()
    }

    deinit {
        if let context { whisper_free(context) }
    }

    // MARK: - Model

    /// Downloads the model (1.6 GB) and verifies it. `progress` gets 0...1.
    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let url = URL(string: "https://huggingface.co/\(Self.repository)/resolve/\(Self.revision)/\(Self.fileName)")!
        let downloaded = try await Downloader.fetch(url, progress: progress)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let size = (try FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.int64Value
        guard size == Self.modelBytes, try Self.sha256(of: downloaded) == Self.modelSHA256 else {
            throw HebrewError.checksumMismatch
        }
        try FileManager.default.createDirectory(at: Self.modelDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: Self.modelFile)
        try FileManager.default.moveItem(at: downloaded, to: Self.modelFile)
    }

    /// Loads the model onto the GPU. About half a second once the file is cached.
    public func load() async throws {
        try await run { [self] in
            guard context == nil else { return }
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            guard let loaded = whisper_init_from_file_with_params(Self.modelFile.path, params) else {
                throw HebrewError.loadFailed
            }
            context = loaded
        }
    }

    /// Frees the model's memory (about 2 GB) when Hebrew is switched off.
    public func unload() {
        queue.async { [self] in
            if let context { whisper_free(context) }
            context = nil
        }
    }

    /// The first run builds the GPU pipelines, so do it at launch rather than on the
    /// first Hebrew dictation.
    public func warmUp() async throws {
        var noise = [Float](repeating: 0, count: Transcriber.sampleRate)
        for i in noise.indices { noise[i] = Float.random(in: -1e-4...1e-4) }
        _ = try await transcribe(noise, minimumSeconds: 0)
    }

    // MARK: - Transcription

    /// Transcribes 16 kHz mono samples. Whisper invents words for very short or empty
    /// audio, so anything under `minimumSeconds` comes back empty.
    public func transcribe(_ samples: [Float], minimumSeconds: Double = 0.3) async throws -> String {
        guard Double(samples.count) >= Double(Transcriber.sampleRate) * minimumSeconds else { return "" }
        return try await run { [self] in
            guard let context else { throw HebrewError.notLoaded }
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            params.translate = false
            params.no_context = true
            params.no_timestamps = true
            params.print_special = false
            params.print_progress = false
            params.print_realtime = false
            params.print_timestamps = false
            params.suppress_blank = true
            params.suppress_nst = true
            params.detect_language = false
            let status = "he".withCString { language in
                params.language = language
                return samples.withUnsafeBufferPointer {
                    whisper_full(context, params, $0.baseAddress, Int32($0.count))
                }
            }
            guard status == 0 else { throw HebrewError.transcriptionFailed(Int(status)) }
            let text = (0..<whisper_full_n_segments(context))
                .compactMap { whisper_full_get_segment_text(context, $0).map { String(cString: $0) } }
                .joined()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: - Helpers

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// whisper.cpp and ggml print model and GPU details to stderr; keep errors only, in
    /// Keet's log. Neither prints transcripts.
    private static let silenceOnce: Void = {
        let callback: ggml_log_callback = { level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            let message = String(cString: text)
            // The framework is built to try a Core ML encoder first. There isn't one (the
            // Metal encoder is faster on Apple GPUs), so it falls back every load.
            guard !message.contains("Core ML model") else { return }
            log.error("whisper.cpp: \(message, privacy: .public)")
        }
        whisper_log_set(callback, nil)
    }()

    private static func silenceLibraryLogs() { _ = silenceOnce }
}

public enum HebrewError: LocalizedError {
    case checksumMismatch, loadFailed, notLoaded
    case transcriptionFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch: "The Hebrew model didn't download completely. Try again."
        case .loadFailed: "The Hebrew model couldn't be loaded."
        case .notLoaded: "The Hebrew model isn't loaded."
        case .transcriptionFailed(let code): "Hebrew transcription failed (\(code))."
        }
    }
}

/// One file download with progress, cancelled when the calling task is.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastReport = -1.0

    private init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    static func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let downloader = Downloader(progress: progress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : HebrewTranscriber.modelBytes
        let fraction = Double(totalBytesWritten) / Double(expected)
        if fraction - lastReport >= 0.01 {
            lastReport = fraction
            progress(min(fraction, 1))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            continuation?.resume(throwing: URLError(.badServerResponse))
            continuation = nil
            return
        }
        // The system deletes `location` when this returns, so move it somewhere ours.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("keet-hebrew-\(UUID().uuidString).bin")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
