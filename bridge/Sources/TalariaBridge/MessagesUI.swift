import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Reads and focuses the Messages window through the Accessibility API.
///
/// The compose field is located in the window rather than trusted from the
/// keyboard focus. In current Messages it is an AXTextField with the identifier
/// "messageBodyField" (placeholder "iMessage"); the AXTextAreas identified as
/// "CKBalloonTextView" are message bubbles in the transcript and are never used.
enum MessagesUI {
    static let bundleID = "com.apple.MobileSMS"
    static let composeIdentifier = "messageBodyField"
    static let bubbleIdentifier = "CKBalloonTextView"
    private static let maxNodes = 4000

    static func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static func appElement(_ app: NSRunningApplication) -> AXUIElement {
        AXUIElementCreateApplication(app.processIdentifier)
    }

    static func focusedElement(_ app: AXUIElement) -> AXUIElement? {
        element(app, kAXFocusedUIElementAttribute)
    }

    static func frontWindow(_ app: AXUIElement) -> AXUIElement? {
        element(app, kAXFocusedWindowAttribute)
            ?? element(app, kAXMainWindowAttribute)
            ?? (raw(app, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    /// Text inputs in the window, breadth first, search fields excluded.
    static func textInputs(in root: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let node = queue.removeFirst()
            visited += 1
            let role = self.role(node)
            if role == "AXTextArea" || role == "AXTextField", string(node, kAXSubroleAttribute) != "AXSearchField" {
                found.append(node)
            }
            queue.append(contentsOf: children(node))
        }
        return found
    }

    static func composeField(_ app: AXUIElement) -> AXUIElement? {
        guard let window = frontWindow(app) else { return nil }
        let inputs = textInputs(in: window)
        if let exact = inputs.first(where: { identifier($0) == composeIdentifier }) {
            return exact
        }
        // Fallback for other Messages versions: an editable input that isn't a
        // message bubble, the lowest one on screen (the compose field sits at the bottom).
        return inputs
            .filter { identifier($0) != bubbleIdentifier && isEditable($0) }
            .max { (position($0)?.y ?? 0) < (position($1)?.y ?? 0) }
    }

    /// Whether the element's text can be changed, which rules out read-only bubbles.
    static func isEditable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    static func identifier(_ element: AXUIElement) -> String? {
        string(element, "AXIdentifier")
    }

    static func text(_ element: AXUIElement) -> String {
        string(element, kAXValueAttribute) ?? ""
    }

    static func isFocused(_ element: AXUIElement, in app: AXUIElement) -> Bool {
        guard let focused = focusedElement(app) else { return false }
        return CFEqual(focused, element)
    }

    @discardableResult
    static func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Posts one key press straight to Messages (it doesn't have to be frontmost).
    static func press(keyCode: CGKeyCode, character: UniChar?, to pid: pid_t) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { continue }
            if var character {
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            }
            event.postToPid(pid)
        }
    }

    static func describe(_ element: AXUIElement?) -> String {
        guard let element else { return "nothing" }
        var parts = [role(element)]
        if let subrole = string(element, kAXSubroleAttribute) { parts.append(subrole) }
        for (label, attribute) in [("desc", kAXDescriptionAttribute), ("title", kAXTitleAttribute),
                                   ("placeholder", "AXPlaceholderValue"), ("id", "AXIdentifier")] {
            if let value = string(element, attribute), !value.isEmpty { parts.append("\(label)=\"\(value)\"") }
        }
        if let value = string(element, kAXValueAttribute) { parts.append("text=\(value.count) chars") }
        if ["AXTextArea", "AXTextField"].contains(role(element)) {
            parts.append(isEditable(element) ? "editable" : "read-only")
        }
        if let point = position(element) { parts.append("y=\(Int(point.y))") }
        return parts.joined(separator: " ")
    }

    // MARK: attribute access

    static func role(_ element: AXUIElement) -> String {
        string(element, kAXRoleAttribute) ?? "?"
    }

    private static func raw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        raw(element, attribute) as? String
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = raw(parent, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (raw(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func position(_ element: AXUIElement) -> CGPoint? {
        guard let value = raw(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }
}

/// Shows "typing…" by putting a single "." in the Messages compose field.
/// Experimental: depends on the Messages UI, so a macOS update can break it.
///
/// Safety rules: it only types into the compose field it located itself, only when
/// that field is empty (or already holds its own "."), only ever types "." and
/// only ever deletes that same "."; it never presses Return. Key presses go to the
/// Messages process directly, never to whatever app happens to be in front.
public struct UITypingDriver: TypingDriver {
    private static let periodKey: CGKeyCode = 47
    private static let deleteKey: CGKeyCode = 51
    private static let placeholder = "."

    public init() {}

    public func begin(handle: String) async -> Bool {
        guard await openChat(handle) else { return false }
        let result = await typePlaceholder()
        if result != "typed" { Log.warning("typing: did not start (\(result))") }
        return result == "typed"
    }

    public func refresh() async {
        if await clearPlaceholder() == "cleared" {
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = await typePlaceholder()
        }
    }

    public func end() async {
        let result = await clearPlaceholder()
        if result != "cleared" { Log.debug("typing: clear \(result)") }
    }

    /// Whether this process may use Accessibility; `prompt` shows the system dialog.
    @MainActor
    public static func accessibilityTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// Read-only description of what the driver sees, for `talaria-bridge typing --inspect`.
    public func inspect(handle: String?) async -> String {
        if let handle, !(await openChat(handle)) { return "could not open the chat with \(handle)" }
        return await MainActor.run {
            guard let app = MessagesUI.runningApp() else { return "Messages is not running" }
            let ax = MessagesUI.appElement(app)
            let compose = MessagesUI.composeField(ax)
            var lines = [
                "frontmost app : \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")",
                "window        : \(MessagesUI.describe(MessagesUI.frontWindow(ax)))",
                "focused       : \(MessagesUI.describe(MessagesUI.focusedElement(ax)))",
                "compose field : \(MessagesUI.describe(compose))",
                "text inputs in the window:",
            ]
            let inputs = MessagesUI.frontWindow(ax).map(MessagesUI.textInputs) ?? []
            for input in inputs.prefix(40) {
                let marker = compose.map { CFEqual($0, input) } == true ? "  <- compose" : ""
                lines.append("  - \(MessagesUI.describe(input))\(marker)")
            }
            if inputs.isEmpty { lines.append("  (none)") }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: steps

    private func openChat(_ handle: String) async -> Bool {
        guard let url = URL(string: "imessage:" + handle) else { return false }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if !opened { Log.warning("typing: could not open the chat in Messages") }
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // let Messages switch conversations
        return opened
    }

    // All Accessibility work stays on the main actor (AXUIElement can't cross threads);
    // the sleeps suspend without blocking it.

    @MainActor
    private func typePlaceholder() async -> String {
        guard let app = MessagesUI.runningApp() else { return "skipped: Messages is not running" }
        let ax = MessagesUI.appElement(app)
        guard let field = MessagesUI.composeField(ax) else {
            return "skipped: no compose field in the Messages window (focus: \(MessagesUI.describe(MessagesUI.focusedElement(ax))))"
        }
        let current = MessagesUI.text(field)
        if current == Self.placeholder { return "typed" }
        guard current.isEmpty else { return "skipped: the compose field has a draft" }
        if !MessagesUI.isFocused(field, in: ax) {
            MessagesUI.focus(field)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Re-check right before the key press: only an empty, focused compose field gets the ".".
        guard MessagesUI.isFocused(field, in: ax) else {
            return "skipped: could not focus the compose field (focus: \(MessagesUI.describe(MessagesUI.focusedElement(ax))))"
        }
        guard MessagesUI.text(field).isEmpty else { return "skipped: the compose field has a draft" }
        MessagesUI.press(keyCode: Self.periodKey, character: UniChar(UInt8(ascii: ".")), to: app.processIdentifier)

        try? await Task.sleep(nanoseconds: 300_000_000)
        if MessagesUI.text(field) == Self.placeholder { return "typed" }
        return "skipped: Messages ignored the key press (compose field: \(MessagesUI.describe(field)))"
    }

    @MainActor
    private func clearPlaceholder() async -> String {
        guard let app = MessagesUI.runningApp() else { return "skipped: Messages is not running" }
        let ax = MessagesUI.appElement(app)
        guard let field = MessagesUI.composeField(ax), MessagesUI.text(field) == Self.placeholder else {
            return "skipped: no placeholder"
        }
        if !MessagesUI.isFocused(field, in: ax) {
            MessagesUI.focus(field)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Delete only while our "." is the whole text of the focused compose field.
        guard MessagesUI.isFocused(field, in: ax), MessagesUI.text(field) == Self.placeholder else {
            return "skipped: focus moved away from the compose field"
        }
        MessagesUI.press(keyCode: Self.deleteKey, character: nil, to: app.processIdentifier)
        try? await Task.sleep(nanoseconds: 200_000_000)
        return MessagesUI.text(field).isEmpty ? "cleared" : "skipped: the placeholder is still there"
    }
}
