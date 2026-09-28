import AVFoundation
import AppKit
import ApplicationServices
import KeetCore
import ServiceManagement
import SwiftUI

// The window follows Witzper's terminal look: near-black panels, monospaced type,
// amber headings, green output, cyan identifiers, hairline borders.

// MARK: - Palette and type

enum Term {
    static let black = Color(red: 0.02, green: 0.02, blue: 0.03)
    static let strip = Color(white: 0.04)
    static let card = Color(white: 0.052)
    static let cardHover = Color(white: 0.075)
    static let well = Color(white: 0.08)
    static let border = Color(red: 0.15, green: 0.15, blue: 0.18)
    static let amber = Color(red: 1.0, green: 0.65, blue: 0.0)
    static let green = Color(red: 0.0, green: 0.95, blue: 0.4)
    static let cyan = Color(red: 0.4, green: 0.9, blue: 1.0)
    static let red = Color(red: 1.0, green: 0.3, blue: 0.3)
    static let dim = Color(white: 0.45)
    static let faint = Color(white: 0.28)
    static let text = Color(white: 0.9)
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let termHeader = mono(11, .bold)
    static let termBody = mono(12)
    static let termSmall = mono(10)
    static let termBig = mono(24, .bold)
}

// MARK: - Building blocks

private struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.termHeader).foregroundStyle(Term.amber).tracking(0.6)
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Term.strip)
    }
}

private struct KV: View {
    let key: String
    let value: String
    var color: Color = Term.cyan
    var keyWidth: CGFloat = 76

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(.termSmall).foregroundStyle(Term.dim).frame(width: keyWidth, alignment: .leading)
            Text(value).font(.termBody).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }
}

/// A bordered monospaced button, Witzper style.
private struct TermButton: View {
    let title: String
    var color: Color = Term.amber
    var filled = false
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.termSmall.weight(.semibold))
                .foregroundStyle(filled ? Term.black : color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(filled ? color : (hovering ? color.opacity(0.14) : Color.clear)))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(color.opacity(hovering || filled ? 1 : 0.75), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

private struct TermField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Text("›").font(.termBody).foregroundStyle(Term.amber)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Term.faint))
                .textFieldStyle(.plain)
                .font(.termBody)
                .foregroundStyle(Term.text)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Term.well)
        .overlay(Rectangle().stroke(Term.border, lineWidth: 1))
    }
}

private struct Meter: View {
    let level: Float
    var segments = 30

    var body: some View {
        GeometryReader { geo in
            let lit = Int((level * Float(segments)).rounded())
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    Rectangle()
                        .fill(i < lit ? color(i) : Color(white: 0.12))
                        .frame(width: max(1, (geo.size.width - CGFloat(segments - 1) * 2) / CGFloat(segments)))
                }
            }
        }
        .animation(.linear(duration: 0.05), value: level)
    }

    private func color(_ i: Int) -> Color {
        if i < Int(Double(segments) * 0.6) { return Term.green }
        if i < Int(Double(segments) * 0.85) { return Term.amber }
        return Term.red
    }
}

private struct LatencyBar: View {
    let label: String
    let ms: Int?
    let max: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.termSmall).foregroundStyle(Term.dim).frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Term.well)
                    if let ms {
                        Rectangle()
                            .fill(Double(ms) > max * 0.8 ? Term.red : Term.green)
                            .frame(width: geo.size.width * CGFloat(min(Double(ms) / max, 1)))
                    }
                }
            }
            .frame(height: 8)
            Text(ms.map { "\($0)ms" } ?? "--").font(.termSmall).foregroundStyle(Term.amber)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// Latency over recent dictations, newest on the right.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let top = Swift.max(values.max() ?? 1, 1)
            let step = geo.size.width / CGFloat(Swift.max(values.count - 1, 1))
            let points = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step, y: geo.size.height - geo.size.height * CGFloat(v / top))
            }
            ZStack {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Term.green.opacity(0.28), Term.green.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(Term.green, lineWidth: 1.5)
                if let last = points.last {
                    Circle().fill(Term.green).frame(width: 5, height: 5).position(last)
                        .shadow(color: Term.green, radius: 4)
                }
            }
        }
    }
}

private struct Blink: View {
    @State private var on = true
    var body: some View {
        Text("_").font(.mono(15, .bold)).opacity(on ? 1 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on.toggle() } }
    }
}

// MARK: - Root

struct MainView: View {
    enum Tab: String, CaseIterable {
        case feed = "LIVE FEED"
        case dictionary = "DICTIONARY"
        case settings = "SETTINGS"
    }

    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore
    @ObservedObject var dictionary: DictionaryStore
    @State private var tab: Tab

