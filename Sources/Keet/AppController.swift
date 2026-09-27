import AVFoundation
import AppKit
import KeetCore
import os

private let log = Logger(subsystem: "agency.ziplyne.keet", category: "dictation")

/// Owns dictation from key press to inserted text, plus the state the window shows.
///
/// Threading: the recorder and everything that reads audio live on `audioQueue`;
/// UI, hotkey and insertion live on the main thread.
@MainActor
final class AppController: ObservableObject {
    enum ModelState: Equatable {
        case loading
        case ready(loadMs: Int)
        case failed(String)

        var isReady: Bool { if case .ready = self { return true } else { return false } }
    }

    enum Phase: Equatable { case idle, listening, transcribing }

    @Published private(set) var modelState: ModelState = .loading
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hotkeyChoice: HotkeyChoice
    @Published private(set) var inputDevices: [InputDevice] = []
    @Published private(set) var systemDefaultMic: InputDevice?
    /// nil follows the system default input.
    @Published private(set) var selectedMicUID: String?
    @Published private(set) var isTestingMic = false
    @Published private(set) var micTestLevel: Float = 0
    /// The app you were in before switching to Keet; history's "Paste into" targets it.
    @Published private(set) var lastExternalApp: NSRunningApplication?
    /// Play a chime when a hold becomes a dictation.
    @Published var startSoundOn: Bool = UserDefaults.standard.object(forKey: "startSound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(startSoundOn, forKey: "startSound") }
    }
    @Published private(set) var micTestPeakDb: Float = -120
    /// Show words in the pill while you talk.
    @Published var livePreview: Bool = UserDefaults.standard.object(forKey: "livePreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(livePreview, forKey: "livePreview") }
    }

    let history: HistoryStore
    let overlay = OverlayController()
    private let startSound = StartSound()
    let hotkey: HotkeyMonitor
    private let inserter = TextInserter()
    private let transcriber = Transcriber()
    private let recorder: AudioRecorder
    private let audioQueue = DispatchQueue(label: "keet.audio", qos: .userInteractive)
    private let tail = TailPolicy()
    private var deviceWatcher: AudioDeviceWatcher?
    private var activationObserver: NSObjectProtocol?
    private var micTestTimer: DispatchSourceTimer?
    private var liveTask: Task<Void, Never>?

    /// Holds shorter than this are treated as a stray tap of the key.
    private let minimumHold: TimeInterval = 0.16
    /// Show the pill only once the hold counts, so shortcuts and stray taps never flash it.
    private let pillDelay: TimeInterval = 0.16

    private var session: Session?
    private var sessionCounter = 0

    /// Audio-side state for the recording in progress. Touched only on `audioQueue`.
    private final class Session: @unchecked Sendable {
        let id: Int
        let pressed = CFAbsoluteTimeGetCurrent()
        var released: CFAbsoluteTime?
        var tracker: EnergyTracker
        var readIndex = 0
        var firstAudio: CFAbsoluteTime?
        var pump: DispatchSourceTimer?
        var finished = false
        var lastMeterPush: CFAbsoluteTime = 0
        /// Escape on a long dictation: transcribe and keep it, but don't paste.
        var keepOnly = false

        init(id: Int, sampleRate: Double) {
            self.id = id
            tracker = EnergyTracker(sampleRate: sampleRate)
        }
    }

    private static var testing: Bool { ProcessInfo.processInfo.environment["KEET_TEST_AUDIO"] != nil }

