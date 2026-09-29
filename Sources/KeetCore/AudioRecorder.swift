import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Single-producer sample store. The real-time audio thread appends; any other
/// thread reads up to the published count. No locks or allocation on the audio thread.
final class SampleStore: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit { storage.deallocate() }

    /// Frames the hardware delivered that never reached us (gaps in sample time).
    private let dropped = Atomic<Int>(0)
    /// Next expected sample time. Audio thread only, apart from `reset()`.
    private var expectedSampleTime = -1.0

    /// Only call while the producer is stopped.
    func reset() {
        written.store(0, ordering: .releasing)
        dropped.store(0, ordering: .relaxed)
        expectedSampleTime = -1
    }

    /// Audio thread: notes a gap between this buffer and the previous one.
    func noteSampleTime(_ sampleTime: Double, frames: Int) {
        if expectedSampleTime >= 0, sampleTime > expectedSampleTime + 1 {
            dropped.add(Int(sampleTime - expectedSampleTime), ordering: .relaxed)
        }
        expectedSampleTime = sampleTime + Double(frames)
    }

    var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    /// Audio thread. `stride` is the channel count of an interleaved buffer; channel 0 is kept.
    func append(_ source: UnsafePointer<Float>, frames: Int, stride: Int) {
        let start = written.load(ordering: .relaxed)
        let n = min(frames, capacity - start)
        guard n > 0 else { return }
        if stride == 1 {
            (storage + start).update(from: source, count: n)
        } else {
            for i in 0..<n { storage[start + i] = source[i * stride] }
        }
        written.store(start + n, ordering: .releasing)
    }

    var count: Int { written.load(ordering: .acquiring) }

    func copy(from start: Int, to end: Int) -> [Float] {
        guard end > start else { return [] }
        return Array(UnsafeBufferPointer(start: storage + start, count: end - start))
    }
}

/// Captures mono microphone audio with an `AVAudioSinkNode`, which receives each
/// hardware IO cycle (about 10 ms) directly. An input tap would hand audio over in
/// 100 ms or larger blocks, and whatever sits in a half-filled block at stop is lost:
/// that is exactly where the last word of a sentence lives.
public final class AudioRecorder: @unchecked Sendable {
    public enum RecorderError: LocalizedError {
        case noInputDevice
        public var errorDescription: String? { "No microphone is available." }
    }

    /// Longest recording, in seconds. Memory is only used as audio arrives
    /// (about 11 MB a minute at 48 kHz).
    public static let maximumSeconds = 1800.0

    public private(set) var sampleRate: Double = 48_000
    public private(set) var isRunning = false

    /// Called on an arbitrary thread when the input device changes mid-session.
    public var onInterruption: (@Sendable () -> Void)?

    /// The microphone to record from, by CoreAudio UID. nil follows the system default.
    /// A device that has gone away also falls back to the system default.
    public var preferredDeviceUID: String? {
        didSet { if preferredDeviceUID != oldValue { needsRebuild = true } }
    }

    /// Name of the device the engine is actually built on.
    public private(set) var activeDeviceName: String?
    private var activeTransport: InputDevice.Transport?

    /// How long after `start()` the first audio should have arrived. With the engine
    /// prepared ahead, USB and built-in microphones deliver it in 23 to 69 ms; an
    /// engine built at that moment takes about 400 ms (measured with `keet-bench
    /// recover`). A Bluetooth headset first switches to its call profile, which takes
    /// longer still.
    public var firstAudioTimeout: Double { activeTransport == .bluetooth ? 2.0 : 0.8 }

    /// Test hook: the next engine built drops every buffer, like one built on a device
    /// that re-enumerated under it. Used by `keet-bench recover`.
    public static var dropAudioOnNextBuild = false

    /// macOS voice processing on the input: noise suppression, automatic gain, and echo
    /// cancellation (so sound from the Mac's own speakers is removed from the recording).
    public var voiceProcessing = false {
        didSet { if voiceProcessing != oldValue { needsRebuild = true } }
    }

    private var engine: AVAudioEngine?
    private var store: SampleStore?
    private var needsRebuild = true
    private var builtFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?

    // Test injection: feed a file in real time instead of the microphone.
    private let testSamples: [Float]?
    private var testTimer: DispatchSourceTimer?
    private let testQueue = DispatchQueue(label: "keet.recorder.test")

