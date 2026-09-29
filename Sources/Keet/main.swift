import AVFoundation
import AppKit
import ApplicationServices
import KeetCore
import os

private let log = Logger(subsystem: "agency.ziplyne.keet", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController!
    private var statusMenu: StatusMenu!
    private var mainWindow: MainWindowController!
    private var tapRetry: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let out = ProcessInfo.processInfo.environment["KEET_MIC_PROBE"] {
            MicProbe.run(output: URL(fileURLWithPath: out))
            return
        }
        if let bundles = ProcessInfo.processInfo.environment["KEET_FOCUS_PROBE"] {
            FocusProbe.run(bundleIDs: bundles.split(separator: ",").map(String.init))
            return
        }
        if let out = ProcessInfo.processInfo.environment["KEET_CLEANUP_PROBE"] {
            CleanupProbe.run(output: URL(fileURLWithPath: out))
            return
        }
        if let dir = ProcessInfo.processInfo.environment["KEET_SNAPSHOT"] {
            let demo = AppController(
                history: HistoryStore(sample: Snapshot.sampleHistory()),
                dictionary: DictionaryStore(sample: [
                    DictionaryWord(text: "ZipLyne", heardAs: ["zip line", "zipline"]),
                    DictionaryWord(text: "Parakeet"),
                    DictionaryWord(text: "Kubernetes", heardAs: ["cooper netties"]),
                ]))
            Snapshot.render(to: URL(fileURLWithPath: dir), controller: demo)
            return
        }
        SpeakerMute.restoreAfterCrash()
        controller = AppController()
        statusMenu = StatusMenu(controller: controller)
        mainWindow = MainWindowController(controller: controller)
        statusMenu.openWindow = { [weak self] in self?.mainWindow.show() }
        NSApp.mainMenu = Self.makeMainMenu()
        controller.start()

        // Overlay placement checks: show the card without any permissions involved.
        if let demo = ProcessInfo.processInfo.environment["KEET_DEMO_CARD"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.controller.overlay.showResult(demo) }
            return
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        startHotkey()

        // First launch, or something still needs setting up: open the window.
        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        if firstLaunch || !AXIsProcessTrusted() {
            mainWindow.show()
        }
    }

    /// Opening Keet again (Finder, Spotlight, Dock) brings up the window.
    func applicationWillTerminate(_ notification: Notification) {
        controller?.restoreSpeakers()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return true
    }

    @objc func openSettings() { mainWindow.show() }

    /// Needed for Command-C, Command-V and the rest to work in the window's text fields.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Keet", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Keet", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Keet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }

    /// The keyboard tap needs Accessibility. Until it's granted, keep trying quietly
    /// so dictation starts working the moment the switch is flipped, with no relaunch.
    private func startHotkey() {
        if controller.hotkey.start() {
            log.notice("keyboard hook running")
            return
        }
        log.notice("keyboard hook waiting for permission (accessibility: \(AXIsProcessTrusted()))")
        var askedForInputMonitoring = false
        var attempts = 0
        tapRetry = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                attempts += 1
                if self.controller.hotkey.start() {
                    log.notice("keyboard hook running after \(attempts) retries")
                    timer.invalidate()
                    return
                }
                // Accessibility normally covers a listen-only keyboard hook. If it's
                // granted and the hook still won't start, ask for Input Monitoring too.
                if AXIsProcessTrusted(), attempts >= 2, !askedForInputMonitoring {
                    askedForInputMonitoring = true
                    log.notice("accessibility granted but hook refused; requesting input monitoring")
                    CGRequestListenEventAccess()
                }
                if attempts % 40 == 0 {
                    log.notice("keyboard hook still waiting (accessibility: \(AXIsProcessTrusted()))")
                }
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

/// Diagnostic: records a few seconds from each input device and writes a timeline of
/// what the engine did (configuration changes, whether it kept running, samples
/// arriving). Run inside the app bundle so it has Keet's microphone permission:
/// `open -n --env KEET_MIC_PROBE=/tmp/probe.txt /Applications/Keet.app`
@MainActor
enum MicProbe {
    static func run(output: URL) {
        final class Lines: @unchecked Sendable {
            private var items: [String] = []
            private let lock = NSLock()
            func append(_ line: String) { lock.lock(); items.append(line); lock.unlock() }
            var text: String { lock.lock(); defer { lock.unlock() }; return items.joined(separator: "\n") }
        }
        let lines = Lines()
        // KEET_PROBE_UID limits the run to one device, recorded with voice processing off then on.
        let only = ProcessInfo.processInfo.environment["KEET_PROBE_UID"]
        let base: [(String, String?)] = [("Automatic", nil)] + AudioDevices.inputs().map { ($0.name, $0.uid) }
        let devices: [(String, String?, Bool)] = only.map { uid in
            let name = AudioDevices.device(uid: uid)?.name ?? uid
            return [(name, uid, false), (name, uid, true)]
        } ?? base.map { ($0.0, $0.1, false) }
        DispatchQueue.global().async {
            for (name, uid, processing) in devices {
                let recorder = AudioRecorder()
                recorder.preferredDeviceUID = uid
                recorder.voiceProcessing = processing
                let t0 = CFAbsoluteTimeGetCurrent()
                func ms() -> Int { Int((CFAbsoluteTimeGetCurrent() - t0) * 1000) }
                let observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
                ) { _ in lines.append("  \(ms()) ms: configuration change, engine running \(recorder.engineIsRunning)") }
                recorder.onInterruption = { lines.append("  \(ms()) ms: interruption callback") }
                do {
                    try recorder.prepare()
                    lines.append("\(name)\(processing ? " with voice processing" : ""): built on \(recorder.activeDeviceName ?? "?") at \(Int(recorder.sampleRate)) Hz")
                    try recorder.start()
                } catch {
                    lines.append("\(name): failed: \(error.localizedDescription)")
                    NotificationCenter.default.removeObserver(observer)
                    continue
                }
                for step in 1...15 {
                    usleep(200_000)
                    lines.append("  \(step * 200) ms: running \(recorder.engineIsRunning), samples \(recorder.capturedCount)")
                }
                let samples = recorder.stop()
                var tracker = EnergyTracker(sampleRate: recorder.sampleRate)
                tracker.consume(Array(samples.dropFirst(Int(recorder.sampleRate))))  // skip the first second
                lines.append("  stopped with \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / recorder.sampleRate)) s), room noise \(Int(tracker.noiseFloorDb)) dB, loudest \(Int(tracker.peakDb)) dB")
                NotificationCenter.default.removeObserver(observer)
            }
            try? lines.text.write(to: output, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Runs the AI cleanup inside the app, as a menu bar app with no window, over your
/// recent dictations: Apple rate-limits the on-device model for background apps, and
/// a command-line test can't show that. Writes timings and outcomes, never the text.
enum CleanupProbe {
    static func run(output: URL) {
        Task.detached {
            let cleanup = Cleanup()
            var lines = ["availability: \(cleanup.availability)"]
            let history = await MainActor.run { HistoryStore().entries.map(\.text) }
                .filter { $0.split(separator: " ").count >= 4 }
            for text in history.prefix(30) {
                cleanup.prepare()
                try? await Task.sleep(for: .milliseconds(300))
                let result = await cleanup.clean(text)
                lines.append("\(result.ms) ms  \(result.note)")
            }
            try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}

/// Runs the text-field check over every element of the given apps (read only: nothing
/// is focused or typed) and prints, per role, how many would get the paste and how
/// many the Copy card. Prints roles and counts, never text.
enum FocusProbe {
    static func run(bundleIDs: [String]) {
        let inserter = TextInserter()
        for bundleID in bundleIDs {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
                print("\(bundleID): not running")
                continue
            }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 1)
            var counts: [String: (paste: Int, card: Int)] = [:]
            var visited = 0
            func walk(_ element: AXUIElement, _ depth: Int) {
                visited += 1
                guard visited <= 8000, depth <= 60 else { return }
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                let key = (role as? String) ?? "-"
                var entry = counts[key] ?? (0, 0)
                if case .editable = inserter.classify(element, bundleID: bundleID) { entry.paste += 1 } else { entry.card += 1 }
                counts[key] = entry
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                   let children = children as? [AXUIElement] {
                    for child in children { walk(child, depth + 1) }
                }
            }
            walk(root, 0)
            print("\(bundleID): \(visited) elements")
            for (role, entry) in counts.sorted(by: { $0.value.paste + $0.value.card > $1.value.paste + $1.value.card }) {
                print("  \(role): paste \(entry.paste), card \(entry.card)")
            }
        }
        exit(0)
    }
}
