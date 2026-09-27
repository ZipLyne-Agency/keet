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
    private let bars = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                let distance = abs(i - bars / 2)
                let level = levels[min(distance, levels.count - 1)]
                let envelope = 1 - CGFloat(distance) * 0.12
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.94))
                    .frame(width: 3, height: 4 + 19 * level * envelope * jitter[i])
            }
        }
        .animation(.interpolatingSpring(stiffness: 600, damping: 28), value: levels)
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
                        .fill(.white)
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
        ZStack {
            if model.phase == .transcribing {
                ThinkingDots().transition(.opacity)
            } else {
                Waveform(levels: model.levels, jitter: model.jitter).transition(.opacity)
            }
        }
        .frame(width: 104, height: 32)
        .background(Capsule(style: .continuous).fill(Color(white: 0.06).opacity(0.92)))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }
}

private struct ResultCard: View {
    let text: String
    @ObservedObject var model: OverlayModel
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 10, weight: .semibold))
                Text("No text field selected")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.09)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white.opacity(0.5))

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
                Spacer()
                Button(action: onCopy) {
                    HStack(spacing: 6) {
                        Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                        Text(model.copied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.15), value: model.copied)
            }
        }
        .padding(14)
        .frame(width: ResultCard.width)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.06).opacity(0.94)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.13), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    static let width: CGFloat = 380

    private func transcript(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .lineSpacing(2)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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
    private static let pillSize = NSSize(width: 104 + 2 * margin, height: 32 + 2 * margin)

    let model = OverlayModel()
    var onCopy: (String) -> Void = { _ in }
    /// Where the text is going. Falls back to the screen under the pointer.
    var focusedScreen: () -> NSScreen? = { nil }

    private var panel: OverlayPanel?
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

    func showListening() {
        dismissTimer?.invalidate()
        model.resetLevels()
        present(size: Self.pillSize, interactive: false)
        model.phase = .listening
    }

    func showTranscribing() {
        guard model.phase == .listening else { return }
        model.phase = .transcribing
    }

    func showResult(_ text: String) {
        model.copied = false
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
            self.panel?.orderOut(nil)
            self.panel = nil
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
                if !force, self.panel?.frame.contains(NSEvent.mouseLocation) == true {
                    self.scheduleDismiss(after: 2)
                } else {
                    self.hide()
                }
            }
        }
    }

    private func present(size: NSSize, interactive: Bool) {
        orderOutWork?.cancel()
        var screen = focusedScreen()
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        if let forced = ProcessInfo.processInfo.environment["KEET_TEST_SCREEN"].flatMap(Int.init),
           NSScreen.screens.indices.contains(forced) {
            screen = NSScreen.screens[forced]
        }
        guard let visible = screen?.visibleFrame else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 6)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.ignoresMouseEvents = !interactive
        panel.orderFrontRegardless()
        overlayLog.notice("present \(NSStringFromRect(panel.frame), privacy: .public) activeSpace=\(panel.isOnActiveSpace)")
    }
}
