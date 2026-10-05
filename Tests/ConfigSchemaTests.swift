import XCTest

/// The schema is JSON written inside a Swift string, so every backslash is
/// escaped twice — once for Swift, once for JSON — and a slip there produces a
/// file no editor can read, with nothing in the app to notice (it only writes
/// the schema, never reads it). 26.09.16 shipped exactly that.
final class ConfigSchemaTests: XCTestCase {

    private func schema() throws -> [String: Any] {
        let data = try XCTUnwrap(ConfigSchema.json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func pattern(_ section: String, _ key: String) throws -> NSRegularExpression {
        let properties = try XCTUnwrap(schema()["properties"] as? [String: Any])
        let group = try XCTUnwrap((properties[section] as? [String: Any])?["properties"] as? [String: Any])
        let raw = try XCTUnwrap((group[key] as? [String: Any])?["pattern"] as? String)
        return try NSRegularExpression(pattern: raw)
    }

    private func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func testSchemaIsValidJSON() throws {
        XCTAssertNoThrow(try schema())
    }

    func testHotKeyPatternsAcceptWhatTheAppWrites() throws {
        let ocr = try pattern("ocr", "hotKey")
        XCTAssertTrue(matches(ocr, "shift+cmd+s"))
        XCTAssertFalse(matches(ocr, ""))

        let popup = try pattern("popup", "hotKey")
        XCTAssertTrue(matches(popup, "opt+x"))
        XCTAssertTrue(matches(popup, ""))          // none recorded yet
        XCTAssertFalse(matches(popup, "opt+"))
    }
}
