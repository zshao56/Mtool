import AppKit
import ApplicationServices

/// The selected-text retrieval abstraction.
///
/// This is the layer the whole tool is designed around: getting the user's
/// currently-selected text reliably across every app is the hard part, and no
/// single mechanism works everywhere. So a "strategy" is one *way* to read the
/// selection, and `SelectionResolver` runs an ordered list of them, taking the
/// first that succeeds.
///
/// Adding a new way to read text (AppleScript for browsers, a per-app special
/// case, a future API) means writing one `SelectionStrategy` and registering it
/// in the resolver — nothing else in the pipeline changes. Strategies can also
/// be reordered or combined freely; today we ship two.

/// Identifies which strategy produced a result — for logging, and so a caller
/// can later adapt behavior to *how* the text was obtained.
enum SelectionStrategyID: String {
    case accessibility
    case copyOnSelect  // app's own "copy on select" already put it on the clipboard
    case clipboardCopy
    case appleScript   // reserved for a future browser strategy
    case menuAction    // reserved for a future "press Edit > Copy" strategy
}

/// Where and what we're reading from. Passed into every strategy so none of them
/// reach for global state directly — keeps each strategy testable in isolation.
struct SelectionContext {
    /// The app that owns the selection (frontmost at trigger time).
    let frontmostApp: NSRunningApplication?
    /// Cursor location in screen coordinates (Cocoa, bottom-left origin) — where
    /// the gesture finished. Used to anchor the popup.
    let mouseLocation: CGPoint
    /// `NSPasteboard.general.changeCount` sampled at the gesture's mouse-DOWN.
    /// Lets a strategy detect a clipboard write that happened *during* this one
    /// selection gesture — i.e. an app's "copy on select" (OTTY, and any terminal
    /// with that option) — and read it directly. Scoping the comparison to this
    /// single gesture is what keeps it from ever picking up stale clipboard text.
    let clipboardChangeCountAtGestureStart: Int
    /// Whether a web-preview action is currently on the wheel. When true the
    /// strategies attach the cheap link-resolution material (focused AX element /
    /// copied rich pasteboard) and the controller runs `LinkResolver`. When false,
    /// zero link work happens — the feature isn't on, so it costs nothing.
    let resolvesLinks: Bool
    /// Whether the user allows the synthetic-⌘C fallback (`popup.simulateCopy`).
    /// Sampled on main at trigger time, since the config is main-thread only.
    var allowsSimulatedCopy: Bool = true
    /// Whether the app is in the user's terminal list (`popup.terminalApps`): a
    /// clipboard write during the gesture counts as the selection there even when
    /// the app reports none. Sampled on main at trigger time.
    var isTerminalApp: Bool = false

    var bundleID: String? { frontmostApp?.bundleIdentifier }
    var pid: pid_t? { frontmostApp?.processIdentifier }
}

/// A successful read. `via` records which strategy won; `bounds` is the optional
/// on-screen rect of the selection (some strategies can provide it for precise
/// popup placement, most can't).
struct SelectionResult {
    let text: String
    let via: SelectionStrategyID
    var bounds: CGRect?
    /// Trigger-time raw material for `LinkResolver`, attached ONLY when the context
    /// has `resolvesLinks == true`. `focusedElement` feeds the point/selection link
    /// tiers; `htmlData`/`rtfData` are the copied rich pasteboard for the HTML/RTF
    /// tier. The final resolved URL is computed by the controller, not stored here.
    var focusedElement: AXUIElement? = nil
    var htmlData: Data? = nil
    var rtfData: Data? = nil
    /// The element the text was read out of, whenever a strategy read it through
    /// Accessibility — unlike `focusedElement`, attached regardless of links. It is
    /// what `SelectionSource` checks before anything is written back in place of
    /// the selection.
    var sourceElement: AXUIElement? = nil
}

/// Where a selection came from, kept with the popup so a result can later be put
/// back IN PLACE of it (the Replace button, `output: replace`).
///
/// Writing into another app's document is only safe with positive evidence that
/// the place is still the one the user selected, so this is opt-in: it records
/// the element and its selected range at trigger time, and `canReplace` is true
/// only when both were readable. Text captured by ⌘C from an app that hides its
/// Accessibility tree gets NO Replace — pasting there lands wherever that app
/// puts focus (a chat's compose box, or a terminal prompt that would run every
/// line of the result).
struct SelectionSource {

    enum Origin {
        /// Selected text in some app.
        case selection
        /// Text recognised from a screen region. There is nothing to replace.
        case ocr
    }

    let origin: Origin
    /// Which strategy read the text; nil for OCR. Shown on the popup in Debug builds.
    var via: SelectionStrategyID? = nil
    let pid: pid_t?
    let element: AXUIElement?
    /// The selected range at trigger time, in the element's own units.
    let range: CFRange?

    static let ocr = SelectionSource(origin: .ocr, via: nil, pid: nil, element: nil, range: nil)

    var canReplace: Bool {
        origin == .selection && pid != nil && element != nil && (range?.length ?? 0) > 0
    }

    /// Read the selected range of `element`. Off the main thread is fine.
    static func capture(element: AXUIElement?, pid: pid_t?, via: SelectionStrategyID? = nil) -> SelectionSource {
        SelectionSource(origin: .selection, via: via, pid: pid, element: element,
                        range: element.flatMap(selectedRange(of:)))
    }

    static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}

/// Why a strategy failed. Only `permissionDenied` is *fatal* — it aborts the
/// whole resolver chain (no fallback can help if Accessibility is off). Every
/// other case just means "try the next strategy".
enum SelectionError: Error {
    case permissionDenied
    case noFocusedElement
    case noSelection
    case unsupported
    case timeout
    case system(Error)

    var isFatal: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

/// One way to read the current selection.
///
/// Implement this + register in `SelectionResolver` to add a strategy. Return a
/// `SelectionResult` on success, `nil` to fall through, or throw to fall through
/// (a thrown `.permissionDenied` aborts the chain). An empty `text` is treated
/// as failure by the resolver and falls through too.
protocol SelectionStrategy: AnyObject {
    var id: SelectionStrategyID { get }

    /// Cheap pre-filter: return false to skip this strategy for this context
    /// (e.g. a browser-only AppleScript strategy when the frontmost app isn't a
    /// supported browser). Default: always applicable.
    func canHandle(_ context: SelectionContext) -> Bool

    /// Read the selected text. See protocol doc for the success/fallthrough rules.
    func selectedText(_ context: SelectionContext) async throws -> SelectionResult?
}

extension SelectionStrategy {
    func canHandle(_ context: SelectionContext) -> Bool { true }
}
