import XCTest
import SQLite3

/// The history file: what goes in comes back, search works on Chinese, and a
/// file written by a newer build — or a broken one — never loses data.
final class HistoryStoreTests: XCTestCase {

    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("history.sqlite") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func record(_ input: String, output: String? = "out", category: HistoryRecord.Category = .ai,
                        app: String? = "com.apple.Safari", at date: Date = Date(),
                        extras: [String: String] = [:], status: HistoryRecord.Status = .ok) -> HistoryRecord {
        HistoryRecord(createdAt: date, trigger: "selection", appBundleID: app, appName: app.map { _ in "Safari" },
                      actionID: "a1", actionKind: "ai", actionTitle: "翻译", actionSymbol: "character.bubble",
                      actionJSON: #"{"kind":"ai","futureKey":1}"#, category: category.rawValue,
                      input: input, provider: "deepseek", model: "deepseek-v4-flash", durationMs: 1200,
                      outcomeType: "text", output: output, extras: extras, deliverMode: "panel",
                      delivered: nil, status: status.rawValue)
    }

    func testRoundTripNewestFirst() async {
        let store = HistoryStore(url: url)
        store.insert(record("first", at: Date(timeIntervalSince1970: 1000)))
        store.insert(record("second", at: Date(timeIntervalSince1970: 2000), extras: ["style": "compare"]))
        let rows = await store.records(matching: .init(), limit: 10)
        XCTAssertEqual(rows.map(\.input), ["second", "first"])
        XCTAssertEqual(rows[0].extras["style"], "compare")
        XCTAssertEqual(rows[0].actionJSON, #"{"kind":"ai","futureKey":1}"#)
        XCTAssertEqual(rows[0].durationMs, 1200)
        XCTAssertEqual(rows[0].createdAt.timeIntervalSince1970, 2000, accuracy: 0.001)
    }

    func testSearchChineseAndLatin() async {
        let store = HistoryStore(url: url)
        store.insert(record("今天天气很好", output: "The weather is nice today"))
        store.insert(record("推测解码", output: "Speculative decoding"))
        func find(_ text: String) async -> [String] {
            await store.records(matching: .init(text: text), limit: 10).map(\.input)
        }
        let three = await find("天气很")      // full-text index (3+ characters)
        let two = await find("天气")          // too short for trigrams: LIKE
        let latin = await find("SPECULATIVE") // case-insensitive
        let none = await find("不存在的词")
        let wildcard = await find("%")        // a LIKE wildcard is matched literally
        XCTAssertEqual(three, ["今天天气很好"])
        XCTAssertEqual(two, ["今天天气很好"])
        XCTAssertEqual(latin, ["推测解码"])
        XCTAssertEqual(none, [])
        XCTAssertEqual(wildcard, [])
    }

    func testFiltersAndCounts() async {
        let store = HistoryStore(url: url)
        store.insert(record("a", category: .ai, app: "com.apple.Safari"))
        store.insert(record("b", category: .text, app: "com.apple.Notes"))
        store.insert(record("c", category: .ai, app: "com.apple.Notes"))
        let notes = await store.records(matching: .init(appBundleID: "com.apple.Notes"), limit: 10)
        XCTAssertEqual(Set(notes.map(\.input)), ["b", "c"])
        let aiInNotes = await store.records(matching: .init(category: .ai, appBundleID: "com.apple.Notes"), limit: 10)
        XCTAssertEqual(aiInNotes.map(\.input), ["c"])
        let counts = await store.counts(matching: .init())
        XCTAssertEqual(counts[nil], 3)
        XCTAssertEqual(counts[.ai], 2)
        XCTAssertEqual(counts[.text], 1)
        let apps = await store.apps()
        XCTAssertEqual(Set(apps.map(\.bundleID)), ["com.apple.Safari", "com.apple.Notes"])
    }

    func testDeliveredPatchesTheRightRecord() async {
        let store = HistoryStore(url: url)
        store.insert(record("other"))
        let ticket = HistoryTicket()
        store.insert(record("mine"), ticket: ticket)
        store.setDelivered(.replaced, ticket: ticket)
        let rows = await store.records(matching: .init(), limit: 10)
        XCTAssertEqual(rows.first { $0.input == "mine" }?.delivered, "replaced")
        XCTAssertNil(rows.first { $0.input == "other" }?.delivered)
    }

    func testDeleteOlderAndDeleteAll() async {
        let store = HistoryStore(url: url)
        for i in 0..<1203 { store.insert(record("old \(i)", at: Date(timeIntervalSince1970: 1000))) }
        store.insert(record("new"))
        await withCheckedContinuation { c in store.deleteOlder(than: Date(timeIntervalSince1970: 5000)) { c.resume() } }
        let left = await store.records(matching: .init(), limit: 2000)
        XCTAssertEqual(left.map(\.input), ["new"])
        let search = await store.records(matching: .init(text: "old 1"), limit: 10)
        XCTAssertEqual(search, [], "deleted rows must leave the search index too")
        await withCheckedContinuation { c in store.deleteAll { c.resume() } }
        let none = await store.records(matching: .init(), limit: 10)
        XCTAssertEqual(none, [])
    }

    /// A newer build added a column and moved the schema on. This build keeps
    /// working with the file and never strips what the newer one stored.
    func testFileFromANewerBuild() async throws {
        let first = HistoryStore(url: url)
        first.insert(record("before"))
        first.flush()
        _ = await first.records(matching: .init(), limit: 1)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            ALTER TABLE history ADD COLUMN future TEXT DEFAULT 'x';
            UPDATE history SET future = 'kept';
            PRAGMA user_version = 99;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let older = HistoryStore(url: url)
        let ticket = HistoryTicket()
        older.insert(record("after"), ticket: ticket)
        older.setDelivered(.copied, ticket: ticket)
        let rows = await older.records(matching: .init(), limit: 10)
        XCTAssertEqual(Set(rows.map(\.input)), ["before", "after"])

        older.flush()
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT future FROM history WHERE input = 'before'", -1, &stmt, nil)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), "kept")
        sqlite3_finalize(stmt)
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil)
        sqlite3_step(stmt)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 99, "an older build must not move the version back")
        sqlite3_finalize(stmt)
        sqlite3_close(db)
    }

    /// A file that is not a database is moved aside — kept, not deleted — and a
    /// new one started.
    func testUnreadableFileIsMovedAside() async throws {
        try Data("this is not a database, just some bytes long enough to be read".utf8).write(to: url)
        let store = HistoryStore(url: url)
        store.insert(record("fresh"))
        let rows = await store.records(matching: .init(), limit: 10)
        XCTAssertEqual(rows.map(\.input), ["fresh"])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("history.sqlite.bad-") }, "\(names)")
    }

    /// Two connections (as a Release and a Debug build would hold) writing at once.
    func testTwoWritersAtOnce() async {
        let a = HistoryStore(url: url), b = HistoryStore(url: url)
        _ = await a.records(matching: .init(), limit: 1)   // create the schema first
        for i in 0..<200 {
            a.insert(record("a\(i)"))
            b.insert(record("b\(i)"))
        }
        a.flush(); b.flush()
        let counts = await a.counts(matching: .init())
        XCTAssertEqual(counts[nil], 400)
    }
}