    init(controller: AppController, history: HistoryStore, tab: Tab = .feed) {
        self.controller = controller
        self.history = history
        self.dictionary = controller.dictionary
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(controller: controller, history: history, dictionary: dictionary)
            line
            tabBar
            line
            Group {
                switch tab {
                case .feed: FeedTab(controller: controller, history: history, dictionary: dictionary)
                case .dictionary: DictionaryTab(controller: controller, dictionary: dictionary)
                case .settings: SettingsTab(controller: controller, history: history)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            line
            StatusBar(controller: controller, history: history)
        }
        .background(Term.black)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(edges: .top)
    }

    private var line: some View { Rectangle().fill(Term.border).frame(height: 1) }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 6) {
                        Text(item.rawValue)
                            .font(.termHeader)
                            .tracking(0.6)
                            .foregroundStyle(item == tab ? Term.amber : Term.dim)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                        Rectangle()
                            .fill(item == tab ? Term.amber : Color.clear)
                            .frame(height: 2)
                            .shadow(color: item == tab ? Term.amber.opacity(0.7) : .clear, radius: 4)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .background(Term.strip)
    }
}

// MARK: - Header and status bar

private struct HeaderBar: View {
    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore
    @ObservedObject var dictionary: DictionaryStore

    var body: some View {
        HStack(spacing: 20) {
            Color.clear.frame(width: 58, height: 1)  // traffic lights
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("KEET").font(.mono(17, .black)).foregroundStyle(Term.amber).tracking(1)
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.termSmall).foregroundStyle(Term.dim)
            }
            Spacer(minLength: 12)
            label("STATUS", controller.statusLine.text, controller.statusLine.color)
            label("HOTKEY", controller.hotkeyChoice.shortLabel, Term.cyan)
            label("MIC", controller.activeMicName.uppercased(), Term.cyan)
                .frame(maxWidth: 170, alignment: .leading)
            label("DICT", dictionary.words.isEmpty ? "OFF" : "\(dictionary.words.count)", Term.amber)
            label("TODAY", "\(todayWords)W", Term.amber)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                    .font(.termSmall).foregroundStyle(Term.dim).monospacedDigit()
            }
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Term.black)
    }

    private var todayWords: Int {
        history.entries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.words }
    }

    private func label(_ key: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key).font(.termSmall).foregroundStyle(Term.dim)
            Text(value).font(.termBody).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
        }
    }
}

private struct StatusBar: View {
    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 7, height: 7).shadow(color: dotColor, radius: 3)
            Text(engineText).font(.termSmall).foregroundStyle(Term.dim)
            if let last = history.entries.first, last.latencyMs > 0 {
                Text("·").font(.termSmall).foregroundStyle(Term.faint)
                Text("LAST \(last.latencyMs)MS").font(.termSmall).foregroundStyle(Term.dim)
            }
            Spacer()
            Text("KEET · FULLY ON-DEVICE DICTATION").font(.termSmall).foregroundStyle(Term.dim)
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Term.strip)
    }

    private var dotColor: Color {
        switch controller.modelState {
        case .ready: return controller.permissionsGranted ? Term.green : Term.amber
        case .loading: return Term.amber
        case .failed: return Term.red
        }
    }

    private var engineText: String {
        switch controller.modelState {
        case .ready(let ms):
            return controller.permissionsGranted ? "ENGINE READY · LOADED IN \(ms)MS" : "PERMISSION NEEDED · SEE SETTINGS"
        case .loading: return "LOADING SPEECH MODEL"
        case .failed: return "SPEECH MODEL FAILED TO LOAD"
        }
    }
}

// MARK: - Live feed

private struct FeedTab: View {
    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore
    @ObservedObject var dictionary: DictionaryStore

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            SystemPanel(controller: controller, history: history, dictionary: dictionary)
                .frame(width: 280)
            Rectangle().fill(Term.border).frame(width: 1)
            TranscriptFeed(controller: controller, history: history)
            Rectangle().fill(Term.border).frame(width: 1)
            ControlPanel(controller: controller, history: history)
                .frame(width: 260)
        }
    }
}

