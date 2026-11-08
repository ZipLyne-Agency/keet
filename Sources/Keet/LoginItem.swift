import AppKit
import ServiceManagement
import os

private let log = Logger(subsystem: "agency.ziplyne.keet", category: "app")

/// Open at Login, through a launchd agent rather than a plain login item, so that a Keet
/// that crashes is opened again within seconds instead of leaving the dictation key dead
/// until someone notices. Quit exits cleanly and launchd leaves it quit.
@MainActor
enum LoginItem {
    static let label = "agency.ziplyne.keet.agent"
    private static var agent: SMAppService { .agent(plistName: "\(label).plist") }

    static var isOn: Bool { agent.status == .enabled }

    /// This copy of Keet was started by the agent, so launchd will reopen it if it dies.
    static var isSupervised: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    static func set(_ on: Bool) throws {
        if on {
            try agent.register()
            if agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else {
            // Unregistering stops the agent's process, which may be this one; come back
            // as an ordinary app a moment later.
            if isSupervised { relaunch(after: 1.5) }
            try agent.unregister()
        }
    }

    /// Run first at launch. Returns false when this copy should exit because the agent
    /// runs (or is about to run) Keet instead.
    static func launch() -> Bool {
        migrateFromPlainLoginItem()
        if isSupervised {
            // A copy opened from Finder hands over to the agent and exits; give it a
            // moment. One still running after that is a real second copy.
            let deadline = Date().addingTimeInterval(3)
            while otherCopyRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if otherCopyRunning {
                log.notice("another Keet is already running; this one exits")
                return false
            }
            return true
        }
        // The fallback below opens Keet with this flag when launchd couldn't start it.
        guard isOn, !CommandLine.arguments.contains(standaloneFlag) else { return true }
        // Opened from Finder, Spotlight or a build script: let the agent run it, so it's
        // watched over. launchctl does nothing if the agent's copy is already running.
        log.notice("handing over to the login agent")
        startAgent(after: 0.3)
        return false
    }

    private static var otherCopyRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != getpid() && !$0.isTerminated }
    }

    /// Earlier versions used a plain login item; replace it so a crash gets reopened.
    private static func migrateFromPlainLoginItem() {
        let plain = SMAppService.mainApp
        guard plain.status == .enabled else { return }
        do {
            try agent.register()
            try plain.unregister()
            log.notice("Open at Login moved to the login agent (\(String(describing: agent.status), privacy: .public))")
        } catch {
            log.error("couldn't move Open at Login to the login agent: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let standaloneFlag = "--standalone"

    /// Detached, so it outlives this process.
    private static func startAgent(after delay: Double) {
        spawn("sleep \(delay); /bin/launchctl kickstart gui/\(getuid())/\(label) || \(openCommand)")
    }

    /// Only if no Keet is running by then, so there's never a second copy.
    private static func relaunch(after delay: Double) {
        spawn("sleep \(delay); /usr/bin/pgrep -xq Keet || \(openCommand)")
    }

    private static var openCommand: String {
        "/usr/bin/open -n -b agency.ziplyne.keet --args \(standaloneFlag)"
    }

    private static func spawn(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
    }
}
