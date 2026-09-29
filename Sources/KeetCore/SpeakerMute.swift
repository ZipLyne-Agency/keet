import CoreAudio
import Foundation

/// Mutes the Mac's speakers while you dictate, so what they play (a video, music, an
/// app running in a simulator) doesn't reach the microphone and end up in the text.
/// Headphones and Bluetooth output can't leak into the mic, so they're left alone, and
/// speakers you had already muted stay muted afterwards.
public final class SpeakerMute: @unchecked Sendable {
    private let lock = NSLock()
    private var muted: (id: AudioDeviceID, uid: String, elements: [AudioObjectPropertyElement])?
    /// Set while Keet holds the speakers muted, so a crash can't leave them that way.
    private static let pendingKey = "speakersMutedByKeet"

    public init() {}

    /// Mutes the default output if it's a speaker. Returns what it did, for the log.
    @discardableResult
    public func mute() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard muted == nil else { return "already muted by Keet" }
        guard let id = Self.defaultOutput() else { return "no output device" }
        let name = Self.string(id, kAudioObjectPropertyName) ?? "output"
        let uid = Self.string(id, kAudioDevicePropertyDeviceUID) ?? ""
        if Self.isBluetooth(id) { return "left \(name) alone: Bluetooth" }
        if Self.isHeadphones(id, uid: uid) { return "left \(name) alone: headphones" }
        let elements = Self.muteElements(id)
        guard !elements.isEmpty else { return "\(name) can't be muted" }
        if elements.allSatisfy({ Self.isMuted(id, $0) }) { return "\(name) was already muted" }
        for element in elements { Self.setMute(id, element, true) }
        muted = (id, uid, elements)
        UserDefaults.standard.set(uid, forKey: Self.pendingKey)
        return "muted \(name)"
    }

    /// Unmutes the speakers if Keet muted them.
    public func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard let muted else { return }
        for element in muted.elements { Self.setMute(muted.id, element, false) }
        self.muted = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
    }

    /// Keet quit or crashed mid-dictation last time: unmute the speakers it left muted.
    public static func restoreAfterCrash() {
        guard let uid = UserDefaults.standard.string(forKey: pendingKey) else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        guard let id = device(uid: uid) else { return }
        for element in muteElements(id) { setMute(id, element, false) }
    }

    // MARK: - CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func device(uid: String) -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return nil }
        return ids.first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr else { return false }
        return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Apple silicon lists the headphone jack as its own device; older Macs switch the
    /// built-in output's data source to headphones.
    private static func isHeadphones(_ id: AudioDeviceID, uid: String) -> Bool {
        if uid.localizedCaseInsensitiveContains("headphone") { return true }
        var address = address(kAudioDevicePropertyDataSource)
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &source) == noErr else { return false }
        return source == 0x6864_706E  // 'hdpn'
    }

    /// The main element when the device has a master mute, else its first two channels.
    private static func muteElements(_ id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        func settable(_ element: AudioObjectPropertyElement) -> Bool {
            var address = address(kAudioDevicePropertyMute, element)
            var settable = DarwinBoolean(false)
            return AudioObjectHasProperty(id, &address)
                && AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(settable)
    }

    private static func isMuted(_ id: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Bool {
        var address = address(kAudioDevicePropertyMute, element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func setMute(_ id: AudioDeviceID, _ element: AudioObjectPropertyElement, _ on: Bool) {
        var address = address(kAudioDevicePropertyMute, element)
        var value: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
