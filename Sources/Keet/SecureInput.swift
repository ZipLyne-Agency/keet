import AppKit
import Carbon.HIToolbox
import IOKit

/// Who holds macOS secure input. While any app holds it, every app's key listeners are
/// told so, and a forgotten holder is the usual reason a global hotkey "stops working".
enum SecureInput {
    static var isOn: Bool { IsSecureEventInputEnabled() }

    /// The process holding secure input, from the console user's registry entry.
    static func holderPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int, pid > 0 { return pid_t(pid) }
        }
        return nil
    }

    /// "Terminal (412)", for the log.
    static func holderDescription() -> String {
        guard let pid = holderPID() else { return "unknown" }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid"
        return "\(name) (\(pid))"
    }
}
