import AppKit

/// Copy the fields we need while CoreGraphics owns the event. No key text is kept.
struct KeyboardEventSnapshot {
    let type: CGEventType
    let code: Int
    let flags: CGEventFlags
    let sourceTag: Int64
    let timestamp: CGEventTimestamp

    init(_ type: CGEventType, _ event: CGEvent) {
        self.type = type
        code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        flags = event.flags
        sourceTag = event.getIntegerValueField(.eventSourceUserData)
        timestamp = event.timestamp
    }
}

/// A dedicated input run loop keeps AppKit layout, AX calls, and menus out of the
/// event-tap callback. Only immutable snapshots cross back to the main thread.
final class KeyboardEventTap {
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var thread: Thread?
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var stopped = false
    private let onEvent: (KeyboardEventSnapshot) -> Void

    init(onEvent: @escaping (KeyboardEventSnapshot) -> Void) { self.onEvent = onEvent }

    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func enable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func start() -> Bool {
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    let owner = Unmanaged<KeyboardEventTap>.fromOpaque(context).takeUnretainedValue()
                    let snapshot = KeyboardEventSnapshot(type, event)
                    // Re-enable on the input thread, even if the UI is busy.
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { owner.enable() }
                    let onEvent = owner.onEvent
                    DispatchQueue.main.async { onEvent(snapshot) }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            self.loop = loop
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
            finished.signal()
        }
        thread.name = "Keet keyboard input"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        // Only the run-loop setup runs before this signal, never an AX or UI call.
        ready.wait()
        return true
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let tap { CFMachPortInvalidate(tap) }
        if let loop { CFRunLoopStop(loop) }
        if thread != nil, Thread.current !== thread { finished.wait() }
        thread = nil
    }
}
