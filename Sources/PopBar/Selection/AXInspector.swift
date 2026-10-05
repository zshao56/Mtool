import AppKit
import ApplicationServices

/// The Inspect action's report: what the selection's element is, as the
/// accessibility API sees it, and where it sits in its window — the same
/// facts `SelectionIgnoreRules` matches on, so a new rule can be written from
/// what this shows. Local only; nothing here is logged.
enum AXInspector {
    /// Attributes worth showing. The element's text (AXValue, AXSelectedText)
    /// is left out: it is the selection itself, already on screen.
    private static let attributes = [
        "AXRole", "AXSubrole", "AXRoleDescription", "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList",
        "AXTitle", "AXDescription", "AXPlaceholderValue", "AXHelp",
    ]

    /// Many cross-process calls: run it off the main thread. `rules` are the
    /// ignore rules in force, read on the main thread by the caller.
    static func report(element: AXUIElement?, pid: pid_t?, rules: [SelectionIgnoreRules.Rule]) -> String {
        var lines: [String] = []
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            lines.append("**\(L("inspect.app"))** \(app.localizedName ?? "?") · `\(app.bundleIdentifier ?? "?")`")
        }
        guard let element else {
            lines.append(L("inspect.noElement"))
            return lines.joined(separator: "\n\n")
        }
        let bundleID = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        if let rule = SelectionIgnoreRules.match(element, bundleID: bundleID, rules: rules) {
            lines.append("**\(L("inspect.rule"))** \(rule.name)")
        }

        var details = ["```"]
        for name in attributes {
            if let value = describe(element, name) { details.append("\(name): \(value)") }
        }
        details.append("```")
        lines.append("**\(L("inspect.element"))**\n" + details.joined(separator: "\n"))

        // From the element up to the window, one line per level.
        var path: [String] = []
        var current: AXUIElement? = element
        while let node = current, path.count < 40 {
            path.append(summary(node))
            let role = describe(node, "AXRole") ?? ""
            if role == "AXWindow" || role == "AXApplication" { break }
            current = parent(of: node)
        }
        let indented = path.enumerated().map { String(repeating: "  ", count: $0.offset) + $0.element }
        lines.append("**\(L("inspect.path"))**\n```\n" + indented.joined(separator: "\n") + "\n```")
        return lines.joined(separator: "\n\n")
    }

    /// `AXRole(AXSubrole) #identifier .class "description"` for one level.
    private static func summary(_ node: AXUIElement) -> String {
        var s = describe(node, "AXRole") ?? "?"
        if let sub = describe(node, "AXSubrole") { s += "(\(sub))" }
        if let id = describe(node, "AXIdentifier") { s += " #\(id)" }
        if let classes = describe(node, "AXDOMClassList") { s += " .\(classes)" }
        if let d = describe(node, "AXDescription") ?? describe(node, "AXTitle") { s += " \"\(d.prefix(40))\"" }
        return s
    }

    private static func parent(of node: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// A readable value, or nil when absent or empty.
    private static func describe(_ node: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success, let value else { return nil }
        let text: String
        if let s = value as? String { text = s }
        else if let list = value as? [String] { text = list.joined(separator: " ") }
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
