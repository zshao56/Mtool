import AppKit
import ApplicationServices

/// Puts an action's result back into the app the text was selected in — in
/// place of the selection, or after it.
///
/// Two ways in, tried in order:
///  1. Accessibility: set the element's selected text. No clipboard involved.
///     Some apps report the attribute as settable and then ignore the write, so
///     the write is checked by reading the element back.
///  2. Paste: the result goes on the clipboard (marked transient), ⌘V is sent,
///     and the user's clipboard is put back afterwards.
///
/// Neither runs unless the place is provably the one the user selected: the same
/// app is frontmost, and the focused element still has the same selected range.
/// Otherwise the result goes on the clipboard and the caller says so — pasting
/// into whatever has focus NOW (a minute later, from a pinned window) is how a
/// result ends up in the wrong document.
///
/// The popup is a non-activating panel, so the source app keeps keyboard focus
/// throughout and nothing needs re-activating.
enum ReplaceWriter {

    enum Mode { case replace, append }

    enum Outcome: Equatable {
        /// Written through Accessibility.
        case replaced
        /// Sent as ⌘V.
        case pasted
        /// The selection is not where it was; the result is on the clipboard.
        case contextLost
    }

    private static let log = FileLog("PopBar.Replace")

    /// How long the pasted text stays on the clipboard before the user's own
    /// content is put back. The target app reads the clipboard when it handles
    /// ⌘V, which is well inside this on every app tried.
    static let restoreDelay: TimeInterval = 1.0

    /// Main thread only.
    static func write(_ result: String, mode: Mode, original: String, source: SelectionSource) -> Outcome {
        guard source.canReplace, let pid = source.pid, let element = source.element,
              let range = source.range else {
            return fallBackToClipboard(result, reason: "no replaceable source")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return fallBackToClipboard(result, reason: "source app is no longer frontmost")
        }
        guard let focused = AXSelectionProbe.focusedElement() else {
            return fallBackToClipboard(result, reason: "no focused element")
        }
        // The SAME element, and in it the SAME range. A different field of the
        // same app that happens to have an equal range (an address bar, another
        // document) is exactly the wrong place, so a range match alone is not
        // enough. An app whose element fails CFEqual on a re-fetch only costs a
        // copy instead of a replace.
        guard CFEqual(focused, element) else {
            return fallBackToClipboard(result, reason: "focus moved to another element")
        }
        let currentRange = SelectionSource.selectedRange(of: focused)
        guard currentRange.map({ $0.location == range.location && $0.length == range.length }) == true else {
            return fallBackToClipboard(result, reason: "selection range changed")
        }

        let text = mode == .replace ? result : original + separator(original, result) + result

        if writeThroughAccessibility(text, into: focused, capturedRange: range) {
            log.info("replaced through Accessibility (\(mode))")
            return .replaced
        }
        paste(text)
        log.info("replaced by paste (\(mode))")
        return .pasted
    }

    /// A blank line between multi-line texts, a space between short ones.
    static func separator(_ original: String, _ result: String) -> String {
        (original.contains("\n") || result.contains("\n")) ? "\n\n" : " "
    }

    private static func writeThroughAccessibility(_ text: String, into element: AXUIElement,
                                                  capturedRange: CFRange) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        let before = value(of: element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        // Did it take? Compare the whole value when the element exposes one;
        // otherwise a write that took collapses the selection, so the range moves.
        // Judging wrong in the "it took" direction would paste a SECOND copy, so a
        // write we cannot confirm counts as one that did not happen only when we
        // can see it did not.
        if let before, let after = value(of: element) { return before != after }
        if let now = SelectionSource.selectedRange(of: element) {
            return !(now.location == capturedRange.location && now.length == capturedRange.length)
        }
        return true
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// The user's clipboard as it was before the first of a run of pastes, while
    /// its restore is still pending. A second Replace inside the restore window
    /// must not back up OUR text as if it were the user's — it reuses this.
    private static var pendingRestore: [NSPasteboardItem]?

    private static func paste(_ text: String) {
        let saved = pendingRestore ?? Pasteboard.backup()
        pendingRestore = saved
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Pasteboard.Marker.transient)
        item.setData(Data(), forType: Pasteboard.Marker.autoGenerated)
        pasteboard.writeObjects([item])
        let ours = pasteboard.changeCount
        KeySender.paste()
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // Only put the user's clipboard back if nothing has been copied since:
            // restoring over a copy they just made would lose it. A later paste of
            // ours also changes the count; that one's own timer restores instead.
            guard NSPasteboard.general.changeCount == ours else {
                log.debug("clipboard changed after paste — not restoring")
                return
            }
            pendingRestore = nil
            Pasteboard.restore(saved)
        }
    }

    private static func fallBackToClipboard(_ result: String, reason: String) -> Outcome {
        log.info("not replacing — \(reason); result copied instead")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        return .contextLost
    }
}
