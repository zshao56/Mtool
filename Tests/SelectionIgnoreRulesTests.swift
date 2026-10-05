import XCTest

/// The built-in ignore rules' JSON form: what is understood, and that anything
/// malformed is skipped rather than allowed to match everything.
final class SelectionIgnoreRulesTests: XCTestCase {

    private func parse(_ json: String) throws -> [SelectionIgnoreRules.Rule] {
        SelectionIgnoreRules.parse(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    func testAllMatcherFormsAndFields() throws {
        let rules = try parse("""
        [{ "name": "Toolbar search", "apps": ["com.apple.finder"],
           "element": { "AXRole": "AXTextField", "AXDescription": { "contains": "SEARCH" } },
           "ancestor": { "AXRole": { "regex": "^AXTool" } } }]
        """)
        XCTAssertEqual(rules.count, 1)
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.name, "Toolbar search")
        XCTAssertEqual(rule.apps, ["com.apple.finder"])
        XCTAssertEqual(rule.element.map(\.attribute), ["AXDescription", "AXRole"])
        let byName = Dictionary(uniqueKeysWithValues: rule.element.map { ($0.attribute, $0.matcher) })
        XCTAssertTrue(byName["AXRole"]!.matches("AXTextField"))
        XCTAssertFalse(byName["AXRole"]!.matches("AXTextFieldX"), "a plain string must match exactly")
        XCTAssertTrue(byName["AXDescription"]!.matches("Smart Search Field"), "contains ignores case")
        XCTAssertTrue(rule.ancestor[0].matcher.matches("AXToolbar"))
        XCTAssertFalse(rule.ancestor[0].matcher.matches("AXGroup"))
    }

    func testMalformedRulesAreSkipped() throws {
        let rules = try parse("""
        [{ "name": "no element" },
         { "name": "empty element", "element": {} },
         { "name": "unknown matcher", "element": { "AXRole": { "startsWith": "AX" } } },
         { "name": "bad regex", "element": { "AXRole": { "regex": "(" } } },
         { "name": "bad ancestor", "element": { "AXRole": "AXTextField" }, "ancestor": { "AXRole": ["AXToolbar"] } },
         { "name": "null ancestor is none", "element": { "AXRole": "AXTextField" }, "ancestor": null },
         { "name": "boolean value", "element": { "AXEnabled": true } },
         { "name": "switched off", "enabled": false, "element": { "AXRole": "AXTextField" } },
         { "name": "fine", "element": { "AXIdentifier": "searchField" } }]
        """)
        XCTAssertEqual(rules.map(\.name), ["null ancestor is none", "boolean value", "fine"])
        XCTAssertTrue(rules[0].ancestor.isEmpty)
        XCTAssertTrue(rules[1].element[0].matcher.matches("true"))
    }

    func testTheBuiltInRulesAllParseAndFollowTheirSwitch() throws {
        // Every entry in the built-in JSON must survive parsing — a typo there
        // would silently drop a rule.
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(SelectionIgnoreRules.builtInJSON.utf8))
        XCTAssertEqual(SelectionIgnoreRules.builtIn.count, raw.arrayValue?.count)
        let on = SelectionIgnoreRules.enabled(in: ["ignoreAddressBars": true])
        XCTAssertEqual(on.map(\.name), ["Chromium address bar", "Safari address bar"])
        XCTAssertTrue(on[0].element[0].matcher.matches("OmniboxViewViews"))
        XCTAssertTrue(on[1].element[0].matcher.matches("WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"))
        XCTAssertTrue(SelectionIgnoreRules.enabled(in: ["ignoreAddressBars": false]).isEmpty)
    }
}
