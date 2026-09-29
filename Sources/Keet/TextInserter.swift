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
    // Native terminals take pasted text even when their accessibility role is unusual.
    // Web-based ones (Orca, Hyper) aren't listed: their terminal input is a real text
    // field (xterm.js's helper textarea), so the web rules below find it.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty",
    ]

    /// What focus looked like at the last `currentTarget()`, for the log. Never text.
    private(set) var lastFocus = ""

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
        guard let app = NSWorkspace.shared.frontmostApplication else {
            lastFocus = "no frontmost app"
            return .unknown
        }
        let bundleID = app.bundleIdentifier ?? "?"
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        var focused: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        if err != .success {
            err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        }
        guard err == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            lastFocus = "\(bundleID), no focused element (\(err.rawValue))"
            if Self.terminalBundleIDs.contains(bundleID) { return .editable(needsLeadingSpace: false) }
            // Finder with nothing selected and similar cases answer "no value": nothing to type into.
            return err == .noValue ? .notEditable : .unknown
        }
        return classify(focused as! AXUIElement, bundleID: bundleID)
    }

    /// Whether this focused element takes typing.
    func classify(_ element: AXUIElement, bundleID: String) -> Target {
        let names = attributeNames(element)
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        // Chrome, Electron apps (Orca, Codex, Cursor, Slack) and Safari tag their
        // elements with DOM attributes.
        let isWeb = names.contains("AXDOMClassList") || names.contains("AXDOMIdentifier") || role == "AXWebArea"
        lastFocus = "\(bundleID), \(role.isEmpty ? "no role" : role)\(isWeb ? " (web)" : "")"

        if Self.textRoles.contains(role) {
            return .editable(needsLeadingSpace: needsLeadingSpace(element))
        }
        if isWeb {
            // Chromium advertises a caret and a settable value on nearly every element:
            // in Orca and Chrome, 157 of 158 groups, 84 of 87 buttons, every table cell.
            // Only a text role (above) or being inside an editable region counts, which
            // is how a rich text box (contenteditable) shows up.
            return isInEditableRegion(element, names)
                ? .editable(needsLeadingSpace: needsLeadingSpace(element)) : .notEditable
        }
        if Self.terminalBundleIDs.contains(bundleID) {
            return .editable(needsLeadingSpace: false)
        }
        if Self.nonTextValueRoles.contains(role) || Self.nonTextRoles.contains(role) {
            return .notEditable
        }
        if isInEditableRegion(element, names) {
            return .editable(needsLeadingSpace: needsLeadingSpace(element))
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .editable(needsLeadingSpace: needsLeadingSpace(element))
        }
        // In native apps, anything that can take typing advertises a caret. A generic
        // group without one (the Finder desktop, a canvas, a sidebar) gets the Copy card.
        if names.contains(kAXSelectedTextRangeAttribute) {
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

    /// A rich text box (contenteditable) and everything inside it point to the box
    /// through AXEditableAncestor; elsewhere the attribute isn't advertised. Only
    /// advertised attributes count: some apps (Finder) answer queries for attributes
    /// they don't list.
    private func isInEditableRegion(_ element: AXUIElement, _ names: Set<String>) -> Bool {
        if names.contains("AXEditableAncestor") {
            var ancestor: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &ancestor) == .success,
               let ancestor, CFGetTypeID(ancestor) == AXUIElementGetTypeID() {
                return true
            }
        }
        if names.contains("AXEditable") {
            var editable: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
               (editable as? Bool) == true {
                return true
            }
        }
        return false
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
