import AppKit
import Carbon.HIToolbox
import os

private let log = Logger(subsystem: "agency.ziplyne.keet", category: "hotkey")

/// The key held to dictate. Raw values are macOS virtual key codes.
enum HotkeyChoice: Int, CaseIterable {
    case leftOption = 58
    case rightOption = 61
    case rightCommand = 54
    case fn = 63

    var title: String {
        switch self {
        case .leftOption: "Left Option"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .fn: "Fn (Globe)"
        }
    }

    var symbol: String {
        switch self {
        case .leftOption, .rightOption: "⌥"
        case .rightCommand: "⌘"
        case .fn: "fn"
        }
    }

    // Device-dependent modifier bits (NX_DEVICE*KEYMASK) tell left from right.
    private static let leftAlt: UInt64 = 0x20
    private static let rightAlt: UInt64 = 0x40
    private static let leftCmd: UInt64 = 0x08
    private static let rightCmd: UInt64 = 0x10

    func isDown(_ flags: CGEventFlags) -> Bool {
        switch self {
        case .leftOption: flags.rawValue & Self.leftAlt != 0
        case .rightOption: flags.rawValue & Self.rightAlt != 0
        case .rightCommand: flags.rawValue & Self.rightCmd != 0
        case .fn: flags.contains(.maskSecondaryFn)
        }
    }

    /// True when any modifier other than this key is held (Caps Lock ignored).
    func othersHeld(_ flags: CGEventFlags) -> Bool {
        var others: CGEventFlags = [.maskShift, .maskControl]
        let raw = flags.rawValue
        switch self {
        case .leftOption:
            if raw & Self.rightAlt != 0 { return true }
            others.formUnion([.maskCommand, .maskSecondaryFn])
        case .rightOption:
            if raw & Self.leftAlt != 0 { return true }
            others.formUnion([.maskCommand, .maskSecondaryFn])
        case .rightCommand:
            if raw & Self.leftCmd != 0 { return true }
            others.formUnion([.maskAlternate, .maskSecondaryFn])
        case .fn:
            others.formUnion([.maskAlternate, .maskCommand])
        }
        return !flags.intersection(others).isEmpty
    }
}

/// The function key held to dictate in Hebrew. Raw values are macOS virtual key codes.
enum FunctionKey: Int, CaseIterable {
    case f1 = 122, f2 = 120, f3 = 99, f4 = 118, f5 = 96, f6 = 97, f7 = 98, f8 = 100, f9 = 101, f10 = 109
    case f11 = 103, f12 = 111, f13 = 105, f14 = 107, f15 = 113, f16 = 106, f17 = 64, f18 = 79, f19 = 80

    var title: String { "F\(Self.allCases.firstIndex(of: self)! + 1)" }
}

/// Polls the real key state while a dictation key is held. The key events can miss the
/// release (the tap was briefly off, secure input took the keyboard, the main thread
/// stalled), and then the pill would listen until the 30-minute limit with nothing that
/// stops it. This catches that within a quarter second of letting go.
final class ReleaseWatch {
    private var timer: Timer?

    func start(isDown: @escaping () -> Bool, onMissedRelease: @escaping () -> Void) {
        stop()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard !isDown() else { return }
            self?.stop()
            onMissedRelease()
        }
        // Common modes, so it still fires while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Holds a bare function key as a second dictation key, through a registered hot key.
/// Unlike the listen-only tap, a hot key takes the key for itself: the app you're in
/// never sees the F12 meant for Keet (in VS Code it would jump to a definition), and
/// holding it doesn't repeat into the app. macOS sends one press and one release
/// however long it's held.
final class FunctionKeyHotkey {
    private static let signature: OSType = 0x4B45_4554  // "KEET"

    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    private(set) var key: FunctionKey?
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var held = false
    private let releaseWatch = ReleaseWatch()

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, refcon in
                guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard id.signature == FunctionKeyHotkey.signature else { return OSStatus(eventNotHandledErr) }
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                Unmanaged<FunctionKeyHotkey>.fromOpaque(refcon).takeUnretainedValue().handle(pressed: pressed)
                return noErr
            },
            types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Takes `key` for Keet, or gives the current one back with nil. Returns false when
    /// macOS refuses it (another app already registered it).
    @discardableResult
    func register(_ key: FunctionKey?) -> Bool {
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
        held = false
        releaseWatch.stop()
        self.key = key
        guard let key else { return true }
        let status = RegisterEventHotKey(
            UInt32(key.rawValue), 0, EventHotKeyID(signature: Self.signature, id: 1), GetEventDispatcherTarget(), 0,
            &registration)
        if status != noErr { self.key = nil }
        return status == noErr
    }

