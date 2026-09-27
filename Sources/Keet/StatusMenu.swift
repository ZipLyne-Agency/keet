import AVFoundation
import AppKit
import ApplicationServices
import ServiceManagement

/// Menu bar item: status, recent transcripts, shortcut choice, permissions.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: AppController
    private let menu = NSMenu()
    var openWindow: () -> Void = {}

    init(controller: AppController) {
        self.controller = controller
        super.init()
        item.button?.image = Self.icon
        item.button?.toolTip = "Keet"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    private static var icon: NSImage {
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Keet")!
        image.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()

        menu.addItem(action("Open Keet", #selector(open), key: "o"))
        menu.addItem(.separator())

        let status: String
        switch controller.modelState {
        case .loading: status = "Loading speech model…"
        case .ready: status = "Hold \(controller.hotkeyChoice.title) to dictate"
        case .failed: status = "Speech model failed to load"
        }
        menu.addItem(disabled(status))
        if case .failed(let reason) = controller.modelState {
            menu.addItem(disabled(reason))
            menu.addItem(action("Try Again", #selector(retryModel)))
        }

        let needsAccessibility = !AXIsProcessTrusted()
        let needsInputMonitoring = !needsAccessibility && !controller.hotkey.isRunning
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if needsAccessibility || needsInputMonitoring || micStatus != .authorized {
            menu.addItem(.separator())
            if needsAccessibility {
                menu.addItem(action("Allow Accessibility Access…", #selector(openAccessibility)))
            }
            if needsInputMonitoring {
                menu.addItem(action("Allow Input Monitoring…", #selector(openInputMonitoring)))
            }
            if micStatus != .authorized {
                menu.addItem(action("Allow Microphone Access…", #selector(openMicrophone)))
            }
        }

        menu.addItem(.separator())
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let entries = controller.history.entries
        if entries.isEmpty {
            recentMenu.addItem(disabled("Nothing yet"))
        } else {
            recentMenu.addItem(disabled("Click to copy"))
            for (index, entry) in entries.prefix(12).enumerated() {
                let row = action(Self.truncate(entry.text), #selector(copyRecent(_:)))
                row.tag = index
                row.toolTip = entry.text
                recentMenu.addItem(row)
            }
        }
        recent.submenu = recentMenu
        menu.addItem(recent)
        let copyLast = action("Copy Last Transcript", #selector(copyLast))
        copyLast.isEnabled = !entries.isEmpty
        menu.addItem(copyLast)

        menu.addItem(.separator())
        let shortcut = NSMenuItem(title: "Dictation Key", action: nil, keyEquivalent: "")
        let shortcutMenu = NSMenu()
        for choice in HotkeyChoice.allCases {
            let entry = action(choice.title, #selector(pickHotkey(_:)))
            entry.tag = choice.rawValue
            entry.state = choice == controller.hotkeyChoice ? .on : .off
            shortcutMenu.addItem(entry)
        }
        shortcut.submenu = shortcutMenu
        menu.addItem(shortcut)

        let mic = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let automatic = action("Automatic", #selector(pickMic(_:)))
        automatic.representedObject = nil
        automatic.state = controller.selectedMicUID == nil ? .on : .off
        micMenu.addItem(automatic)
        micMenu.addItem(.separator())
        for device in controller.inputDevices {
            let row = action(device.name, #selector(pickMic(_:)))
            row.representedObject = device.uid
            row.state = controller.selectedMicUID == device.uid ? .on : .off
            micMenu.addItem(row)
        }
        mic.submenu = micMenu
        menu.addItem(mic)

        let login = action("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("Quit Keet", #selector(quit), key: "q"))
    }

    private static func truncate(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? String(flat.prefix(57)) + "…" : flat
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = self
        return entry
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        let entries = controller.history.entries
        guard entries.indices.contains(sender.tag) else { return }
        TextInserter.copyToClipboard(entries[sender.tag].text)
    }

    @objc private func copyLast() {
        if let entry = controller.history.entries.first { TextInserter.copyToClipboard(entry.text) }
    }

    @objc private func open() { openWindow() }

    @objc private func pickMic(_ sender: NSMenuItem) {
        controller.selectMicrophone(uid: sender.representedObject as? String)
    }

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        if let choice = HotkeyChoice(rawValue: sender.tag) { controller.setHotkey(choice) }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func retryModel() {
        Task { await controller.loadModel() }
    }

    @objc private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    @objc private func openInputMonitoring() {
        if !CGRequestListenEventAccess() {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }

    @objc private func openMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