    init(history: HistoryStore? = nil) {
        self.history = history ?? HistoryStore()
        let testFile = ProcessInfo.processInfo.environment["KEET_TEST_AUDIO"].map { URL(fileURLWithPath: $0) }
        recorder = AudioRecorder(testAudioFile: testFile)
        let saved = HotkeyChoice(rawValue: UserDefaults.standard.integer(forKey: "hotkey")) ?? .leftOption
        hotkeyChoice = saved
        hotkey = HotkeyMonitor(choice: saved)
        selectedMicUID = UserDefaults.standard.string(forKey: "micUID")
        recorder.preferredDeviceUID = selectedMicUID

        hotkey.onPress = { [weak self] in self?.keyPressed() }
        hotkey.onRelease = { [weak self] in self?.keyReleased() }
        hotkey.onCancel = { [weak self] reason in self?.cancel(reason) }
        hotkey.onEscape = { [weak self] in
            guard let self, self.overlay.isShowingResult else { return }
            self.overlay.hide()
        }
        hotkey.onActivity = { [weak self] in self?.userMovedOn() }
        overlay.onCopy = { TextInserter.copyToClipboard($0) }
        recorder.onInterruption = { [weak self] in
            DispatchQueue.main.async { self?.keyReleased() }
        }

        refreshDevices()
        deviceWatcher = AudioDeviceWatcher { [weak self] in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
    }

    func start() {
        audioQueue.async { [recorder] in try? recorder.prepare() }
        // UI tests can run without touching the model.
        guard ProcessInfo.processInfo.environment["KEET_SKIP_MODEL"] == nil else { return }
        Task { await loadModel() }
    }

    func loadModel() async {
        modelState = .loading
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            try await transcriber.load()
            try await transcriber.warmUp()
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            log.notice("model ready in \(ms) ms")
            modelState = .ready(loadMs: ms)
        } catch {
            log.error("model load failed: \(error.localizedDescription, privacy: .public)")
            modelState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Settings

    func setHotkey(_ choice: HotkeyChoice) {
        cancel(.shortcut)
        hotkey.choice = choice
        hotkeyChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "hotkey")
    }

    /// nil follows the system default input.
    func selectMicrophone(uid: String?) {
        if isTestingMic { stopMicTest() }
        selectedMicUID = uid
        UserDefaults.standard.set(uid, forKey: "micUID")
        audioQueue.async { [recorder] in
            recorder.preferredDeviceUID = uid
            if !recorder.isRunning { try? recorder.prepare() }
        }
    }

    /// The device dictation will use: the chosen one if it's connected, else the default.
    var activeMic: InputDevice? {
        if let uid = selectedMicUID, let device = inputDevices.first(where: { $0.uid == uid }) { return device }
        return systemDefaultMic
    }

    func inputVolume() -> Float? { activeMic.flatMap { AudioDevices.inputVolume($0.id) } }

    func setInputVolume(_ volume: Float) {
        if let device = activeMic { AudioDevices.setInputVolume(device.id, volume) }
    }

    /// Median peak level of recent dictations, in dBFS.
    var recentPeakDb: Float? {
        let peaks = history.entries.prefix(20).compactMap(\.peakDb).sorted()
        return peaks.count >= 3 ? peaks[peaks.count / 2] : nil
    }

    var activeMicName: String {
        if let uid = selectedMicUID, let device = inputDevices.first(where: { $0.uid == uid }) { return device.name }
        return systemDefaultMic?.name ?? "No microphone"
    }

    private func refreshDevices() {
        inputDevices = AudioDevices.inputs()
        systemDefaultMic = AudioDevices.defaultInput()
    }

    private func devicesChanged() {
        refreshDevices()
        // The engine is bound to whichever device it was built on; rebuild so the
        // next dictation uses the current default or the chosen mic coming back.
        audioQueue.async { [recorder] in
            recorder.invalidate()
            if !recorder.isRunning { try? recorder.prepare() }
        }
    }

    // MARK: - Microphone test

    func toggleMicTest() {
        isTestingMic ? stopMicTest() : startMicTest()
    }

    private func startMicTest() {
        guard session == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSSound.beep()
            return
        }
        isTestingMic = true
        audioQueue.async { [weak self, recorder] in
            guard let self else { return }
            do { try recorder.start() } catch {
                DispatchQueue.main.async { self.isTestingMic = false }
                return
            }
            var tracker = EnergyTracker(sampleRate: recorder.sampleRate)
            var read = 0
            let started = CFAbsoluteTimeGetCurrent()
            let timer = DispatchSource.makeTimerSource(queue: self.audioQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(25))
            timer.setEventHandler { [weak self] in
                let count = recorder.capturedCount
                if count > read {
                    tracker.consume(recorder.samples(from: read, to: count))
                    read = count
                }
                let level = tracker.meterLevel
                let recentPeak = tracker.framesDb.suffix(30).max() ?? -120
                let done = CFAbsoluteTimeGetCurrent() - started > 10
                DispatchQueue.main.async {
                    self?.micTestLevel = level
                    self?.micTestPeakDb = recentPeak
                    if done { self?.stopMicTest() }
                }
            }
            self.micTestTimer = timer
            timer.resume()
        }
    }

    func stopMicTest() {
        guard isTestingMic else { return }
        isTestingMic = false
        micTestLevel = 0
        micTestPeakDb = -120
        audioQueue.async { [weak self, recorder] in
            self?.micTestTimer?.cancel()
            self?.micTestTimer = nil
            recorder.stop()
        }
    }

    // MARK: - History actions

