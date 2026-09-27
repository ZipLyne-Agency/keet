import AVFoundation
import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "agency.ziplyne.keet", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController!
    private var statusMenu: StatusMenu!
    private var mainWindow: MainWindowController!
    private var tapRetry: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = ProcessInfo.processInfo.environment["KEET_SNAPSHOT"] {
            let demo = AppController(history: HistoryStore(sample: Snapshot.sampleHistory()))
            Snapshot.render(to: URL(fileURLWithPath: dir), controller: demo)
            return
        }
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
