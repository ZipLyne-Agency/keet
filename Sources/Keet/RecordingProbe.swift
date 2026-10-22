import AppKit
import AVFoundation
import KeetCore

/// A bounded, headless hardware check. Writes timings and counts, never audio.
enum RecordingProbe {
    private struct Cycle: Codable {
        let prepareMs: Int
        let startMs: Int
        let firstAudioMs: Int
        let samples: Int
        let droppedMs: Int
        let engineBuilds: Int
        let idleSamples: Int
        let engineStopped: Bool
    }

    private struct Report: Codable {
        var cycles: [Cycle] = []
        var silentEngineDetected = false
        var recoveryMs: Int?
        var recoverySamples = 0
        var errors: [String] = []
    }

    static func run(output: URL) {
        let uid = UserDefaults.standard.string(forKey: "micUID")
        DispatchQueue.global(qos: .userInitiated).async {
            var report = Report()
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                report.errors.append("Microphone permission is not granted.")
            } else {
                let recorder = AudioRecorder()
                recorder.preferredDeviceUID = uid
                defer { recorder.stop() }
                do {
                    for _ in 0..<6 {
                        let prepare = CFAbsoluteTimeGetCurrent()
                        try recorder.prepare()
                        let preparedMs = milliseconds(since: prepare)
                        let start = CFAbsoluteTimeGetCurrent()
                        try recorder.start()
                        let startMs = milliseconds(since: start)
                        while recorder.capturedCount == 0, milliseconds(since: start) < 2500 { usleep(1000) }
                        let first = recorder.capturedCount > 0 ? milliseconds(since: start) : -1
                        usleep(150_000)
                        let count = recorder.capturedCount
                        let dropped = recorder.droppedMs
                        recorder.stop()
                        usleep(100_000)
                        let idleSamples = recorder.capturedCount
                        report.cycles.append(Cycle(prepareMs: preparedMs, startMs: startMs,
                                                   firstAudioMs: first, samples: count, droppedMs: dropped,
                                                   engineBuilds: recorder.engineBuildCount, idleSamples: idleSamples,
                                                   engineStopped: !recorder.engineIsRunning))
                        if first < 0 { report.errors.append("A microphone start delivered no audio.") }
                        if idleSamples > 0 || recorder.engineIsRunning {
                            report.errors.append("Audio capture continued after stop.")
                        }
                    }

                    // Exercise the same one-rebuild recovery used after sleep.
                    AudioRecorder.dropAudioOnNextBuild = true
                    recorder.invalidate()
                    try recorder.start()
                    let silent = CFAbsoluteTimeGetCurrent()
                    while milliseconds(since: silent) < Int(recorder.firstAudioTimeout * 1000) { usleep(5000) }
                    report.silentEngineDetected = recorder.capturedCount == 0
                    if !report.silentEngineDetected { report.errors.append("The injected silent engine was not exercised.") }
                    let recover = CFAbsoluteTimeGetCurrent()
                    try recorder.rebuildAndRestart()
                    while recorder.capturedCount == 0, milliseconds(since: recover) < 2500 { usleep(1000) }
                    report.recoveryMs = milliseconds(since: recover)
                    report.recoverySamples = recorder.capturedCount
                    if recorder.capturedCount == 0 { report.errors.append("Rebuilding did not restore audio.") }
                } catch {
                    report.errors.append(error.localizedDescription)
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) { try? data.write(to: output, options: .atomic) }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func milliseconds(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}
