import AppKit
import Carbon.HIToolbox

/// Synthesizes a global ⌘C keystroke via CGEvent — the engine behind the
/// clipboard-copy fallback. Requires the Accessibility permission (which the
/// whole tool already gates on); needs no extra entitlement.
enum KeySender {

    /// Sentinel stamped onto every key event we synthesize (in the event's
    /// `eventSourceUserData` field), so our OWN `GlobalInputMonitor` can tell our
    /// synthetic ⌘C apart from a real user keystroke. Without it the monitor sees our
    /// ⌘C as a user keyDown and dismisses the very popup we're about to show (this is
    /// what made a triple-click in an AX-opaque app like WeChat — which goes through
    /// the ⌘C fallback — pop then vanish).
    ///
    /// The value is derived from the bundle id rather than written down, so it stays
    /// app-unique through a rename without anyone having to remember to change it.
    /// FNV-1a and not `hashValue`: Swift's hashing is seeded per process, and while
    /// only this process ever reads the tag back, a constant you can recognise in a
    /// log beats one that is different every launch.
    static let syntheticUserData: Int64 = {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Brand.baseID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // Clamp into the positive Int64 range: the field is signed.
        return Int64(hash & 0x7fff_ffff_ffff_ffff)
    }()

    /// Post ⌘C to the system, where it lands on whatever app is frontmost.
    static func copy() {
        postKeyCombo(virtualKey: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
    }

    /// Post ⌘V — used to put a result in place of the selection when the app
    /// does not take it through Accessibility. Tagged like `copy()`.
    static func paste() {
        postKeyCombo(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    private static func postKeyCombo(virtualKey: CGKeyCode, flags: CGEventFlags) {
        // .combinedSessionState so the synthesized event merges with the user's
        // real modifier state cleanly.
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        // Tag both events so we can recognize and ignore them in our global monitor.
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticUserData)
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticUserData)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