private struct SystemPanel: View {
    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore
    @ObservedObject var dictionary: DictionaryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "SYSTEM")
                VStack(alignment: .leading, spacing: 7) {
                    KV(key: "ASR", value: "PARAKEET UNIFIED 0.6B")
                    KV(key: "WEIGHTS", value: "INT8 ENCODER")
                    KV(key: "BACKEND", value: "APPLE NEURAL ENGINE", color: Term.green)
                    KV(key: "PRIVACY", value: "100% LOCAL", color: Term.green)
                    KV(key: "DICTIONARY", value: dictionaryText, color: Term.amber)
                    KV(key: "CLEANUP", value: cleanupText, color: cleanupText == "APPLE ON DEVICE" ? Term.green : Term.dim)
                    KV(key: "MIC", value: controller.activeMicName.uppercased())
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                SectionHeader(title: "LATENCY (LAST DICTATION)")
                VStack(alignment: .leading, spacing: 6) {
                    LatencyBar(label: "TAIL", ms: last?.tailMs, max: 600)
                    LatencyBar(label: "ASR", ms: last?.transcribeMs, max: 400)
                    LatencyBar(label: "AI", ms: last?.cleanupMs, max: 1000)
                    LatencyBar(label: "TOTAL", ms: last.map(\.latencyMs), max: 1000)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                SectionHeader(title: "LATENCY HISTORY", trailing: AnyView(
                    Text("\(recent.count) RUNS").font(.termSmall).foregroundStyle(Term.dim)))
                VStack(alignment: .leading, spacing: 6) {
                    if recent.count >= 2 {
                        Sparkline(values: recent).frame(height: 56)
                        HStack {
                            stat("MIN", recent.min() ?? 0)
                            Spacer()
                            stat("MEDIAN", recent.sorted()[recent.count / 2])
                            Spacer()
                            stat("MAX", recent.max() ?? 0)
                        }
                    } else {
                        Text("NEEDS TWO DICTATIONS").font(.termSmall).foregroundStyle(Term.faint)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                SectionHeader(title: "TODAY")
                HStack(alignment: .top) {
                    big(todayWords, "WORDS")
                    Spacer()
                    big(today.count, "DICTATIONS")
                }
                .padding(.horizontal, 14).padding(.top, 10)
                KV(key: "ALL TIME", value: "\(history.entries.reduce(0) { $0 + $1.words }.formatted()) WORDS", color: Term.amber)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(Term.black)
    }

    private var last: Dictation? { history.entries.first(where: { $0.latencyMs > 0 }) }
    private var recent: [Double] {
        Array(history.entries.lazy.filter { $0.latencyMs > 0 }.prefix(40).map { Double($0.latencyMs) }.reversed())
    }
    private var today: [Dictation] { history.entries.filter { Calendar.current.isDateInToday($0.date) } }
    private var todayWords: Int { today.reduce(0) { $0 + $1.words } }
    private var cleanupText: String {
        guard controller.aiCleanup else { return "OFF" }
        return controller.cleanupAvailability == .ready ? "APPLE ON DEVICE" : "UNAVAILABLE"
    }
    private var dictionaryText: String {
        switch controller.dictionaryState {
        case .empty: return "OFF"
        case .preparing: return "LOADING…"
        case .active(let n): return "\(n) WORDS"
        case .failed: return "FAILED"
        }
    }

    private func stat(_ label: String, _ ms: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.termSmall).foregroundStyle(Term.dim)
            Text("\(Int(ms))ms").font(.termSmall).foregroundStyle(Term.amber)
        }
    }

    private func big(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.termBig).foregroundStyle(Term.amber).monospacedDigit()
            Text(label).font(.termSmall).foregroundStyle(Term.dim)
        }
    }
}

