import ApplicationServices
import Foundation

/// Places where a selection is not meant for the popup — a browser's address
/// bar, a particular app's search box — recognised from the accessibility
/// attributes of the focused element and, optionally, of one of its ancestors.
///
/// The rules are internal: written below in `builtInJSON`, not read from the
/// user's config. To add one, find the values with the Inspect Element action
/// and add an entry; the format is documented in docs/ignore-rules.html.
enum SelectionIgnoreRules {

    struct Rule {
        let name: String
        /// The switch that turns the rule on (e.g. "ignoreAddressBars"); nil = always on.
        let setting: String?
        /// Bundle IDs the rule is limited to (case-insensitive). Empty = every app.
        let apps: [String]
        /// All must hold for the focused element itself.
        let element: [Condition]
        /// If present, some ancestor (up to the window) must satisfy all of these.
        let ancestor: [Condition]
    }

    struct Condition {
        let attribute: String
        let matcher: Matcher
    }

    enum Matcher {
        case equals(String)
        case contains(String)
        case regex(NSRegularExpression)

        func matches(_ value: String) -> Bool {
            switch self {
            case .equals(let s): return value == s
            case .contains(let s): return value.range(of: s, options: [.caseInsensitive, .widthInsensitive]) != nil
            case .regex(let r): return r.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            }
        }
    }

    private static let log = FileLog("PopBar.IgnoreRules")

    /// Every built-in rule. A rule with `"setting"` is on only while that
    /// switch is (see `enabled(in:)`).
    ///
    /// The address-bar values were read off the real elements (2026-09-29)
    /// and do not depend on the UI language: a Japanese Chrome describes its
    /// address bar as 「アドレス検索バー」, but its class stays `OmniboxViewViews`,
    /// which Edge, Brave, Arc and other Chromium browsers share (unverified).
    static let builtInJSON = """
    [
      { "name": "Chromium address bar", "setting": "ignoreAddressBars",
        "element": { "AXDOMClassList": "OmniboxViewViews" } },
      { "name": "Safari address bar", "setting": "ignoreAddressBars",
        "element": { "AXIdentifier": "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" } }
    ]
    """

    static let builtIn: [Rule] = parse(try? JSONDecoder().decode(JSONValue.self, from: Data(builtInJSON.utf8)))

    /// The built-in rules whose switch is on. `settings` maps a switch name to its state.
    static func enabled(in settings: [String: Bool]) -> [Rule] {
        builtIn.filter { rule in rule.setting.map { settings[$0] ?? false } ?? true }
    }

    // MARK: - Parsing

    /// Rules in the documented JSON form. A rule that cannot be understood is
    /// skipped (and logged by name), never allowed to match everything.
    static func parse(_ value: JSONValue?) -> [Rule] {
        (value?.arrayValue ?? []).enumerated().compactMap { index, item in
            guard let o = item.objectValue else { return nil }
            let name = o["name"]?.stringValue ?? "rule \(index + 1)"
            if o["enabled"]?.boolValue == false { return nil }
            guard let element = conditions(o["element"]), !element.isEmpty else {
                log.warn("ignore rule \"\(name)\" skipped: \"element\" needs at least one valid condition")
                return nil
            }
            let ancestor: [Condition]
            if let raw = o["ancestor"], !raw.isNull {
                guard let parsed = conditions(raw), !parsed.isEmpty else {
                    log.warn("ignore rule \"\(name)\" skipped: \"ancestor\" has no valid condition")
                    return nil
                }
                ancestor = parsed
            } else {
                ancestor = []
            }
            let apps = (o["apps"]?.arrayValue ?? []).compactMap(\.stringValue)
                + (o["app"]?.stringValue.map { [$0] } ?? [])
            return Rule(name: name, setting: o["setting"]?.stringValue, apps: apps, element: element, ancestor: ancestor)
        }
    }

    /// `{ "AXRole": "AXTextField", "AXDescription": { "contains": "search" } }`.
    /// nil when any condition is malformed — a half-understood rule could match
    /// far more than its author meant.
    private static func conditions(_ value: JSONValue?) -> [Condition]? {
        guard let o = value?.objectValue else { return nil }
        var out: [Condition] = []
        for (attribute, spec) in o.sorted(by: { $0.key < $1.key }) {
            let matcher: Matcher
            if let s = scalarText(spec) {
                matcher = .equals(s)
            } else if let m = spec.objectValue, m.count == 1, let (kind, raw) = m.first, let s = scalarText(raw) {
                switch kind {
                case "equals": matcher = .equals(s)
                case "contains": matcher = .contains(s)
                case "regex":
                    guard let r = try? NSRegularExpression(pattern: s) else { return nil }
                    matcher = .regex(r)
                default: return nil
                }
            } else {
                return nil
            }
            out.append(Condition(attribute: attribute, matcher: matcher))
        }
        return out
    }

    /// A string, number or boolean as the text `values(_:_:)` compares with;
    /// nil for anything else (an array, an object, null).
    private static func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number: return value.stringValue
        default: return nil
        }
    }

    // MARK: - Matching

    /// The first rule the element matches, if any. Off the main thread is fine.
    static func match(_ element: AXUIElement, bundleID: String?, rules: [Rule]) -> Rule? {
        rules.first { rule in
            if !rule.apps.isEmpty {
                guard let bundleID, rule.apps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
                else { return false }
            }
            guard satisfies(element, rule.element) else { return false }
            guard !rule.ancestor.isEmpty else { return true }
            var current = parent(of: element)
            var depth = 0
            while let node = current, depth < 40 {
                if satisfies(node, rule.ancestor) { return true }
                let roles = values(node, "AXRole")
                if roles.contains("AXWindow") || roles.contains("AXApplication") { break }   // up to the window
                current = parent(of: node)
                depth += 1
            }
            return false
        }
    }

    private static func satisfies(_ node: AXUIElement, _ conditions: [Condition]) -> Bool {
        conditions.allSatisfy { c in values(node, c.attribute).contains { c.matcher.matches($0) } }
    }

    /// An attribute as strings: a list attribute (AXDOMClassList) gives each
    /// entry; a number or boolean its text; an absent one nothing.
    static func values(_ node: AXUIElement, _ attribute: String) -> [String] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success, let value else { return [] }
        if let s = value as? String { return [s] }
        if let list = value as? [String] { return list }
        if let n = value as? NSNumber { return [CFGetTypeID(value) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue] }
        return []
    }

    private static func parent(of node: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
