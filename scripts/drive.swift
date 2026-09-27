// Test driver: posts synthetic key events the way a real keyboard would.
//   swift scripts/drive.swift hold <keycode> <ms>        press a modifier, hold, release
//   swift scripts/drive.swift combo <modcode> <keycode>  modifier + key (e.g. Option+Left)
//   swift scripts/drive.swift key <keycode>              press and release a key
//   swift scripts/drive.swift click <x> <y>              left click at screen point (top-left origin)
import AppKit

let deviceBits: [Int: UInt64] = [58: 0x20, 61: 0x40, 55: 0x08, 54: 0x10, 56: 0x02, 60: 0x04, 59: 0x01]
let familyMask: [Int: CGEventFlags] = [
    58: .maskAlternate, 61: .maskAlternate, 55: .maskCommand, 54: .maskCommand,
    56: .maskShift, 60: .maskShift, 59: .maskControl, 63: .maskSecondaryFn,
]
let source = CGEventSource(stateID: .hidSystemState)

func modifier(_ code: Int, down: Bool) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)!
    event.type = .flagsChanged
    var raw: UInt64 = 0x100
    if down { raw |= (familyMask[code]?.rawValue ?? 0) | (deviceBits[code] ?? 0) }
    event.flags = CGEventFlags(rawValue: raw)
    event.post(tap: .cghidEventTap)
}

func key(_ code: Int, flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(15_000)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "hold":
    let code = Int(args[1])!, ms = Int(args[2])!
    modifier(code, down: true)
    usleep(UInt32(ms * 1000))
    modifier(code, down: false)
case "combo":
    let mod = Int(args[1])!, code = Int(args[2])!
    modifier(mod, down: true)
    usleep(60_000)
    key(code, flags: CGEventFlags(rawValue: (familyMask[mod]?.rawValue ?? 0) | (deviceBits[mod] ?? 0)))
    usleep(60_000)
    modifier(mod, down: false)
case "key":
    key(Int(args[1])!)
case "click":
    let point = CGPoint(x: Double(args[1])!, y: Double(args[2])!)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(30_000)
    }
default:
    print("usage: drive.swift hold <keycode> <ms> | combo <mod> <key> | key <code> | click <x> <y>")
}
