import Foundation

/// The scene the main shortcut resolves to. There are exactly four states and
/// the app is always in one of them; the visible windows follow the state rather
/// than the other way round.
enum ContextScene: String, Equatable {
    /// Nothing is showing. A trigger from here resolves a scene.
    case hidden
    /// Scenario 1 — there is a non-empty text selection: show the action bar.
    case selection
    /// Scenario 2 — focus is in an editable control with no selection: show the
    /// clipboard panel.
    case clipboard
    /// Scenario 3 — anything else, or the context could not be read reliably:
    /// show the quick search box.
    case search
}

/// What the focused accessibility element is, as far as could be determined.
/// Every negative answer is the safe one: an unknown element is treated as
/// non-editable (and therefore never read) rather than assumed editable.
struct FocusedInputInfo: Equatable {
    var role: String?
    var subrole: String?
    var enabled: Bool
    var editable: Bool
    /// `AXSelectedText` is writable (checked with `AXUIElementIsAttributeSettable`).
    var selectedTextSettable: Bool
    /// `AXValue` is writable — the fallback for controls that expose no
    /// selected-text attribute.
    var valueSettable: Bool
    /// A password / secure field or the system's secure-input state. Never read.
    var isSecure: Bool
    /// An Electron/browser fallback matched by role even though the app exposes
    /// no explicit editable attribute. Requires real-device verification before
    /// automatic pasting is enabled (see docs/ACCEPTANCE.md).
    var isBrowserOrElectronFallback: Bool

    /// The conservative "we know nothing" value.
    static let unknown = FocusedInputInfo(
        role: nil, subrole: nil, enabled: false, editable: false,
        selectedTextSettable: false, valueSettable: false,
        isSecure: true, isBrowserOrElectronFallback: false)

    /// Whether this element should be treated as an editable text control for
    /// scenario 2. Deliberately strict: enabled, not secure, and either an
    /// explicit editable attribute or a writable value attribute, or a positively
    /// verified browser/Electron fallback.
    var looksEditable: Bool {
        guard !isSecure, enabled else { return false }
        if isBrowserOrElectronFallback { return true }
        guard editable else { return false }
        return selectedTextSettable || valueSettable
    }
}

/// A snapshot of the frontmost app and its focus, taken the instant the main
/// shortcut is pressed and BEFORE Mtool takes focus. The accessibility element
/// itself is deliberately not stored here — this type is pure data and is what
/// the routing unit tests exercise; the live `AXUIElement` is held by the
/// controller alongside the snapshot.
struct ContextSnapshot: Equatable {
    var frontAppBundleID: String?
    var frontAppPID: Int32?
    /// The selection read with `AXSelectedText` / the resolver, if any.
    var selectedText: String?
    var focused: FocusedInputInfo?
    var timestamp: Date
    /// Incremented on every trigger/close; async work compares it so a stale
    /// read never lands on a newer scene.
    var generation: Int

    init(frontAppBundleID: String? = nil,
         frontAppPID: Int32? = nil,
         selectedText: String? = nil,
         focused: FocusedInputInfo? = nil,
         timestamp: Date = Date(),
         generation: Int = 0) {
        self.frontAppBundleID = frontAppBundleID
        self.frontAppPID = frontAppPID
        self.selectedText = selectedText
        self.focused = focused
        self.timestamp = timestamp
        self.generation = generation
    }
}

/// The pure routing decision, in priority order:
///
/// 1. a non-empty text selection → `.selection` (even inside an input control,
///    because a selection there is still scenario 1);
/// 2. an editable focused control with no selection → `.clipboard`;
/// 3. everything else, including a failed/unreadable read → `.search`.
enum ContextRouting {

    /// Whether a captured string is worth acting on (not empty and not only
    /// whitespace / line breaks / invisible characters).
    static func hasActionableSelection(_ text: String?) -> Bool {
        guard let text else { return false }
        if text.isBlankSelection { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func scene(for snapshot: ContextSnapshot) -> ContextScene {
        if hasActionableSelection(snapshot.selectedText) { return .selection }
        if let focused = snapshot.focused, focused.looksEditable { return .clipboard }
        return .search
    }

    /// Whether an async selection read is still for the app that was frontmost
    /// when the shortcut was pressed. The read is asynchronous, so the user may
    /// have switched apps while it was in flight; a result for the old app must
    /// not open a surface over the new one.
    ///
    /// Both unknown cases are treated as "still current": if the trigger could
    /// not capture a pid, or the frontmost app cannot be read right now, there is
    /// nothing reliable to compare and dropping the result would be worse than
    /// showing it.
    static func isCurrent(frontPIDAtTrigger: Int32?, frontPIDNow: Int32?) -> Bool {
        guard let trigger = frontPIDAtTrigger else { return true }
        guard let now = frontPIDNow else { return true }
        return trigger == now
    }
}
