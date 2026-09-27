import AppKit
import ApplicationServices

/// Finds out whether a text field has focus and puts text into it.
final class TextInserter {
    enum Target {
        /// A text field, text view, web input, or terminal has focus.
        case editable(needsLeadingSpace: Bool)
        /// Focus is somewhere that can't take text (desktop, a list, a button).
        case notEditable
        /// The app doesn't answer accessibility queries; paste and also show the card.
        case unknown
    }

    /// Marks the paste keystrokes Keet posts so its own keyboard hook can tell them apart.
    static let syntheticEventTag: Int64 = 0x4B45_4554

    private let systemWide = AXUIElementCreateSystemWide()
    private var primedPIDs = Set<pid_t>()

    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]
    // Controls whose value is settable but aren't places to type.
    private static let nonTextValueRoles: Set<String> = [
        kAXSliderRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXScrollBarRole,
        kAXColorWellRole, kAXIncrementorRole, kAXDisclosureTriangleRole, "AXStepper", "AXSwitch",
        kAXTabGroupRole, kAXRadioGroupRole, kAXMenuButtonRole,
    ]
    // Terminals take pasted text even when their accessibility role is unusual.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty", "com.stablyai.orca",
        "co.zeit.hyper",
    ]

    private var activationObserver: NSObjectProtocol?

    init() {
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.prime(app)
        }
        prime()
    }

    /// Electron and Chromium apps build their accessibility tree only after being
    /// asked. Called whenever an app comes to the front (and again on key press) so
    /// the tree is ready by the time text arrives.
    func prime(_ app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        guard let app else { return }
        let pid = app.processIdentifier
        guard !primedPIDs.contains(pid) else { return }
        primedPIDs.insert(pid)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    func currentTarget() -> Target {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var focused: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        if err != .success {
            err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        }
        if let bundleID = app.bundleIdentifier, Self.terminalBundleIDs.contains(bundleID) {
            return .editable(needsLeadingSpace: false)
        }
        guard err == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            // Finder with nothing selected and similar cases answer "no value": nothing to type into.
            return err == .noValue ? .notEditable : .unknown
        }
        let element = focused as! AXUIElement
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""

        if Self.textRoles.contains(role) || isEditableWebContent(element) {
            return .editable(needsLeadingSpace: needsLeadingSpace(element))
        }
        if Self.nonTextValueRoles.contains(role) || Self.nonTextRoles.contains(role) {
            return .notEditable
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .editable(needsLeadingSpace: needsLeadingSpace(element))
        }
        // Anything that can take typing advertises a caret. A generic group without
        // one (the Finder desktop, a canvas, a sidebar) gets the Copy card.
        if attributeNames(element).contains(kAXSelectedTextRangeAttribute) {
            return .editable(needsLeadingSpace: needsLeadingSpace(element))
        }
        return .notEditable
    }

    // Focus on one of these means there is no caret to type at.
    private static let nonTextRoles: Set<String> = [
        "AXWebArea", kAXButtonRole, "AXLink", kAXListRole, kAXOutlineRole, kAXTableRole, kAXRowRole,
        kAXCellRole, kAXImageRole, kAXStaticTextRole, kAXScrollAreaRole, kAXWindowRole, kAXMenuRole,
        kAXMenuItemRole, kAXMenuBarRole, kAXMenuBarItemRole, kAXToolbarRole, kAXSplitGroupRole, kAXBrowserRole,
        kAXApplicationRole, kAXSheetRole, kAXDrawerRole, kAXGridRole, kAXColumnRole, "AXLayoutArea",
        "AXCollection", "AXDockItem",
    ]

    /// Pastes through the clipboard (the one method every app accepts), then puts
    /// back whatever was on the clipboard before.
    func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Clipboard managers skip items marked transient.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pasteboard.writeObjects([item])
        let ourChange = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = Self.syntheticEventTag
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // If something else was copied in the meantime, leave it alone.
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            guard !saved.isEmpty else { return }
            let items = saved.map { pairs -> NSPasteboardItem in
                let restored = NSPasteboardItem()
                for (type, data) in pairs { restored.setData(data, forType: type) }
                return restored
            }
            pasteboard.writeObjects(items)
        }
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Accessibility helpers

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// contenteditable regions in browsers report generic roles but expose a caret.
    /// Only advertised attributes count: some apps (Finder) answer caret queries
    /// with an empty range on elements that can't hold text at all.
    private func isEditableWebContent(_ element: AXUIElement) -> Bool {
        let names = attributeNames(element)
        if names.contains("AXEditable") {
            var editable: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
               (editable as? Bool) == true {
                return true
            }
        }
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        return role != "AXWebArea"
            && names.contains(kAXSelectedTextRangeAttribute)
            && names.contains(kAXInsertionPointLineNumberAttribute)
    }

    private func attributeNames(_ element: AXUIElement) -> Set<String> {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return Set((names as? [String]) ?? [])
    }

    /// True when the caret sits right after a word or punctuation, so the dictated
    /// text needs a space in front of it.
    private func needsLeadingSpace(_ element: AXUIElement) -> Bool {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return false }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location > 0 else { return false }

        var before = CFRange(location: range.location - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &before) else { return false }
        var charValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, param, &charValue) == .success,
              let char = (charValue as? String)?.last else { return false }
        return !(char.isWhitespace || "([{\"'“‘/-".contains(char))
    }
}