    public init(testAudioFile: URL? = nil) {
        if let url = testAudioFile, let loaded = try? Self.loadMono(url) {
            testSamples = loaded.samples
            sampleRate = loaded.rate
        } else {
            testSamples = nil
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// Forces the next `prepare()` to rebuild, e.g. after the system default input changed.
    public func invalidate() { needsRebuild = true }

    /// Builds the engine ahead of the first key press so starting is only `start()`.
    public func prepare() throws {
        guard testSamples == nil, needsRebuild else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let chosen = preferredDeviceUID.flatMap(AudioDevices.device(uid:))
        if let chosen, let unit = input.audioUnit {
            var id = chosen.id
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let active = chosen ?? AudioDevices.defaultInput()
        activeDeviceName = active?.name
        activeTransport = active?.transport
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Keep other apps' audio at full volume while dictating.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }

        let store = SampleStore(capacity: Int(format.sampleRate * Self.maximumSeconds))
        let deaf = Self.dropAudioOnNextBuild
        Self.dropAudioOnNextBuild = false
        let sink = AVAudioSinkNode { timestamp, frameCount, bufferList in
            if deaf { return noErr }
            if timestamp.pointee.mFlags.contains(.sampleTimeValid) {
                store.noteSampleTime(timestamp.pointee.mSampleTime, frames: Int(frameCount))
            }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard let first = buffers.first, let data = first.mData else { return noErr }
            store.append(
                data.assumingMemoryBound(to: Float.self),
                frames: Int(frameCount),
                stride: max(1, Int(first.mNumberChannels))
            )
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        engine.prepare()

        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            guard let self else { return }
            // Choosing a specific microphone makes the engine post this about 145 ms
            // after it starts, while it keeps running and capturing normally. Only a
            // change that actually stopped the engine (a mic unplugged mid-dictation)
            // needs handling.
            guard engine?.isRunning != true else { return }
            self.needsRebuild = true
            if self.isRunning { self.onInterruption?() }
        }

        self.engine = engine
        self.store = store
        self.sampleRate = format.sampleRate
        builtFormat = format
        needsRebuild = false
    }

    public func start() throws {
        guard !isRunning else { return }
        if let testSamples {
            startInjecting(testSamples)
            isRunning = true
            return
        }
        try prepare()
        // The device's format can change while idle (another app switched its sample
        // rate, or the device re-enumerated after sleep). An engine built for the old
        // format gets no audio. Compare the hardware side: once the sink is connected,
        // the input node's output format just reports the connection's format.
        if let engine, let builtFormat {
            let hardware = engine.inputNode.inputFormat(forBus: 0)
            if hardware.sampleRate != builtFormat.sampleRate || hardware.channelCount != builtFormat.channelCount {
                needsRebuild = true
                try prepare()
            }
        }
        store?.reset()
        do {
            try engine?.start()
        } catch {
            // A stale engine (device unplugged, sample rate changed) fails here; rebuild once.
            needsRebuild = true
            try prepare()
            store?.reset()
            try engine?.start()
        }
        isRunning = true
    }

    /// Throws away the running engine, builds a fresh one on the devices as they are
    /// now, and starts it. For a started engine that delivers no audio: after sleep,
    /// a USB dock can re-enumerate its devices while the engine is being built, and
    /// the engine ends up connected with a format the device no longer has.
    /// Anything captured so far is discarded.
    public func rebuildAndRestart() throws {
        engine?.stop()
        isRunning = false
        needsRebuild = true
        try start()
    }

    /// Stops capture and returns everything recorded, at `sampleRate`.
    @discardableResult
    public func stop() -> [Float] {
        guard isRunning else { return [] }
        if testSamples != nil {
            testTimer?.cancel()
            testTimer = nil
        } else {
            engine?.stop()
            // stop() releases the engine's resources; prepare again now so the next
            // key press only has to start it.
            engine?.prepare()
        }
        isRunning = false
        guard let store else { return [] }
        let samples = store.copy(from: 0, to: store.count)
        store.reset()
        return samples
    }

    public var capturedCount: Int { store?.count ?? 0 }

    /// Audio the hardware captured but that never reached Keet during the current or
    /// last recording, in milliseconds: dropouts, usually from an overloaded Mac.
    public var droppedMs: Int {
        guard let store, sampleRate > 0 else { return 0 }
        return Int(Double(store.droppedFrames) / sampleRate * 1000)
    }

    /// Within a second of the maximum length; the caller should finish up.
    public var isNearlyFull: Bool {
        guard let store else { return false }
        return store.count >= store.capacity - Int(sampleRate)
    }

    /// Whether the underlying engine is actually running (it can stop on its own
    /// when the hardware configuration changes).
    public var engineIsRunning: Bool { engine?.isRunning ?? false }

    public func samples(from start: Int, to end: Int) -> [Float] {
        store?.copy(from: start, to: end) ?? []
    }

    // MARK: - Test injection

    private func startInjecting(_ source: [Float]) {
        let store = SampleStore(capacity: Int(sampleRate * Self.maximumSeconds))
        self.store = store
        let chunk = Int(sampleRate / 100)
        var position = 0
        let timer = DispatchSource.makeTimerSource(queue: testQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler {
            var block = [Float](repeating: 0, count: chunk)
            for i in 0..<chunk {
                block[i] = position + i < source.count
                    ? source[position + i]
                    : Float.random(in: -2e-4...2e-4)  // room tone after the clip ends
            }
            position += chunk
            block.withUnsafeBufferPointer { store.append($0.baseAddress!, frames: chunk, stride: 1) }
        }
        testTimer = timer
        timer.resume()
    }

    public static func loadMono(_ url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
            channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return ([], format.sampleRate)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return ([], format.sampleRate) }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), format.sampleRate)
    }
}
