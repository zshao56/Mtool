import Foundation

/// One past run of an action, as stored in `HistoryStore` and shown on the
/// History page.
///
/// Every field that names a kind of thing (`trigger`, `category`, `outcomeType`,
/// `status`, `deliverMode`, `delivered`) is held as the RAW STRING from the
/// database, with a typed view beside it. A record written by a newer build can
/// carry a value this build has never heard of; it is shown as best it can be
/// and never rewritten, the same rule `PopBarActionConfig` follows for `kind`.
struct HistoryRecord: Identifiable, Hashable {

    enum Trigger: String { case selection, hotkey, ocr }

    /// Which filter chip a record falls under. Decided when the record is written.
    enum Category: String, CaseIterable { case ai, text, speech, web, automation, error }

    enum Status: String { case ok, error, cancelled }

    /// What the run produced — this, not the action's kind, decides how the
    /// record is drawn.
    enum OutcomeType: String {
        /// Text the action made: `output` holds it.
        case text
        /// A report or an error message: `output` holds it.
        case message
        /// A page opened: `output` is the URL.
        case link
        /// A local file or folder shown: `output` is the path.
        case file
        /// Text read aloud: the text is `input`.
        case speech
        /// The action ran and showed nothing (Copy, a Shortcut with no output).
        case silent
    }

    /// What became of a result meant for the document (or the clipboard).
    enum Delivered: String { case replaced, pasted, copied, failed }

    /// The database row id. 0 for a record not stored yet.
    var id: Int64 = 0
    var createdAt: Date
    var trigger: String
    var appBundleID: String?
    var appName: String?
    var actionID: String?
    var actionKind: String
    var actionTitle: String
    var actionSymbol: String
    /// The action exactly as it was configured, encoded by `PopBarActionConfig`
    /// itself (so keys a newer build added survive). Written once, never re-encoded.
    var actionJSON: String
    var category: String
    var input: String
    var inputTruncated = false
    var provider: String?
    var model: String?
    var durationMs: Int?
    var outcomeType: String
    var output: String?
    /// Type-specific details (`style`, `target`, `isDirectory`, `reader`…).
    /// Read only; a value that is not a string arrives as its JSON text.
    var extras: [String: String] = [:]
    var deliverMode: String?
    var delivered: String?
    var status: String

    var typedTrigger: Trigger? { Trigger(rawValue: trigger) }
    var typedCategory: Category? { Category(rawValue: category) }
    var typedStatus: Status { Status(rawValue: status) ?? .ok }
    var typedOutcome: OutcomeType? { OutcomeType(rawValue: outcomeType) }
    var typedDelivered: Delivered? { delivered.flatMap(Delivered.init(rawValue:)) }

    var isError: Bool { typedStatus == .error }

    /// The most text either field keeps; longer is cut here and flagged, never
    /// dropped (a 2 MB log pasted into Translate still gets a record).
    static let maxTextLength = 100_000

    static func truncated(_ text: String) -> (text: String, truncated: Bool) {
        guard text.count > maxTextLength else { return (text, false) }
        return (String(text.prefix(maxTextLength)), true)
    }
}