private struct TranscriptFeed: View {
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
        var groups: [(Date, [Dictation])] = []
        for entry in filtered {
            let day = Calendar.current.startOfDay(for: entry.date)
            if let last = groups.last, last.0 == day {
                groups[groups.count - 1].1.append(entry)
            } else {
                groups.append((day, [entry]))
            }
        }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "LIVE TRANSCRIPT FEED", trailing: AnyView(HStack(spacing: 6) {
                TermButton(title: "EXPORT", color: Term.dim, help: "Save the dictations shown to a text file", action: export)
                TermButton(title: "CLEAR", color: Term.dim, help: "Delete every dictation") { confirmClear = true }
            }))
            TermField(placeholder: "search transcripts or apps", text: $query)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Term.strip)
            Rectangle().fill(Term.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    if history.entries.isEmpty {
                        EmptyFeed(choice: controller.hotkeyChoice)
                    } else if filtered.isEmpty {
                        Text("NO MATCHES FOR \u{201C}\(query.uppercased())\u{201D}").font(.termSmall).foregroundStyle(Term.dim)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(days, id: \.day) { group in
                        Section {
                            ForEach(group.items) { entry in
                                FeedCard(entry: entry, controller: controller) { history.delete(entry.id) }
                            }
                        } header: {
                            DayRule(day: group.day, words: group.items.reduce(0) { $0 + $1.words })
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Term.black)
        .confirmationDialog("Delete all dictations?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("This removes every dictation from this Mac. It can't be undone.")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "keet-\(Date().formatted(.iso8601.year().month().day())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["# Keet dictations", ""]
        for group in days.reversed() {
            lines.append("## \(group.day.formatted(date: .complete, time: .omitted))")
            for entry in group.items.reversed() {
                lines.append("[\(entry.date.formatted(date: .omitted, time: .standard))]\(entry.appName.map { " \($0)" } ?? "")")
                lines.append(entry.text)
                lines.append("")
            }
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct DayRule: View {
    let day: Date
    let words: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.termSmall.weight(.bold)).foregroundStyle(Term.amber)
            Rectangle().fill(Term.border).frame(height: 1)
            Text("\(words) WORDS").font(.termSmall).foregroundStyle(Term.dim)
        }
        .padding(.vertical, 8)
        .background(Term.black)
    }

    private var title: String {
        if Calendar.current.isDateInToday(day) { return "TODAY" }
        if Calendar.current.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
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

private struct FeedCard: View {
    let entry: Dictation
    @ObservedObject var controller: AppController
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                    .font(.termSmall).foregroundStyle(Term.dim).monospacedDigit()
                if let icon = AppIcons.icon(for: entry.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                }
                Text((entry.appName ?? "DICTATION").uppercased()).font(.termSmall.weight(.semibold)).foregroundStyle(Term.cyan)
                if entry.delivery != .pasted {
                    Text("·").font(.termSmall).foregroundStyle(Term.dim)
                    Text(entry.delivery == .card ? "NOT INSERTED" : "CANCELLED")
                        .font(.termSmall.weight(.semibold))
                        .foregroundStyle(entry.delivery == .card ? Term.amber : Term.red)
                }
                if entry.rawText != nil {
                    Text("·").font(.termSmall).foregroundStyle(Term.dim)
                    Text("AI CLEANED").font(.termSmall.weight(.semibold)).foregroundStyle(Term.green.opacity(0.8))
                        .help("Tidied by Apple Intelligence on this Mac")
                }
                Spacer(minLength: 8)
                if entry.audioSeconds > 0 {
                    Text(String(format: "%.1fs", entry.audioSeconds)).font(.termSmall).foregroundStyle(Term.dim)
                }
                if entry.latencyMs > 0 {
                    Text("\(entry.latencyMs) ms").font(.termSmall).foregroundStyle(Term.amber)
                }
                TermButton(title: copied ? "COPIED" : "COPY", color: copied ? Term.green : Term.amber, action: copy)
                if hovering {
                    if let app = controller.lastExternalApp?.localizedName {
                        TermButton(title: "PASTE", color: Term.cyan, help: "Paste into \(app)") {
                            controller.pasteIntoLastApp(entry.text)
                        }
                    }
                    TermButton(title: "DEL", color: Term.red, help: "Delete", action: onDelete)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("▸").font(.termBody).foregroundStyle(Term.green.opacity(0.7))
                Text(entry.text)
                    .font(.mono(12.5))
                    .lineSpacing(3)
                    .foregroundStyle(Term.green)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let raw = entry.rawText {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("HEARD").font(.termSmall).foregroundStyle(Term.faint)
                    Text(raw)
                        .font(.mono(11))
                        .lineSpacing(2)
                        .foregroundStyle(Term.dim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(hovering ? Term.cardHover : Term.card)
        .overlay(
            RoundedRectangle(cornerRadius: 4).stroke(hovering ? Term.amber.opacity(0.35) : Term.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy", action: copy)
            if let raw = entry.rawText {
                Button("Copy What Was Heard") { TextInserter.copyToClipboard(raw) }
            }
            if let app = controller.lastExternalApp?.localizedName {
                Button("Paste into \(app)") { controller.pasteIntoLastApp(entry.text) }
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func copy() {
        TextInserter.copyToClipboard(entry.text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

private struct EmptyFeed: View {
    let choice: HotkeyChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 24, weight: .semibold)).foregroundStyle(Term.amber)
                Text("NO DICTATIONS YET").font(.termHeader).foregroundStyle(Term.amber)
            }
            Text("Hold \(choice.shortLabel), speak, then let go. The transcript lands in whatever app has focus, and shows up here.")
                .font(.termBody).foregroundStyle(Term.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Term.border, lineWidth: 1))
        .padding(.top, 12)
    }
}

private struct ControlPanel: View {
    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "STATUS")
                HStack(spacing: 10) {
                    Circle().fill(controller.statusLine.color).frame(width: 10, height: 10)
                        .shadow(color: controller.statusLine.color, radius: controller.phase == .listening ? 6 : 2)
                    HStack(spacing: 0) {
                        Text(controller.statusLine.text).font(.mono(15, .bold)).foregroundStyle(controller.statusLine.color)
                        if controller.phase == .idle && controller.modelState.isReady {
                            Blink().foregroundStyle(controller.statusLine.color)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)

                SectionHeader(title: "MIC LEVEL")
                VStack(alignment: .leading, spacing: 8) {
                    Meter(level: controller.liveLevel).frame(height: 22)
                    HStack {
                        TermButton(title: controller.isTestingMic ? "STOP TEST" : "TEST MIC",
                                   color: controller.isTestingMic ? Term.red : Term.green,
                                   action: controller.toggleMicTest)
                        Spacer()
                        if controller.isTestingMic, controller.micTestPeakDb > -100 {
                            let gap = controller.micTestPeakDb - controller.micTestNoiseDb
                            Text("VOICE +\(Int(gap.rounded()))dB").font(.termSmall).foregroundStyle(gapColor(gap))
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                SectionHeader(title: "INPUT")
                VStack(alignment: .leading, spacing: 7) {
                    KV(key: "DEVICE", value: controller.activeMicName.uppercased(), keyWidth: 62)
                    if let gap = controller.recentSeparationDb {
                        KV(key: "VOICE/ROOM", value: "+\(Int(gap.rounded())) dB", color: gapColor(gap), keyWidth: 62)
                        Text(gap >= 25 ? "GOOD SEPARATION." : "LOW. MOVE CLOSER TO THE MIC.")
                            .font(.termSmall).foregroundStyle(gap >= 25 ? Term.dim : Term.amber)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                SectionHeader(title: "KEYBOARD SHORTCUTS")
                VStack(alignment: .leading, spacing: 6) {
                    shortcut("HOLD \(controller.hotkeyChoice.symbol)", "dictate")
                    shortcut("ESC", "cancel while holding")
                    shortcut("⌘,", "settings")
                    shortcut("⌘Q", "quit keet")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(Term.black)
    }

    private func gapColor(_ gap: Float) -> Color { gap >= 30 ? Term.green : (gap >= 20 ? Term.amber : Term.red) }

    private func shortcut(_ key: String, _ description: String) -> some View {
        HStack {
            Text(key).font(.termBody).foregroundStyle(Term.cyan).frame(width: 76, alignment: .leading)
            Text(description).font(.termSmall).foregroundStyle(Term.dim)
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @ObservedObject var controller: AppController
    @ObservedObject var dictionary: DictionaryStore
    @State private var word = ""
    @State private var heardAs = ""
    @State private var query = ""
    @State private var problem: String?

    private var filtered: [DictionaryWord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return dictionary.words }
        return dictionary.words.filter {
            $0.text.localizedCaseInsensitiveContains(q) || $0.heardAs.joined(separator: " ").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "ADD A WORD")
                VStack(alignment: .leading, spacing: 8) {
                    Text("WORD").font(.termSmall).foregroundStyle(Term.dim)
                    TermField(placeholder: "ZipLyne", text: $word, onSubmit: add)
                    Text("USUALLY HEARD AS (OPTIONAL)").font(.termSmall).foregroundStyle(Term.dim).padding(.top, 4)
                    TermField(placeholder: "zip line, zipline", text: $heardAs, onSubmit: add)
                    HStack {
                        TermButton(title: "ADD WORD", color: Term.green, action: add)
                        Spacer()
                    }
                    .padding(.top, 4)
                    if let problem {
                        Text(problem.uppercased()).font(.termSmall).foregroundStyle(Term.red)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)

                SectionHeader(title: "WORD SPOTTER")
                VStack(alignment: .leading, spacing: 7) {
                    KV(key: "STATE", value: stateText.value, color: stateText.color, keyWidth: 70)
                    KV(key: "MODEL", value: "PARAKEET CTC 110M", keyWidth: 70)
                    KV(key: "COST", value: "~120 MS / DICTATION", color: Term.amber, keyWidth: 70)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                SectionHeader(title: "HOW IT WORKS")
                Text("Names, companies and jargon the model has never heard. A heard word is swapped for yours only when it looks alike and the audio backs it up, so everyday words stay put. Words need 3+ letters.")
                    .font(.termSmall).foregroundStyle(Term.dim).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                Spacer()
            }
            .frame(width: 320)
            .background(Term.black)

            Rectangle().fill(Term.border).frame(width: 1)

            VStack(spacing: 0) {
                SectionHeader(title: "DICTIONARY", trailing: AnyView(
                    Text("\(dictionary.words.count) WORDS").font(.termSmall).foregroundStyle(Term.dim)))
                TermField(placeholder: "filter words", text: $query)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Term.strip)
                Rectangle().fill(Term.border).frame(height: 1)
                HStack {
                    Text("WORD").frame(width: 240, alignment: .leading)
                    Text("HEARD AS")
                    Spacer()
                }
                .font(.termSmall.weight(.bold)).foregroundStyle(Term.dim)
                .padding(.horizontal, 24).padding(.vertical, 6)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            WordRow(entry: entry) { dictionary.remove(entry.id) }
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Term.black)
        }
    }

    private var stateText: (value: String, color: Color) {
        switch controller.dictionaryState {
        case .empty: return ("OFF · ADD A WORD", Term.dim)
        case .preparing(let first): return (first ? "DOWNLOADING MODEL…" : "LOADING…", Term.amber)
        case .active(let n): return ("ACTIVE · \(n) WORDS", Term.green)
        case .failed: return ("FAILED", Term.red)
        }
    }

    private func add() {
        let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count >= 3 else {
            problem = "Words need at least 3 letters."
            return
        }
        problem = nil
        dictionary.add(text, heardAs: heardAs.split(separator: ",").map(String.init))
        word = ""
        heardAs = ""
    }
}

private struct WordRow: View {
    let entry: DictionaryWord
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(entry.text).font(.termBody.weight(.semibold)).foregroundStyle(Term.green)
                .frame(width: 240, alignment: .leading)
            Text(entry.heardAs.isEmpty ? "--" : entry.heardAs.joined(separator: ", "))
                .font(.termSmall).foregroundStyle(entry.heardAs.isEmpty ? Term.faint : Term.dim)
                .lineLimit(1)
            Spacer()
            TermButton(title: "DEL", color: Term.red, action: onDelete).opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(hovering ? Term.cardHover : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Term.border.opacity(0.6)).frame(height: 1) }
        .onHover { hovering = $0 }
    }
}

// MARK: - Settings

private struct SettingsTab: View {
    @ObservedObject var controller: AppController
    @ObservedObject var history: HistoryStore
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var inputVolume: Float?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "DICTATION KEY")
                    keyPicker.padding(.horizontal, 14).padding(.vertical, 12)
                    SectionHeader(title: "MICROPHONE")
                    microphone.padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(Term.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "GENERAL")
                    VStack(spacing: 10) {
                        toggle("START SOUND", "Chime when Keet starts hearing you", $controller.startSoundOn)
                        toggle("AI CLEANUP", "Drop um, uh, filler like and repeats", $controller.aiCleanup)
                        toggle("LIVE WORDS", "Show words in the pill while you talk", $controller.livePreview)
                        toggle("OPEN AT LOGIN", "Start Keet when you log in", $openAtLogin)
                            .onChange(of: openAtLogin) { _, on in
                                do {
                                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                } catch {
                                    openAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                        toggle("KEEP HISTORY", "Save dictations on this Mac", $history.keepOnDisk)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)

                    SectionHeader(title: "PERMISSIONS")
                    TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                        VStack(spacing: 8) {
                            permission("MICROPHONE", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                                       "Privacy_Microphone")
                            permission("ACCESSIBILITY", AXIsProcessTrusted(), "Privacy_Accessibility")
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)

                    SectionHeader(title: "SPEECH MODEL")
                    VStack(alignment: .leading, spacing: 7) {
                        KV(key: "MODEL", value: "PARAKEET UNIFIED 0.6B EN")
                        KV(key: "MADE BY", value: "NVIDIA · CORE ML BY FLUIDINFERENCE")
                        KV(key: "RUNS ON", value: "NEURAL ENGINE VIA FLUIDAUDIO", color: Term.green)
                        KV(key: "STATUS", value: modelStatus, color: Term.amber)
                        HStack {
                            TermButton(title: "SHOW IN FINDER", color: Term.cyan) {
                                NSWorkspace.shared.activateFileViewerSelecting([Transcriber.modelDirectory])
                            }
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)

                    SectionHeader(title: "AI CLEANUP")
                    VStack(alignment: .leading, spacing: 7) {
                        KV(key: "MODEL", value: "APPLE FOUNDATION MODEL")
                        KV(key: "RUNS ON", value: "THIS MAC · APPLE INTELLIGENCE", color: Term.green)
                        KV(key: "STATUS", value: cleanupStatus, color: controller.cleanupAvailability == .ready ? Term.amber : Term.red)
                        Text("THE MODEL SUGGESTS EDITS; KEET KEEPS ONLY SAFE ONES: FILLERS, REPEATS, NEAR-SOUNDING WORD FIXES, PUNCTUATION. IT NEVER DROPS, ADDS, OR REORDERS YOUR WORDS. SKIPPED WHEN THERE'S NOTHING TO REMOVE, AND OVER 100 WORDS.")
                            .font(.termSmall).foregroundStyle(Term.dim).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                        if controller.cleanupAvailability == .appleIntelligenceOff {
                            HStack {
                                TermButton(title: "OPEN APPLE INTELLIGENCE SETTINGS", color: Term.cyan) {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)

                    SectionHeader(title: "ABOUT")
                    VStack(alignment: .leading, spacing: 7) {
                        KV(key: "LICENSE", value: "MIT · OPEN SOURCE", color: Term.green)
                        Link(destination: URL(string: "https://github.com/ZipLyne-Agency/keet")!) {
                            Text("GITHUB.COM/ZIPLYNE-AGENCY/KEET ↗").font(.termSmall).foregroundStyle(Term.cyan)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
            .frame(width: 400)
        }
        .background(Term.black)
    }

    private var cleanupStatus: String {
        switch controller.cleanupAvailability {
        case .ready: return controller.aiCleanup ? "ON" : "OFF"
        case .appleIntelligenceOff: return "TURN ON APPLE INTELLIGENCE"
        case .modelNotReady: return "APPLE MODEL DOWNLOADING"
        case .deviceNotEligible: return "NOT SUPPORTED ON THIS MAC"
        case .needsNewerMacOS: return "NEEDS MACOS 26"
        case .unavailable: return "UNAVAILABLE"
        }
    }

    private var keyPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                    let selected = controller.hotkeyChoice == choice
                    Button { controller.setHotkey(choice) } label: {
                        VStack(spacing: 5) {
                            Text(choice.symbol).font(.mono(20, .bold))
                            Text(choice.title.uppercased()).font(.termSmall)
                        }
                        .foregroundStyle(selected ? Term.amber : Term.dim)
                        .frame(maxWidth: .infinity).frame(height: 62)
                        .background(selected ? Term.amber.opacity(0.08) : Term.card)
                        .overlay(Rectangle().stroke(selected ? Term.amber : Term.border, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("HOLD TO TALK, LET GO TO INSERT. ESC CANCELS.").font(.termSmall).foregroundStyle(Term.dim)
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 0) {
            micRow(nil, "AUTOMATIC", "follows system · \(controller.systemDefaultMic?.name ?? "none")")
            ForEach(controller.inputDevices) { device in
                micRow(device.uid, device.name.uppercased(), transport(device))
            }
            if let volume = inputVolume {
                HStack(spacing: 10) {
                    Text("INPUT VOL").font(.termSmall).foregroundStyle(Term.dim).frame(width: 70, alignment: .leading)
                    Slider(value: Binding(get: { Double(volume) },
                                          set: { inputVolume = Float($0); controller.setInputVolume(Float($0)) }), in: 0...1)
                        .tint(Term.amber)
                    Text("\(Int((volume * 100).rounded()))%").font(.termSmall).foregroundStyle(Term.amber)
                        .frame(width: 38, alignment: .trailing)
                }
                .padding(.top, 14)
            }
            HStack(spacing: 10) {
                TermButton(title: controller.isTestingMic ? "STOP" : "TEST", color: controller.isTestingMic ? Term.red : Term.green,
                           action: controller.toggleMicTest)
                Meter(level: controller.micTestLevel).frame(height: 14)
                if controller.isTestingMic, controller.micTestPeakDb > -100 {
                    let gap = controller.micTestPeakDb - controller.micTestNoiseDb
                    Text("+\(Int(gap.rounded()))dB").font(.termSmall)
                        .foregroundStyle(gap >= 30 ? Term.green : (gap >= 20 ? Term.amber : Term.red))
                        .frame(width: 50, alignment: .trailing)
                }
            }
            .padding(.top, 12)
            Text("TALK NORMALLY DURING THE TEST. AIM FOR YOUR VOICE +30 dB OVER THE ROOM. CLOSER BEATS LOUDER: RAISING INPUT VOLUME LIFTS THE NOISE TOO.")
                .font(.termSmall).foregroundStyle(Term.dim).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .onAppear { inputVolume = controller.inputVolume() }
        .onChange(of: controller.selectedMicUID) { _, _ in inputVolume = controller.inputVolume() }
        .onChange(of: controller.systemDefaultMic) { _, _ in inputVolume = controller.inputVolume() }
    }

    private func micRow(_ uid: String?, _ name: String, _ detail: String) -> some View {
        let selected = controller.selectedMicUID == uid
        return Button { controller.selectMicrophone(uid: uid) } label: {
            HStack(spacing: 10) {
                Text(selected ? "●" : "○").font(.termBody).foregroundStyle(selected ? Term.green : Term.faint)
                Text(name).font(.termBody.weight(selected ? .bold : .regular))
                    .foregroundStyle(selected ? Term.green : Term.text)
                Spacer()
                Text(detail.uppercased()).font(.termSmall).foregroundStyle(Term.dim).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(selected ? Term.green.opacity(0.06) : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Term.border.opacity(0.6)).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func transport(_ device: InputDevice) -> String {
        switch device.transport {
        case .builtIn: "built in"
        case .bluetooth: "bluetooth"
        case .usb: "usb"
        case .virtual: "virtual"
        case .other: "external"
        }
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.termBody).foregroundStyle(Term.text)
                Text(detail).font(.termSmall).foregroundStyle(Term.dim)
            }
            Spacer()
            HStack(spacing: 0) {
                segment("ON", isOn.wrappedValue, Term.green) { isOn.wrappedValue = true }
                segment("OFF", !isOn.wrappedValue, Term.dim) { isOn.wrappedValue = false }
            }
            .overlay(Rectangle().stroke(Term.border, lineWidth: 1))
        }
    }

    private func segment(_ title: String, _ active: Bool, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.termSmall.weight(.bold))
                .foregroundStyle(active ? Term.black : Term.faint)
                .frame(width: 38, height: 20)
                .background(active ? color : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func permission(_ name: String, _ granted: Bool, _ pane: String) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.termBody).foregroundStyle(Term.text)
            Spacer()
            if granted {
                Text("GRANTED").font(.termSmall.weight(.bold)).foregroundStyle(Term.green)
            } else {
                Text("NEEDED").font(.termSmall.weight(.bold)).foregroundStyle(Term.red)
                TermButton(title: "ALLOW", color: Term.amber) {
                    if pane == "Privacy_Microphone", AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    }
                }
            }
        }
    }

    private var modelStatus: String {
        switch controller.modelState {
        case .loading: "LOADING…"
        case .ready(let ms): "READY · LOADED IN \(ms)MS"
        case .failed: "FAILED TO LOAD"
        }
    }
}

// MARK: - Shared labels

extension HotkeyChoice {
    /// "L⌥ OPTION" style label for the terminal UI.
    var shortLabel: String {
        switch self {
        case .leftOption: "L⌥ OPTION"
        case .rightOption: "R⌥ OPTION"
        case .rightCommand: "R⌘ COMMAND"
        case .fn: "FN GLOBE"
        }
    }
}

extension AppController {
    var permissionsGranted: Bool {
        AXIsProcessTrusted() && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// The one-word status shown in the header, status panel and bar.
    var statusLine: (text: String, color: Color) {
        switch phase {
        case .listening: return ("LISTENING", Term.red)
        case .transcribing: return ("TRANSCRIBING", Term.amber)
        case .idle: break
        }
        switch modelState {
        case .loading: return ("LOADING", Term.amber)
        case .failed: return ("MODEL ERROR", Term.red)
        case .ready: return permissionsGranted ? ("READY", Term.green) : ("PERMISSION", Term.amber)
        }
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
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Keet"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(Term.black)
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 1080, height: 640)
            window.contentView = NSHostingView(rootView: MainView(controller: controller, history: controller.history))
            window.setFrameAutosaveName("KeetMainWindowTerminal")
            if !window.setFrameUsingName("KeetMainWindowTerminal") { window.center() }
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
                      appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", audioSeconds: 3.4, latencyMs: 512,
                      delivery: .pasted, peakDb: -24, noiseDb: -58, tailMs: 150, transcribeMs: 58,
                      rawText: "Can you like send me the the latest numbers before the meeting this afternoon?",
                      cleanupMs: 296),
            Dictation(date: ago(9), text: "Let's move the standup to 10:30 and skip the retro this week.",
                      appName: "Messages", bundleID: "com.apple.MobileSMS", audioSeconds: 2.9, latencyMs: 168,
                      delivery: .pasted, peakDb: -22, noiseDb: -57, tailMs: 110, transcribeMs: 52),
            Dictation(date: ago(31), text: "Honestly the new design looks great, but the spacing on the settings page feels a little tight. Can we give the cards more room and bring the headings closer to their content?",
                      appName: "Notes", bundleID: "com.apple.Notes", audioSeconds: 9.8, latencyMs: 301,
                      delivery: .pasted, peakDb: -26, noiseDb: -56, tailMs: 190, transcribeMs: 96),
            Dictation(date: ago(47), text: "Book a table for four people at seven.",
                      appName: "Finder", bundleID: "com.apple.finder", audioSeconds: 2.2, latencyMs: 97,
                      delivery: .card, peakDb: -25, noiseDb: -57, tailMs: 40, transcribeMs: 44),
            Dictation(date: ago(66), text: "Ship the ZipLyne proposal once HotLyne is updated.",
                      appName: "Mail", bundleID: "com.apple.mail", audioSeconds: 3.1, latencyMs: 245,
                      delivery: .pasted, peakDb: -23, noiseDb: -58, tailMs: 120, transcribeMs: 160),
            Dictation(date: ago(60 * 26), text: "Make sure the tests pass before you merge it, and tag me on the pull request.",
                      appName: "Mail", bundleID: "com.apple.mail", audioSeconds: 4.1, latencyMs: 140,
                      delivery: .pasted, peakDb: -24, noiseDb: -57, tailMs: 60, transcribeMs: 62),
        ]
    }

    static func render(to directory: URL, controller: AppController) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tabs: [(MainView.Tab, String)] = [(.feed, "feed"), (.dictionary, "dictionary"), (.settings, "settings")]
        var windows: [NSWindow] = []
        for (tab, name) in tabs {
            let view = NSHostingView(rootView: MainView(controller: controller, history: controller.history, tab: tab))
            let frame = NSRect(x: -20_000, y: -20_000, width: 1200, height: 740)
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
        OverlayController.renderPreview(to: directory.appendingPathComponent("pill.png")) { model in
            model.phase = .listening
            model.levels = [0.8, 0.6, 0.9, 0.4, 0.5, 0.3]
        }
        OverlayController.renderPreview(to: directory.appendingPathComponent("card.png"), height: 220) { model in
            model.cardNote = "No text field selected"
            model.phase = .result("Book a table for four people at seven, and ask them for the corner by the window.")
        }
        OverlayController.renderPreview(to: directory.appendingPathComponent("pill-live.png")) { model in
            model.phase = .listening
            model.levels = [0.8, 0.6, 0.9, 0.4, 0.5, 0.3]
            model.liveText = "so the idea is that the words show up right here while you're still talking, and the newest ones stay"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            windows.forEach { $0.orderOut(nil) }
            NSApp.terminate(nil)
        }
    }
}
