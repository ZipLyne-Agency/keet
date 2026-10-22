import AppKit
import Testing
@testable import Keet

@Suite(.serialized)
struct HotkeyTests {
    @Test func inputSnapshotSurvivesChangesToTheOriginalEvent() {
        let event = flags(0x80120)
        let snapshot = KeyboardEventSnapshot(.flagsChanged, event)
        event.flags = CGEventFlags(rawValue: 0x100)
        #expect(snapshot.code == 58)
        #expect(snapshot.flags.rawValue == 0x80120)
    }

    private func flags(_ raw: UInt64, code: Int = 58) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: raw)
        return event
    }

    @Test @MainActor func normalPressAndRelease() {
        let monitor = HotkeyMonitor(choice: .leftOption)
        var presses = 0, releases = 0
        monitor.onPress = { presses += 1 }
        monitor.onRelease = { releases += 1 }
        monitor.handle(.flagsChanged, flags(0x80120))
        monitor.handle(.flagsChanged, flags(0x100))
        #expect(presses == 1)
        #expect(releases == 1)
    }

    @Test @MainActor func releaseCanBeRecoveredFromAnotherModifierEvent() {
        let monitor = HotkeyMonitor(choice: .leftOption)
        var releases = 0
        monitor.onRelease = { releases += 1 }
        monitor.handle(.flagsChanged, flags(0x80120))
        // A remapper or a missed event can report another modifier next. Its flags
        // already say Option is up; waiting for the polling timer adds needless lag.
        monitor.handle(.flagsChanged, flags(0x100108, code: 55))
        #expect(releases == 1)
        monitor.handle(.flagsChanged, flags(0x100))
        #expect(releases == 1)
    }

    @Test @MainActor func shortcutCancelsOnlyOnceAndDoesNotDeliver() {
        let monitor = HotkeyMonitor(choice: .leftOption)
        var cancels = 0, releases = 0
        monitor.onCancel = { _ in cancels += 1 }
        monitor.onRelease = { releases += 1 }
        monitor.handle(.flagsChanged, flags(0x80120))
        let key = flags(0x80120, code: 123)
        monitor.handle(.keyDown, key)
        monitor.handle(.keyDown, key)
        monitor.handle(.flagsChanged, flags(0x100))
        #expect(cancels == 1)
        #expect(releases == 0)
    }

    @Test @MainActor func oppositeOptionDoesNotStartDictation() {
        let monitor = HotkeyMonitor(choice: .leftOption)
        var presses = 0
        monitor.onPress = { presses += 1 }
        monitor.handle(.flagsChanged, flags(0x80140, code: 61))
        #expect(presses == 0)
    }
}
