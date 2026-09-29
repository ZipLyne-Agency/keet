import AppKit
import SwiftUI
import os

private let overlayLog = Logger(subsystem: "agency.ziplyne.keet", category: "overlay")

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening
        case transcribing
        case result(String)
    }

    @Published var phase: Phase = .hidden
    /// Recent loudness, newest first. The pill mirrors it outward from the center.
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 6)
    /// Per-bar variation so the wave looks like a voice rather than a level meter.
    @Published var jitter: [CGFloat] = Array(repeating: 1, count: 11)
    @Published var copied = false
    /// Words heard so far, shown in the pill while you talk.
    @Published var liveText = ""
    /// Heading on the Copy card.
    @Published var cardNote = "No text field selected"
    /// When the key went down, for the timer in the pill.
    @Published var startedAt = Date()
    /// When the key came up; the timer stops there.
    @Published var stoppedAt: Date?

    func push(level: CGFloat) {
        var next = levels
        next.removeLast()
        next.insert(level, at: 0)
        levels = next
        jitter = jitter.map { _ in CGFloat.random(in: 0.62...1) }
    }

    func resetLevels() { levels = Array(repeating: 0, count: levels.count) }
}

// MARK: - Views

private struct Waveform: View {
    let levels: [CGFloat]
    let jitter: [CGFloat]
    var bars = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                let distance = abs(i - bars / 2)
                let level = levels[min(distance, levels.count - 1)]
                let envelope = 1 - CGFloat(distance) * 0.12
                Capsule(style: .continuous)
                    .fill(Term.green)
                    .frame(width: 3, height: 4 + 19 * level * envelope * jitter[i])
            }
        }
        .animation(.interpolatingSpring(stiffness: 600, damping: 28), value: levels)
    }
}

/// Witzper's pulsing red "recording" dot.
private struct RecordingDot: View {
    let active: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(active ? Term.red : Term.amber)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.35 : 1)
            .shadow(color: (active ? Term.red : Term.amber).opacity(0.8), radius: 3)
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { dim = true } }
    }
}

/// How long you've been talking: 0:07, 1:42, 12:03.
private struct Elapsed: View {
    let start: Date
    let end: Date?

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(Self.format((end ?? context.date).timeIntervalSince(start)))
                .font(.mono(11, .semibold))
                .monospacedDigit()
                .foregroundStyle(end == nil ? Term.text : Term.dim)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { i in
                    let wave = max(0, sin(t * 10 - Double(i) * 0.75))
                    Circle()
                        .fill(Term.amber)
                        .frame(width: 4, height: 4)
                        .opacity(0.3 + 0.7 * wave)
                        .scaleEffect(0.85 + 0.35 * wave)
                }
            }
        }
    }
}

private struct Pill: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        Group {
            if model.liveText.isEmpty {
                compact
            } else {
                caption
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .animation(.easeOut(duration: 0.15), value: model.phase)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.liveText.isEmpty)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: captionWidth)
    }

    private var indicator: some View {
        ZStack {
            if model.phase == .transcribing {
                ThinkingDots().transition(.opacity)
            } else {
                Waveform(levels: model.levels, jitter: model.jitter, bars: model.liveText.isEmpty ? 9 : 7)
                    .transition(.opacity)
            }
        }
    }

    private var compact: some View {
        HStack(spacing: 9) {
            RecordingDot(active: model.phase == .listening)
            indicator
            Elapsed(start: model.startedAt, end: model.stoppedAt)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        // The border is a filled capsule behind a 1-point-smaller one: stroking a capsule
        // this short leaves small ticks at its ends.
        .background(Capsule().fill(Term.black.opacity(0.96)).padding(1).background(Capsule().fill(Term.border)))
    }

    /// Hugs short phrases and grows with the words, up to two lines at full width.
    private var captionWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let ideal = (model.liveText as NSString).size(withAttributes: [.font: font]).width + 4
        return min(max(ideal, 60), OverlayController.captionTextWidth)
    }

    /// The pill grown into a caption: waveform on the left, newest words on the right.
    private var caption: some View {
        HStack(spacing: 12) {
            RecordingDot(active: model.phase == .listening)
            indicator.frame(width: 44, height: 24)
            Elapsed(start: model.startedAt, end: model.stoppedAt)
            Text(model.liveText)
                .font(.mono(13, .medium))
                .foregroundStyle(Term.green)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(width: captionWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeOut(duration: 0.12), value: model.liveText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Term.black.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Term.border, lineWidth: 1))
        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
    }
}

private struct ResultCard: View {
    let text: String
    @ObservedObject var model: OverlayModel
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Term.amber).frame(width: 6, height: 6)
                Text(model.cardNote.uppercased())
                    .font(.mono(10, .bold))
                    .foregroundStyle(Term.amber)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Text("×").font(.mono(13, .bold)).foregroundStyle(Term.dim)
                        .frame(width: 20, height: 20)
                        .overlay(Rectangle().stroke(Term.border, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Group {
                if text.count > 280 {
                    ScrollView { transcript(text) }.frame(height: 150)
                } else {
                    transcript(text)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onCopy)

            HStack {
                Text("CLICK THE TEXT OR PRESS COPY").font(.mono(9)).foregroundStyle(Term.faint)
                Spacer()
                Button(action: onCopy) {
                    Text(model.copied ? "COPIED" : "COPY")
                        .font(.mono(11, .bold))
                        .foregroundStyle(model.copied ? Term.black : Term.amber)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(model.copied ? Term.green : Color.clear)
                        .overlay(Rectangle().stroke(model.copied ? Term.green : Term.amber, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.15), value: model.copied)
            }
        }
        .padding(14)
        .frame(width: ResultCard.width)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Term.black.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Term.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }

    static let width: CGFloat = 400

    private func transcript(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("▸").font(.mono(12)).foregroundStyle(Term.green.opacity(0.7))
            Text(text)
                .font(.mono(13))
                .lineSpacing(3)
                .foregroundStyle(Term.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OverlayRoot: View {
    @ObservedObject var model: OverlayModel
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            switch model.phase {
            case .hidden:
                Color.clear
            case .listening, .transcribing:
                Pill(model: model)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.55, anchor: .bottom).combined(with: .opacity),
                            removal: .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity)))
            case .result(let text):
                ResultCard(text: text, model: model, onCopy: onCopy, onClose: onClose)
                    .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, OverlayController.margin)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: model.phase)
    }
}