    private func handle(pressed: Bool) {
        if pressed {
            // As with the main key: never dictate into a password field.
            guard !held, !IsSecureEventInputEnabled() else { return }
            held = true
            onPress()
            guard let key else { return }
            releaseWatch.start(
                isDown: { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.rawValue)) },
                onMissedRelease: { [weak self] in
                    log.error("\(key.title, privacy: .public) is up but its release never arrived; ending the dictation")
                    self?.handle(pressed: false)
                })
        } else if held {
            held = false
            releaseWatch.stop()
            onRelease()
        }
    }
}

/// Watches the keyboard with a listen-only event tap. It never blocks or alters
/// input, so a slow or stuck Keet can't interfere with typing.
final class HotkeyMonitor {
    enum CancelReason {
        /// Another key, click or modifier early in the hold: it was a shortcut.
        case shortcut
        /// Escape while holding.
        case escape
    }

    var choice: HotkeyChoice
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: (CancelReason) -> Void = { _ in }
    /// After holding this long it's a dictation, not a shortcut: stray keys, clicks and
    /// modifiers no longer cancel it. Only Escape does.
    var shortcutWindow: TimeInterval = 0.6
    /// Escape pressed while not dictating (used to dismiss the result card).
    var onEscape: () -> Void = {}
    /// Any key or click while not holding: you've moved on, so a dictation still
    /// listening for its last word can stop.
    var onActivity: () -> Void = {}
    /// The Hebrew key. FunctionKeyHotkey handles it; this tap still sees it, so it's
    /// skipped here.
    var functionKeyCode: Int?
    /// The Hebrew key is held: Escape cancels that dictation, other keys, clicks and the
    /// main key do nothing.
    var functionKeyHeld = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    private var cancelled = false
    private var pressedAt: CFAbsoluteTime = 0
    private let releaseWatch = ReleaseWatch()

    private var inShortcutWindow: Bool { CFAbsoluteTimeGetCurrent() - pressedAt < shortcutWindow }

    private func cancel(_ reason: CancelReason) {
        guard !cancelled else { return }
        cancelled = true
        onCancel(reason)
    }

    init(choice: HotkeyChoice) { self.choice = choice }

    var isRunning: Bool { tap != nil }

    /// Returns false when macOS refuses the tap (Accessibility not granted yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func released() {
        held = false
        releaseWatch.stop()
        if !cancelled { onRelease() }
    }

    private func missedRelease() {
        guard held else { return }
        let tapOn = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        log.error("\(self.choice.title, privacy: .public) is up but its release never arrived (tap enabled: \(tapOn)); ending the dictation")
        if let tap, !tapOn { CGEvent.tapEnable(tap: tap, enable: true) }
        released()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A release may have happened while the tap was off.
            if held, !choice.isDown(CGEventSource.flagsState(.combinedSessionState)) { released() }

        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            if code == choice.rawValue {
                let down = choice.isDown(flags)
                if down, !held {
                    // Only a bare press dictates; with other modifiers it's a shortcut. While
                    // the Hebrew key is held, the main key is ignored altogether.
                    guard !choice.othersHeld(flags), !IsSecureEventInputEnabled(), !functionKeyHeld else { return }
                    held = true
                    cancelled = false
                    pressedAt = CFAbsoluteTimeGetCurrent()
                    onPress()
                    releaseWatch.start(
                        isDown: { [choice] in choice.isDown(CGEventSource.flagsState(.combinedSessionState)) },
                        onMissedRelease: { [weak self] in self?.missedRelease() })
                } else if !down, held {
                    released()
                }
            } else if held, choice.othersHeld(flags), inShortcutWindow {
                cancel(.shortcut)
            }

        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if code == functionKeyCode { return }
            // During a Hebrew dictation the main key's state doesn't matter: Escape
            // cancels it, and nothing else does.
            if functionKeyHeld {
                if code == kVK_Escape { onCancel(.escape) }
                return
            }
            if held {
                if code == kVK_Escape {
                    cancel(.escape)
                } else if inShortcutWindow {
                    // Option+arrow, Option+letter: a shortcut, not dictation.
                    cancel(.shortcut)
                }
                // Later keys are ignored: a bumped key must not throw away minutes of speech.
            } else {
                // Our own Command-V paste arrives here too; it isn't the user.
                if event.getIntegerValueField(.eventSourceUserData) != TextInserter.syntheticEventTag {
                    onActivity()
                }
                if code == kVK_Escape { onEscape() }
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if functionKeyHeld { return }
            if held {
                if inShortcutWindow { cancel(.shortcut) }
            } else {
                onActivity()
            }

        default:
            break
        }
    }
}
