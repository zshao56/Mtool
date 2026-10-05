import XCTest
import SQLite3

/// The clipboard database: round-trips, de-duplication, pinning, capacity,
/// retention and snippets.
final class ClipboardStoreTests: XCTestCase {

    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("clipboard.sqlite") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func textItem(_ text: String, at date: Date = Date(), app: String? = "com.apple.Safari") -> ClipboardItem {
        ClipboardItem(kind: .text, text: text, sourceBundleID: app, createdAt: date,
                      contentHash: ClipboardPolicyEngine.dedupeKey(kind: .text, text: text, imageDigest: nil))
    }

    func testRoundTripNewestFirst() {
        let store = ClipboardStore(url: url)
        store.insert(textItem("first", at: Date(timeIntervalSince1970: 1_000)))
        store.insert(textItem("second", at: Date(timeIntervalSince1970: 2_000)))
        let items = store.items(limit: 10)
        XCTAssertEqual(items.map(\.text), ["second", "first"])
        XCTAssertEqual(items[0].kind, .text)
        XCTAssertEqual(items[0].sourceBundleID, "com.apple.Safari")
    }

    func testDuplicateRefreshesInsteadOfAdding() {
        let store = ClipboardStore(url: url)
        store.insert(textItem("same", at: Date(timeIntervalSince1970: 1_000)))
        store.insert(textItem("same", at: Date(timeIntervalSince1970: 5_000)))
        let items = store.items(limit: 10)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].createdAt.timeIntervalSince1970, 5_000, accuracy: 0.01)
    }

    func testPinnedSurvivesClearAndPruning() {
        let store = ClipboardStore(url: url)
        let id = store.insert(textItem("keep", at: Date(timeIntervalSince1970: 1_000)))!
        store.insert(textItem("drop1", at: Date(timeIntervalSince1970: 2_000)))
        store.insert(textItem("drop2", at: Date(timeIntervalSince1970: 3_000)))
        store.setPinned(id: id, pinned: true)
        // Capacity keeps one non-pinned row; the pinned one is never counted.
        let removed = store.prune(policy: ClipboardPolicy(maxItems: 1, retentionDays: 0, maxImageBytes: 0))
        XCTAssertEqual(removed, 1)
        let remaining = store.items(limit: 10)
        XCTAssertTrue(remaining.contains { $0.text == "keep" && $0.pinned })
        // clearHistory removes every non-pinned row; the pinned one survives.
        store.clearHistory()
        store.flush()
        XCTAssertEqual(store.items(limit: 10).map(\.text), ["keep"])
    }

    func testRetentionPrunesOldRows() {
        let store = ClipboardStore(url: url)
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        store.insert(textItem("old", at: old))
        store.insert(textItem("new"))
        let removed = store.prune(policy: ClipboardPolicy(maxItems: 0, retentionDays: 30, maxImageBytes: 0))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(store.items(limit: 10).map(\.text), ["new"])
    }

    func testSearch() {
        let store = ClipboardStore(url: url)
        store.insert(textItem("今天天气很好"))
        store.insert(textItem("speculative decoding"))
        XCTAssertEqual(store.items(matching: "天气").map(\.text), ["今天天气很好"])
        XCTAssertEqual(store.items(matching: "SPECULATIVE").map(\.text), ["speculative decoding"])
        XCTAssertEqual(store.items(matching: "nothing-here"), [])
    }

    func testSnippetsRoundTrip() {
        let store = ClipboardStore(url: url)
        let a = store.upsertSnippet(Snippet(title: "Greeting", text: "Hello"))
        let b = store.upsertSnippet(Snippet(title: "Sign", text: "Regards"))
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        let snippets = store.snippets()
        XCTAssertEqual(snippets.map(\.title), ["Greeting", "Sign"])
        store.deleteSnippet(id: a!)
        store.flush()
        XCTAssertEqual(store.snippets().map(\.title), ["Sign"])
    }

    func testCount() {
        let store = ClipboardStore(url: url)
        store.insert(textItem("a"))
        store.insert(textItem("b"))
        XCTAssertEqual(store.count(), 2)
    }
}