    /// Brings back the app you were in and pastes the text there.
    func pasteIntoLastApp(_ text: String) {
        guard let app = lastExternalApp, !app.isTerminated else {
            TextInserter.copyToClipboard(text)
            return
        }
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [inserter] in inserter.paste(text) }
    }

    // MARK: - Dictation lifecycle

    private func keyPressed() {
        guard Self.testing || (modelState.isReady && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        else {
            log.notice("key down ignored: model \(String(describing: self.modelState), privacy: .public)")
            NSSound.beep()
            return
        }
        if isTestingMic { stopMicTest() }
        if overlay.isShowingResult { overlay.hide() }
        inserter.prime()

        // A new press during the previous dictation's tail finishes that one now.
        if let previous = session {
            audioQueue.async { [weak self] in self?.finish(previous) }
        }
        sessionCounter += 1
        let current = Session(id: sessionCounter, sampleRate: recorder.sampleRate)
        session = current
        phase = .listening
        log.notice("session \(current.id): key down")

        audioQueue.async { [weak self, recorder] in
            guard let self else { return }
            do {
                try recorder.start()
            } catch {
                log.error("microphone start failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { self.cancel(.shortcut) }
                return
            }
            // The device rate is known only once the engine is built.
            current.tracker = EnergyTracker(sampleRate: recorder.sampleRate)
            let pump = DispatchSource.makeTimerSource(queue: self.audioQueue)
            pump.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            pump.setEventHandler { [weak self] in self?.pumpTick(current) }
            current.pump = pump
            pump.resume()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pillDelay) { [weak self] in
            guard let self, self.session === current else { return }
            self.overlay.showListening()
            if self.startSoundOn { self.startSound.play() }
        }
        if livePreview { startLivePreview(current) }
    }

    /// While the key is held, re-transcribes the last 14 seconds a few times a second
    /// and shows the newest words in the pill. The text you get when you let go still
    /// comes from one full pass over the whole recording.
    private func startLivePreview(_ current: Session) {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            while !Task.isCancelled, let self, self.session === current, self.phase == .listening {
                let rate = self.recorder.sampleRate
                let count = self.recorder.capturedCount
                let start = max(0, count - Int(rate * 14))
                if count - start > Int(rate * 0.4),
                   let pcm = try? self.transcriber.resample(self.recorder.samples(from: start, to: count), from: rate),
                   let text = try? await self.transcriber.transcribe(pcm),
                   !Task.isCancelled, self.session === current, self.phase == .listening, !text.isEmpty {
                    self.overlay.setLiveText(text)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func keyReleased() {
        guard let current = session else { return }
        let held = CFAbsoluteTimeGetCurrent() - current.pressed
        log.notice("session \(current.id): key up after \(Int(held * 1000)) ms")
        liveTask?.cancel()
        if held < minimumHold {
            cancel(.shortcut)
            return
        }
        audioQueue.async {
            if current.released == nil { current.released = CFAbsoluteTimeGetCurrent() }
        }
    }

    /// Typing or clicking after release means the speaker is done; don't keep
    /// listening for more words.
    private func userMovedOn() {
        guard let current = session else { return }
        audioQueue.async { [weak self] in
            guard let self, current.released != nil, !current.finished else { return }
            log.notice("session \(current.id): tail cut short by typing or a click")
            self.finish(current)
        }
    }

    private func cancel(_ reason: HotkeyMonitor.CancelReason = .shortcut) {
        guard let current = session else { return }
        liveTask?.cancel()
        if reason == .escape, CFAbsoluteTimeGetCurrent() - current.pressed >= 2 {
            // Never throw away real speech: transcribe it, keep it in History, show it
            // on the card, but don't paste.
            log.notice("session \(current.id): escape, keeping the speech")
            audioQueue.async { [weak self] in
                current.keepOnly = true
                self?.finish(current)
            }
            return
        }
        log.notice("session \(current.id): cancelled")
        session = nil
        phase = .idle
        overlay.hide()
        audioQueue.async { [recorder] in
            guard !current.finished else { return }
            current.finished = true
            current.pump?.cancel()
            recorder.stop()
        }
    }

    /// Every 10 ms while recording: meter the new audio, and after release decide
    /// whether the speaker has finished their last word.
    private nonisolated func pumpTick(_ current: Session) {
        guard !current.finished else { return }
        let count = recorder.capturedCount
        if count > current.readIndex {
            let fresh = recorder.samples(from: current.readIndex, to: count)
            current.readIndex = count
            current.tracker.consume(fresh)
            if current.firstAudio == nil { current.firstAudio = CFAbsoluteTimeGetCurrent() }
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - current.lastMeterPush >= 1.0 / 40 {
            current.lastMeterPush = now
            let level = current.tracker.meterLevel
            DispatchQueue.main.async { [weak self] in self?.overlay.push(level: level) }
        }

        if recorder.isNearlyFull {
            log.notice("session \(current.id): reached the recording limit, transcribing what was said")
            finish(current)
            return
        }

        guard let released = current.released else { return }
        let elapsedMs = Int((now - released) * 1000)
        guard tail.shouldStop(elapsedMs: elapsedMs, trailingQuietMs: current.tracker.trailingQuietMs) else { return }
        finish(current)
    }

    /// Stops capture and hands the audio to the model. Runs on `audioQueue`.
    private nonisolated func finish(_ current: Session) {
        guard !current.finished else { return }
        current.finished = true
        current.pump?.cancel()
        if current.released == nil { current.released = CFAbsoluteTimeGetCurrent() }
        let released = current.released!
        let tailMs = Int((CFAbsoluteTimeGetCurrent() - released) * 1000)
        let rate = recorder.sampleRate
        let samples = recorder.stop()
        let startLatency = current.firstAudio.map { Int(($0 - current.pressed) * 1000) } ?? -1
        let t = current.tracker
        log.notice("session \(current.id): first audio after \(startLatency) ms, tail \(tailMs) ms, \(samples.count) samples, noise \(Int(t.noiseFloorDb)) dB, threshold \(Int(t.speechThresholdDb)) dB, peak \(Int(t.peakDb)) dB")
        let peak = t.peakDb
        DispatchQueue.main.async { [weak self] in
            self?.transcribe(samples, rate: rate, released: released, peakDb: peak, session: current)
        }
    }

    private func transcribe(
        _ samples: [Float], rate: Double, released: CFAbsoluteTime, peakDb: Float, session current: Session
    ) {
        let isLatest = session === current || session == nil
        if session === current { session = nil }
        if isLatest {
            phase = .transcribing
            overlay.showTranscribing()
        }
        Task { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            var text = ""
            do {
                let pcm = try self.transcriber.resample(samples, from: rate)
                if let fake = ProcessInfo.processInfo.environment["KEET_FAKE_TEXT"] {
                    text = fake  // insertion tests without the model
                } else {
                    text = try await self.transcriber.transcribe(pcm)
                }
            } catch {
                log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            }
            let transcribeMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            let latencyMs = Int((CFAbsoluteTimeGetCurrent() - released) * 1000)
            let keepOnly = await self.keepOnly(current)
            self.deliver(text, ownsOverlay: isLatest, audioSeconds: Double(samples.count) / max(rate, 1),
                         latencyMs: latencyMs, peakDb: peakDb, keepOnly: keepOnly)
            log.notice("session \(current.id): transcribe \(transcribeMs) ms, release to text \(latencyMs) ms")
        }
    }

    private nonisolated func keepOnly(_ current: Session) async -> Bool {
        await withCheckedContinuation { continuation in
            audioQueue.async { continuation.resume(returning: current.keepOnly) }
        }
    }

    private func deliver(
        _ text: String, ownsOverlay: Bool, audioSeconds: Double, latencyMs: Int, peakDb: Float, keepOnly: Bool
    ) {
        // A newer dictation may already be showing its pill; leave that alone.
        let ownsOverlay = ownsOverlay && session == nil
        if ownsOverlay { phase = .idle }
        guard !text.isEmpty else {
            if ownsOverlay { overlay.hide() }
            return
        }
        if keepOnly {
            if ownsOverlay { overlay.showResult(text, note: "Cancelled, not pasted. Saved in History.") }
            let app = NSWorkspace.shared.frontmostApplication
            history.add(Dictation(
                date: Date(), text: text, appName: app?.localizedName, bundleID: app?.bundleIdentifier,
                audioSeconds: audioSeconds, latencyMs: latencyMs, delivery: .cancelled, peakDb: peakDb))
            return
        }
        let target = inserter.currentTarget()
        log.notice("insert target: \(String(describing: target), privacy: .public)")
        let app = NSWorkspace.shared.frontmostApplication
        var delivery = Dictation.Delivery.pasted
        switch target {
        case .editable(let needsLeadingSpace):
            if ownsOverlay { overlay.hide() }
            inserter.paste(needsLeadingSpace ? " " + text : text)
        case .unknown:
            if ownsOverlay { overlay.hide() }
            inserter.paste(text)
        case .notEditable:
            delivery = .card
            if ownsOverlay { overlay.showResult(text) }
        }
        history.add(Dictation(
            date: Date(), text: text, appName: app?.localizedName, bundleID: app?.bundleIdentifier,
            audioSeconds: audioSeconds, latencyMs: latencyMs, delivery: delivery, peakDb: peakDb))
    }
}
