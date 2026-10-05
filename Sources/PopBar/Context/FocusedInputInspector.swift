import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads what the focused accessibility element is and whether it is safe to
/// treat as an editable text control (scenario 2).
///
/// This is a NEW capability: the upstream app could read a selection but had no
/// general "is this control editable" test. Everything here errs toward the safe
/// answer — an element that cannot be shown to be editable, enabled and
/// non-secure is reported as not editable, so scenario 2 is never entered and
/// nothing is read out of a password box.
enum FocusedInputInspector {

    private static let log = FileLog("FocusedInput")

    /// Attribute names that are not in the public headers but are widely exposed.
    private static let editableAttribute = "AXEditable"

    /// Inspect the focused element (or nil). Cheap AX calls; main thread.
    static func inspect(_ element: AXUIElement?) -> FocusedInputInfo {
        guard let element else { return .unknown }

        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let enabled = boolValue(element, kAXEnabledAttribute) ?? true
        // Tri-state: nil when the app does not expose AXEditable at all.
        let editable = boolValue(element, editableAttribute)
        let selectedTextSettable = isSettable(element, kAXSelectedTextAttribute)
        let valueSettable = isSettable(element, kAXValueAttribute)
        let secure = isSecure(role: role, subrole: subrole)

        // Informational: a text role that did NOT expose the non-standard
        // `AXEditable` attribute — the browser/Electron case. The routing
        // decision is role + writable, never this flag.
        let fallback = !secure && enabled && editable == nil
            && (role.map(FocusedInputInfo.textInputRoles.contains) ?? false)

        let info = FocusedInputInfo(
            role: role, subrole: subrole, enabled: enabled, editable: editable,
            selectedTextSettable: selectedTextSettable, valueSettable: valueSettable,
            isSecure: secure, isBrowserOrElectronFallback: fallback)
        log.debug("focused role=\(role ?? "nil") sub=\(subrole ?? "nil") enabled=\(enabled) editable=\(editable) selSettable=\(selectedTextSettable) valSettable=\(valueSettable) secure=\(secure)")
        return info
    }

    /// Whether the system's secure keyboard entry is active right now. While it
    /// is, the clipboard watcher pauses and the double-tap trigger is disabled.
    static func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// Write `text` into `element` at its caret / selection, or fail.
    ///
    /// Strictly position-correct, in order of preference:
    ///  1. set `AXSelectedText` — replaces the selection, inserts at the caret;
    ///  2. read `AXSelectedTextRange` and `AXValue`, splice `text` into the value
    ///     at that UTF-16 range, and set `AXValue`.
    ///
    /// A blind `AXValue` append is **never** done: if neither the selected-text
    /// write nor a readable caret range is available, this returns false so the
    /// caller takes the safe fallback instead of writing in the wrong place.
    static func writeText(_ text: String, to element: AXUIElement) -> Bool {
        let info = inspect(element)
        guard info.enabled, !info.isSecure, !text.isEmpty else { return false }

        // 1) The selected-text attribute. Works for both "replace selection" and
        //    "insert at caret" in the apps that expose it.
        if isSettable(element, kAXSelectedTextAttribute),
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return true
        }

        // 2) Position-correct value splice. Both the text and the caret/selection
        //    range must be readable; otherwise we cannot know where to insert.
        guard isSettable(element, kAXValueAttribute),
              let existing = string(element, kAXValueAttribute),
              let range = selectedRange(of: element),
              let combined = TextInsertion.insert(text, into: existing, atUTF16: range) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, combined as CFString) == .success
    }

    /// Whether two AX element references name the same element.
    ///
    /// `CFEqual` is the primary test. An app that returns a fresh object for
    /// every query is then matched on pid + role/subrole/identifier + geometry +
    /// selected range; when geometry is unavailable a real identifier is
    /// required, so two anonymous controls are never confused.
    static func isSameElement(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        guard let a, let b else { return false }
        if CFEqual(a, b) { return true }

        var pidA: pid_t = 0, pidB: pid_t = 0
        guard AXUIElementGetPid(a, &pidA) == .success,
              AXUIElementGetPid(b, &pidB) == .success, pidA == pidB else { return false }

        guard string(a, kAXRoleAttribute) == string(b, kAXRoleAttribute),
              string(a, kAXSubroleAttribute) == string(b, kAXSubroleAttribute) else { return false }

        let idA = string(a, "AXIdentifier") ?? string(a, "AXDOMIdentifier")
        let idB = string(b, "AXIdentifier") ?? string(b, "AXDOMIdentifier")
        if let idA, !idA.isEmpty {
            guard idA == idB else { return false }
        } else if let frameA = frame(of: a), let frameB = frame(of: b) {
            guard frameA == frameB else { return false }
        } else {
            // No identifier and no geometry: not enough to claim it is the same
            // element, so refuse to paste into it.
            return false
        }

        guard selectedRange(of: a) == selectedRange(of: b) else { return false }
        return true
    }

    /// The system-wide focused element, or nil. Kept here so the paste validation
    /// is self-contained and does not depend on the selection-reading layer.
    static func focusedElement() -> AXUIElement? {
        AXSelectionProbe.focusedElement()
    }

    // MARK: - AX helpers

    private static func isSecure(role: String?, subrole: String?) -> Bool {
        if let role, role == "AXSecureTextField" { return true }
        if let subrole, subrole.localizedCaseInsensitiveContains("secure") { return true }
        // NSSecureTextField surfaces come through as AXSecureTextField, but a
        // generic role with a secure subrole is covered above. Secure keyboard
        // entry is handled at the trigger/watcher sites.
        return false
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    /// The element's selected-text / caret range, in UTF-16 units (the units
    /// `AXSelectedTextRange` and `NSRange` both use).
    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private struct FrameKey: Equatable {
        let x: Double, y: Double, width: Double, height: Double
    }

    private static func frame(of element: AXUIElement) -> FrameKey? {
        guard let position = point(element, kAXPositionAttribute),
              let size = size(element, kAXSizeAttribute) else { return nil }
        return FrameKey(x: Double(position.x), y: Double(position.y),
                        width: Double(size.width), height: Double(size.height))
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
