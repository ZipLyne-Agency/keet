import AppKit
import Carbon.HIToolbox

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

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    private var cancelled = false
    private var pressedAt: CFAbsoluteTime = 0

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

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A release may have happened while the tap was off.
            if held, !choice.isDown(CGEventSource.flagsState(.combinedSessionState)) {
                held = false
                if !cancelled { onRelease() }
            }

        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            if code == choice.rawValue {
                let down = choice.isDown(flags)
                if down, !held {
                    // Only a bare press dictates; with other modifiers it's a shortcut.
                    guard !choice.othersHeld(flags), !IsSecureEventInputEnabled() else { return }
                    held = true
                    cancelled = false
                    pressedAt = CFAbsoluteTimeGetCurrent()
                    onPress()
                } else if !down, held {
                    held = false
                    if !cancelled { onRelease() }
                }
            } else if held, choice.othersHeld(flags), inShortcutWindow {
                cancel(.shortcut)
            }

        case .keyDown:
            if held {
                if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
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
                if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) { onEscape() }
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
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