// MARK: - Window

private final class OverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating indicator at the bottom center of the screen you're working on.
@MainActor
final class OverlayController {
    static let margin: CGFloat = 16
    static let captionTextWidth: CGFloat = 460
    /// The listening panel is sized for the widest caption up front, so the pill can
    /// grow without the window resizing. It ignores the mouse, so the empty part of it
    /// never blocks clicks.
    static let listeningSize = NSSize(width: captionTextWidth + 44 + 12 + 32 + 2 * margin + 40, height: 140)

    let model = OverlayModel()
    var onCopy: (String) -> Void = { _ in }

    /// One panel per screen, all showing the same model, so the pill is visible on
    /// whichever display you're looking at. (Following only the focused window's
    /// screen hid it entirely when that display couldn't show floating windows.)
    private var panels: [OverlayPanel] = []
    private var orderOutWork: DispatchWorkItem?
    private var dismissTimer: Timer?

    /// A panel created while a Space is active lands in that Space, so each
    /// appearance gets a fresh one rather than reusing a window that may belong
    /// to a Space you've since left.
    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel()
        let root = OverlayRoot(
            model: model,
            onCopy: { [weak self] in self?.copyResult() },
            onClose: { [weak self] in self?.hide() })
        panel.contentView = FirstMouseHostingView(rootView: root)
        return panel
    }

    var isShowingResult: Bool {
        if case .result = model.phase { return true }
        return false
    }

    func showListening(since start: Date = Date()) {
        dismissTimer?.invalidate()
        model.resetLevels()
        model.liveText = ""
        model.startedAt = start
        model.stoppedAt = nil
        present(size: Self.listeningSize, interactive: false)
        model.phase = .listening
    }

    func showTranscribing() {
        guard model.phase == .listening else { return }
        model.stoppedAt = Date()
        model.phase = .transcribing
    }

    func setLiveText(_ text: String) {
        guard model.phase == .listening || model.phase == .transcribing else { return }
        model.liveText = text
    }

    func showResult(_ text: String, note: String = "No text field selected") {
        model.copied = false
        model.cardNote = note
        model.liveText = ""
        let measure = NSHostingView(
            rootView: ResultCard(text: text, model: model, onCopy: {}, onClose: {}))
        let fitting = measure.fittingSize
        present(size: NSSize(width: fitting.width + 2 * Self.margin, height: fitting.height + 2 * Self.margin),
                interactive: true)
        model.phase = .result(text)
        scheduleDismiss(after: 12)
    }

    func hide() {
        dismissTimer?.invalidate()
        guard model.phase != .hidden else { return }
        model.phase = .hidden
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.phase == .hidden else { return }
            self.panels.forEach { $0.orderOut(nil) }
            self.panels = []
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func push(level: Float) {
        guard model.phase == .listening else { return }
        model.push(level: CGFloat(level))
    }

    private func copyResult() {
        guard case .result(let text) = model.phase else { return }
        onCopy(text)
        model.copied = true
        scheduleDismiss(after: 1.1, force: true)
    }

    private func scheduleDismiss(after seconds: TimeInterval, force: Bool = false) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Keep the card while the pointer rests on it.
                if !force, self.panels.contains(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
                    self.scheduleDismiss(after: 2)
                } else {
                    self.hide()
                }
            }
        }
    }

    private func present(size: NSSize, interactive: Bool) {
        orderOutWork?.cancel()
        var screens = NSScreen.screens
        if let forced = ProcessInfo.processInfo.environment["KEET_TEST_SCREEN"].flatMap(Int.init),
           screens.indices.contains(forced) {
            screens = [screens[forced]]
        }
        if panels.count != screens.count {
            panels.forEach { $0.orderOut(nil) }
            panels = screens.map { _ in makePanel() }
        }
        for (panel, screen) in zip(panels, screens) {
            let visible = screen.visibleFrame
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 6)
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
            panel.ignoresMouseEvents = !interactive
            panel.orderFrontRegardless()
        }
        overlayLog.notice("present on \(screens.count) screens, \(Int(size.width))x\(Int(size.height))")
    }
}

// MARK: - Snapshots

extension OverlayController {
    /// Renders the overlay in a given state off screen (design review, docs).
    static func renderPreview(to url: URL, height: CGFloat = 140, configure: (OverlayModel) -> Void) {
        let model = OverlayModel()
        configure(model)
        let view = NSHostingView(rootView: OverlayRoot(model: model, onCopy: {}, onClose: {}))
        let size = NSSize(width: listeningSize.width, height: height)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(white: 0.42, alpha: 1)
        window.contentView = view
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            window.orderOut(nil)
        }
    }
}
