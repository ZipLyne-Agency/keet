import AVFoundation
import AppKit
import ApplicationServices
import KeetCore
import ServiceManagement
import SwiftUI

// MARK: - Theme

enum Theme {
    static let background = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let surface = Color(red: 0.078, green: 0.082, blue: 0.094)
    static let surfaceRaised = Color(red: 0.110, green: 0.114, blue: 0.129)
    static let hairline = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.34)
    static let accent = Color(red: 0.37, green: 0.89, blue: 0.63)
    static let warning = Color(red: 0.96, green: 0.73, blue: 0.29)
    static let danger = Color(red: 0.95, green: 0.45, blue: 0.44)
}

private struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? Theme.text : tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.09) : Color.white.opacity(0.04)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Root

struct MainView: View {
    enum Tab: String, CaseIterable { case history = "History", settings = "Settings" }

    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore
    @State private var tab: Tab

    init(controller: AppController, history: HistoryStore, tab: Tab = .history) {
        self.controller = controller
        self.history = history
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Group {
                switch tab {
                case .history: HistoryPage(controller: controller, history: history)
                case .settings: SettingsPage(controller: controller, history: history)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(edges: .top)
    }

    private var header: some View {
        HStack(spacing: 12) {
            // Room for the window's traffic lights.
            Color.clear.frame(width: 64, height: 1)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 24, height: 24)
            Text("Keet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            StatusChip(controller: controller)
            Spacer(minLength: 12)
            TabSwitcher(tab: $tab)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Theme.background)
    }
}

private struct TabSwitcher: View {
    @Binding var tab: MainView.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MainView.Tab.allCases, id: \.self) { item in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { tab = item }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item == .history ? "clock.arrow.circlepath" : "gearshape")
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.rawValue).font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(tab == item ? Color.black : Theme.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(tab == item ? Theme.text : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

private struct StatusChip: View {
    @ObservedObject var controller: AppController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.5)) { _ in
            let (color, title, detail) = status
            HStack(spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .shadow(color: color.opacity(0.8), radius: controller.phase == .listening ? 4 : 0)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Theme.hairline))
        }
    }

    private var status: (Color, String, String?) {
        switch controller.phase {
        case .listening: return (Theme.danger, "Listening", nil)
        case .transcribing: return (Theme.warning, "Transcribing", nil)
        case .idle: break
        }
        switch controller.modelState {
        case .loading: return (Theme.warning, "Loading model", nil)
        case .failed: return (Theme.danger, "Model failed to load", nil)
        case .ready:
            if !AXIsProcessTrusted() || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                return (Theme.warning, "Needs permission", "see Settings")
            }
            return (Theme.accent, "Ready", "hold \(controller.hotkeyChoice.symbol) \(controller.hotkeyChoice.title)")
        }
    }
}

// MARK: - History

