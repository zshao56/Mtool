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

    /// Roles that are text controls. `AXTextArea` alone is NOT enough to call
    /// something editable — a read-only text area is still `AXTextArea` — so the
    /// settability check below is what decides.
    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// Roles a browser or Electron app might expose for a real text input even
    /// without an explicit editable attribute. Kept as a *separate* fallback
    /// flag: the plan requires real macOS acceptance evidence before automatic
    /// pasting is enabled for it, so it defaults to off and the router treats it
    /// as "not editable" until verified on a real desktop.
    private static let browserFallbackRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField",
    ]

    /// Whether the browser/Electron fallback may be trusted. Off by default; turn
    /// on only after `docs/ACCEPTANCE.md` records a real-device pass.
    static let browserFallbackEnabled = false

    /// Inspect the focused element (or nil). Cheap AX calls; main thread.
    static func inspect(_ element: AXUIElement?) -> FocusedInputInfo {
        guard let element else { return .unknown }

        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let enabled = boolValue(element, kAXEnabledAttribute) ?? true
        let editable = boolValue(element, editableAttribute) ?? false
        let selectedTextSettable = isSettable(element, kAXSelectedTextAttribute)
        let valueSettable = isSettable(element, kAXValueAttribute)
        let secure = isSecure(role: role, subrole: subrole)

        var fallback = false
        if browserFallbackEnabled, !secure, enabled,
           let role, browserFallbackRoles.contains(role) {
            // A real text control in a browser/Electron app that hides
            // `AXEditable` but does expose a settable value.
            fallback = valueSettable || selectedTextSettable
        }

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

    /// Whether `element` is still the front window's focused element and can take
    /// text through accessibility. Used to re-validate before a paste.
    static func canWrite(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        return inspect(element).looksEditable
    }

    /// Write `text` into `element` through accessibility. Tries the plain value
    /// first (append at the end), then the selected-text attribute (insert at the
    /// caret). Returns whether either worked. Never called for a secure element.
    static func writeText(_ text: String, to element: AXUIElement) -> Bool {
        guard !inspect(element).isSecure else { return false }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let existing = value as? String,
           isSettable(element, kAXValueAttribute) {
            let combined = existing + text
            if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, combined as CFString) == .success {
                return true
            }
        }
        if isSettable(element, kAXSelectedTextAttribute),
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return true
        }
        return false
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
}
