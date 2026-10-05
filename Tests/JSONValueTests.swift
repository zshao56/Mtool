import XCTest

/// The config file is hand-edited, so the app must never delete something out of
/// it just because this build does not recognise it. That guarantee rests on one
/// mechanism — the document is kept as a tree and only the exact paths the app
/// knows about are ever written — so that is what these pin down.
final class JSONValueTests: XCTestCase {

    // MARK: - Unknown keys survive

    func testSettingAKnownPathLeavesAnUnknownSiblingAlone() throws {
        var doc = try decode("""
        {
          "popup": { "enabled": true },
          "experimental": { "somethingNew": true, "note": "written by hand" }
        }
        """)

        doc.set(path: "popup.enabled", to: false)

        XCTAssertEqual(doc[path: "popup.enabled"]?.boolValue, false)
        XCTAssertEqual(doc[path: "experimental.somethingNew"]?.boolValue, true,
                       "a top-level key this build has never heard of was dropped")
        XCTAssertEqual(doc[path: "experimental.note"]?.stringValue, "written by hand")
    }

    func testSettingAKnownPathLeavesAnUnknownKeyInTheSameObjectAlone() throws {
        var doc = try decode("""
        { "wheel": { "outerRadius": 116, "futureKnob": 42 } }
        """)

        doc.set(path: "wheel.outerRadius", to: 150)

        XCTAssertEqual(doc[path: "wheel.outerRadius"]?.doubleValue, 150)
        XCTAssertEqual(doc[path: "wheel.futureKnob"]?.doubleValue, 42,
                       "an unknown key NEXT TO the one being written was dropped")
    }

    func testAFullEncodeDecodeRoundTripKeepsEverything() throws {
        let source = """
        {
          "known": { "a": 1 },
          "unknown": { "nested": { "deep": ["x", 2, true, null] } }
        }
        """
        var doc = try decode(source)
        doc.set(path: "known.a", to: 2)

        // What the app actually writes goes through the encoder, so the round trip
        // is the thing that has to preserve, not just the in-memory edit.
        let data = try JSONEncoder().encode(doc)
        let reloaded = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(reloaded[path: "known.a"]?.doubleValue, 2)
        XCTAssertEqual(reloaded[path: "unknown.nested.deep"]?.arrayValue?.count, 4)
        XCTAssertEqual(reloaded[path: "unknown.nested.deep"]?.arrayValue?[0].stringValue, "x")
        XCTAssertEqual(reloaded[path: "unknown.nested.deep"]?.arrayValue?[3], JSONValue.null)
    }

    // MARK: - Paths

    func testWritingThroughAMissingIntermediateCreatesIt() {
        var doc = JSONValue.object([:])
        doc.set(path: "a.b.c", to: "deep")
        XCTAssertEqual(doc[path: "a.b.c"]?.stringValue, "deep")
    }

    func testReadingThroughANonObjectIsNilRatherThanACrash() throws {
        let doc = try decode("""
        { "popup": 3 }
        """)
        XCTAssertNil(doc[path: "popup.enabled"])
    }

    // MARK: - Tolerant reads (the file is typed by a person)

    func testNumbersAndStringsAreAcceptedWhereABoolIsExpected() throws {
        let doc = try decode("""
        { "a": 1, "b": 0, "c": "true", "d": "no", "e": "nonsense" }
        """)
        XCTAssertEqual(doc[path: "a"]?.boolValue, true)
        XCTAssertEqual(doc[path: "b"]?.boolValue, false)
        XCTAssertEqual(doc[path: "c"]?.boolValue, true)
        XCTAssertEqual(doc[path: "d"]?.boolValue, false)
        XCTAssertNil(doc[path: "e"]?.boolValue, "a word that means neither should not be guessed at")
    }

    func testWholeNumbersEncodeWithoutADecimalPoint() throws {
        var doc = JSONValue.object([:])
        doc.set(path: "radius", to: .number(116))
        let text = String(data: try JSONEncoder().encode(doc), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"radius\":116"),
                      "a config a person reads should say 116, not 116.0 — got \(text)")
    }

    // MARK: - Helper

    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}