private struct HistoryPage: View {
    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [Dictation] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.text.localizedCaseInsensitiveContains(q) || ($0.appName ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private var days: [(day: Date, items: [Dictation])] {
        let calendar = Calendar.current
        var groups: [(Date, [Dictation])] = []
        for entry in filtered {
            let day = calendar.startOfDay(for: entry.date)
            if let last = groups.last, last.0 == day {
                groups[groups.count - 1].1.append(entry)
            } else {
                groups.append((day, [entry]))
            }
        }
        return groups
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatsRow(entries: history.entries)
                toolbar
                if history.entries.isEmpty {
                    EmptyHistory(choice: controller.hotkeyChoice)
                } else if filtered.isEmpty {
                    Text("Nothing matches \u{201C}\(query)\u{201D}.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                        ForEach(days, id: \.day) { group in
                            Section {
                                ForEach(group.items) { entry in
                                    DictationRow(entry: entry, controller: controller) {
                                        history.delete(entry.id)
                                    }
                                }
                            } header: {
                                DayHeader(day: group.day, words: group.items.reduce(0) { $0 + $1.words })
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .confirmationDialog("Delete all dictations?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("This removes every dictation from this Mac. It can't be undone.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                TextField("Search your dictations", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))

            Menu {
                Button("Export as Text…", action: export)
                    .disabled(history.entries.isEmpty)
                Divider()
                Button("Delete All…", role: .destructive) { confirmClear = true }
                    .disabled(history.entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Keet dictations \(Date().formatted(.iso8601.year().month().day())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines: [String] = []
        for group in days {
            lines.append(group.day.formatted(date: .complete, time: .omitted))
            lines.append("")
            for entry in group.items.reversed() {
                let app = entry.appName.map { " \($0)" } ?? ""
                lines.append("[\(entry.date.formatted(date: .omitted, time: .shortened))]\(app)")
                lines.append(entry.text)
                lines.append("")
            }
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct StatsRow: View {
    let entries: [Dictation]

    var body: some View {
        let today = entries.filter { Calendar.current.isDateInToday($0.date) }
        let latencies = entries.prefix(50).map(\.latencyMs).filter { $0 > 0 }.sorted()
        HStack(spacing: 12) {
            stat(today.reduce(0) { $0 + $1.words }.formatted(), "Words today", "text.word.spacing")
            stat(today.count.formatted(), "Dictations today", "waveform")
            stat(latencies.isEmpty ? "–" : "\(latencies[latencies.count / 2]) ms", "Key release to text", "bolt")
            stat(entries.reduce(0) { $0 + $1.words }.formatted(), "Words, all time", "sum")
        }
    }

    private func stat(_ value: String, _ label: String, _ symbol: String) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}

private struct DayHeader: View {
    let day: Date
    let words: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.secondary)
            Spacer()
            Text("\(words.formatted()) words")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .background(Theme.background)
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased()
    }
}

private enum AppIcons {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

private struct DictationRow: View {
    let entry: Dictation
    @ObservedObject var controller: AppController
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.appName ?? "Dictation")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                    if entry.delivery == .card {
                        Text("Not inserted")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.warning.opacity(0.12)))
                            .help("No text field had focus, so it went to the Copy card")
                    }
                    Spacer(minLength: 8)
                    // Timing at rest, actions on hover, in the same spot.
                    ZStack(alignment: .trailing) {
                        if entry.audioSeconds > 0 {
                            Text(String(format: "%.1f s · %d ms", entry.audioSeconds, entry.latencyMs))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                                .help("Recording length · key release to text")
                                .opacity(hovering || copied ? 0 : 1)
                        }
                        HStack(spacing: 4) {
                            IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy",
                                       tint: copied ? Theme.accent : Theme.secondary) { copy() }
                            if let app = controller.lastExternalApp?.localizedName {
                                IconButton(symbol: "arrow.turn.down.left", help: "Paste into \(app)") {
                                    controller.pasteIntoLastApp(entry.text)
                                }
                            }
                            IconButton(symbol: "trash", help: "Delete", action: onDelete)
                        }
                        .opacity(hovering || copied ? 1 : 0)
                    }
                    .frame(height: 18)
                }
                Text(entry.text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(hovering ? Theme.surfaceRaised : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Copy") { copy() }
            if let app = controller.lastExternalApp?.localizedName {
                Button("Paste into \(app)") { controller.pasteIntoLastApp(entry.text) }
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder private var appIcon: some View {
        if let icon = AppIcons.icon(for: entry.bundleID) {
            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.accent.opacity(0.12)))
        }
    }

    private func copy() {
        TextInserter.copyToClipboard(entry.text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

private struct EmptyHistory: View {
    let choice: HotkeyChoice

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Theme.accent.opacity(0.1)))
            Text("Hold \(choice.symbol) \(choice.title) and start talking")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Let go and the text appears wherever your cursor is.\nEverything you say is kept here, on this Mac.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Dictation key", "Hold to talk, let go to insert. Escape cancels.") { keyPicker }
                section("Microphone", nil) { microphone }
                section("General", nil) { general }
                section("Permissions", "Keet needs both to hear you and to type for you.") { permissions }
                section("Speech model", "Runs entirely on this Mac. Nothing you say leaves it.") { model }
                footer
            }
            .padding(28)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    private func section<Content: View>(_ title: String, _ subtitle: String?, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            content()
        }
    }

    // Dictation key

    private var keyPicker: some View {
        HStack(spacing: 10) {
            ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                let selected = controller.hotkeyChoice == choice
                Button { controller.setHotkey(choice) } label: {
                    VStack(spacing: 8) {
                        Text(choice.symbol)
                            .font(.system(size: choice == .fn ? 17 : 22, weight: .medium, design: .rounded))
                            .foregroundStyle(selected ? Theme.accent : Theme.text)
                        Text(choice.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 78)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? Theme.accent.opacity(0.08) : Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: selected ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Microphone

    private var microphone: some View {
        Card(padding: 6) {
            VStack(spacing: 0) {
                micRow(
                    uid: nil, name: "Automatic",
                    detail: "Follows the system input\(controller.systemDefaultMic.map { " · now \($0.name)" } ?? "")",
                    symbol: "wand.and.stars")
                ForEach(controller.inputDevices) { device in
                    micRow(uid: device.uid, name: device.name, detail: detail(device), symbol: symbol(device))
                }
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 6)
                HStack(spacing: 12) {
                    Button(action: controller.toggleMicTest) {
                        Text(controller.isTestingMic ? "Stop" : "Test")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(controller.isTestingMic ? Theme.text : .black)
                            .frame(width: 58, height: 26)
                            .background(Capsule().fill(controller.isTestingMic ? Color.white.opacity(0.12) : Theme.text))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    LevelMeter(level: controller.micTestLevel)
                        .frame(height: 10)
                    Text(controller.isTestingMic ? "Speak now" : controller.activeMicName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text("Bluetooth headsets drop to call quality while their microphone is on. The Mac's own microphone avoids that.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .offset(y: 22)
        }
        .padding(.bottom, 16)
    }

    private func micRow(uid: String?, name: String, detail: String, symbol: String) -> some View {
        let selected = controller.selectedMicUID == uid
        return Button { controller.selectMicrophone(uid: uid) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.secondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Theme.accent : Theme.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.white.opacity(0.04) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(_ device: InputDevice) -> String {
        switch device.transport {
        case .builtIn: "Built in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .virtual: "Virtual device"
        case .other: "External"
        }
    }

    private func symbol(_ device: InputDevice) -> String {
        switch device.transport {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "headphones"
        case .usb: "mic"
        case .virtual: "square.stack.3d.down.right"
        case .other: "mic"
        }
    }

    // General

    private var general: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                toggleRow("Open at login", "Start Keet when you log in, so the key always works.", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                toggleRow(
                    "Keep history on this Mac",
                    "Saved in ~/Library/Application Support/Keet. Off keeps it only until Keet quits.",
                    isOn: $history.keepOnDisk)
            }
        }
    }

    private func toggleRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
        }
        .padding(14)
    }

    // Permissions

    private var permissions: some View {
        TimelineView(.periodic(from: .now, by: 1.5)) { _ in
            Card(padding: 0) {
                VStack(spacing: 0) {
                    permissionRow(
                        "Microphone", "To hear you while you hold the key.",
                        granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                    ) {
                        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                            AVCaptureDevice.requestAccess(for: .audio) { _ in }
                        } else {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    permissionRow(
                        "Accessibility", "To see the dictation key and paste the text.",
                        granted: AXIsProcessTrusted()
                    ) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }
    }

    private func permissionRow(_ title: String, _ detail: String, granted: Bool, action: @escaping () -> Void)
        -> some View
    {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(granted ? Theme.accent : Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if granted {
                Text("Allowed").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            } else {
                Button("Allow…", action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(Theme.text))
            }
        }
        .padding(14)
    }

    // Model

    private var model: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                kv("Model", "Parakeet Unified 0.6B, English")
                divider
                kv("Made by", "NVIDIA · converted to Core ML by FluidInference")
                divider
                kv("Runs on", "Apple Neural Engine, through FluidAudio")
                divider
                kv("Status", modelStatus)
                divider
                HStack {
                    Text("On disk").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(Transcriber.modelDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Transcriber.modelDirectory])
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
    }

    private var modelStatus: String {
        switch controller.modelState {
        case .loading: "Loading…"
        case .ready(let ms): "Ready · loaded in \(ms) ms"
        case .failed(let reason): "Failed: \(reason)"
        }
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Keet \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
            Text("·")
            Link("Open source on GitHub", destination: URL(string: "https://github.com/ZipLyne-Agency/keet")!)
                .foregroundStyle(Theme.accent)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
        .frame(maxWidth: .infinity)
    }
}

private struct LevelMeter: View {
    let level: Float
    private let segments = 32

    var body: some View {
        GeometryReader { geo in
            let lit = Int((level * Float(segments)).rounded())
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < lit ? color(i) : Color.white.opacity(0.07))
                        .frame(width: max(1, (geo.size.width - CGFloat(segments - 1) * 2) / CGFloat(segments)))
                }
            }
        }
        .animation(.linear(duration: 0.06), value: level)
    }

    private func color(_ i: Int) -> Color {
        let x = Double(i) / Double(segments)
        return x < 0.7 ? Theme.accent : (x < 0.9 ? Theme.warning : Theme.danger)
    }
}

// MARK: - Window

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let controller: AppController
    private var window: NSWindow?

    init(controller: AppController) {
        self.controller = controller
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Keet"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(Theme.background)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 540)
            window.contentView = NSHostingView(
                rootView: MainView(controller: controller, history: controller.history))
            window.setFrameAutosaveName("KeetMainWindow")
            if !window.setFrameUsingName("KeetMainWindow") { window.center() }
            window.delegate = self
            self.window = window
        }
        // A Dock icon while the window is open makes it reachable with Command-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        controller.stopMicTest()
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Snapshots

/// Renders the window off screen with sample data, for design review without
/// showing anything on the display. Run with KEET_SNAPSHOT=<directory>.
@MainActor
enum Snapshot {
    static func sampleHistory() -> [Dictation] {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            Dictation(date: ago(2), text: "Can you send me the latest numbers before the meeting this afternoon?",
                      appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", audioSeconds: 3.4, latencyMs: 132, delivery: .pasted),
            Dictation(date: ago(9), text: "Let's move the standup to 10:30 and skip the retro this week.",
                      appName: "Messages", bundleID: "com.apple.MobileSMS", audioSeconds: 2.9, latencyMs: 118, delivery: .pasted),
            Dictation(date: ago(31), text: "Honestly the new design looks great, but the spacing on the settings page feels a little tight. Can we give the cards more room and bring the headings closer to their content?",
                      appName: "Notes", bundleID: "com.apple.Notes", audioSeconds: 9.8, latencyMs: 161, delivery: .pasted),
            Dictation(date: ago(47), text: "Book a table for four people at seven.",
                      appName: "Finder", bundleID: "com.apple.finder", audioSeconds: 2.2, latencyMs: 97, delivery: .card),
            Dictation(date: ago(60 * 26), text: "Make sure the tests pass before you merge it, and tag me on the pull request.",
                      appName: "Mail", bundleID: "com.apple.mail", audioSeconds: 4.1, latencyMs: 140, delivery: .pasted),
            Dictation(date: ago(60 * 27), text: "Remind me to call the accountant about the invoice tomorrow morning.",
                      appName: "Reminders", bundleID: "com.apple.reminders", audioSeconds: 3.3, latencyMs: 125, delivery: .pasted),
        ]
    }

    static func render(to directory: URL, controller: AppController) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tabs: [(MainView.Tab, String)] = [(.history, "history"), (.settings, "settings")]
        var windows: [NSWindow] = []
        for (tab, name) in tabs {
            let view = NSHostingView(rootView: MainView(controller: controller, history: controller.history, tab: tab))
            let frame = NSRect(x: -20_000, y: -20_000, width: 940, height: tab == .settings ? 1180 : 680)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            windows.forEach { $0.orderOut(nil) }
            NSApp.terminate(nil)
        }
    }
}
