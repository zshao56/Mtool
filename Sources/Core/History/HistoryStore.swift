import Foundation
import SQLite3
import CryptoKit

extension Notification.Name {
    /// Posted on the main queue after this process changed the history.
    static let historyDidChange = Notification.Name("HistoryDidChange")
}

/// Hands a record's row id from its insert to a later patch of the same record
/// (what became of the result). Touched only on the store's queue, where the
/// insert always runs before any patch queued after it.
final class HistoryTicket {
    fileprivate var rowID: Int64?
}

/// The action history, in one SQLite file shared by Debug and Release builds
/// (`Brand.sharedSupportDirectory/history.sqlite`).
///
/// Design notes (decided with a review of the alternatives; see
/// `design/history-options.html`):
///
/// - The system `libsqlite3`, no wrapper library. One table, one full-text index.
/// - Columns for everything filtered, sorted, searched or patched; one JSON blob
///   per axis (`action_json`, `outcome_json`) for the rest, written once.
/// - Migrations only ever ADD (columns with defaults, indexes, tables), keyed by
///   `PRAGMA user_version`, so an older build can still insert into a file a newer
///   one upgraded — and since it only inserts, updates named columns and deletes
///   rows, it can never strip what a newer build stored.
/// - Search uses an FTS5 index with the `trigram` tokenizer: the default one
///   treats a run of Chinese as one word. Trigrams need 3 characters, so shorter
///   queries fall back to `LIKE`; so does everything if FTS5 is missing.
/// - Two processes may write at once: WAL, a busy timeout, `BEGIN IMMEDIATE`.
/// - Everything runs on one serial queue; the UI gets value snapshots.
final class HistoryStore {

    static let shared = HistoryStore(url: HistoryStore.defaultURL)

    /// `MTOOL_HISTORY_DB` points a build at a scratch copy (testing a migration or
    /// Clear All without touching the real history). The legacy `QDUO_HISTORY_DB`
    /// name is also honoured so an existing developer setup keeps working.
    static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["MTOOL_HISTORY_DB"] ?? env["QDUO_HISTORY_DB"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Brand.sharedSupportDirectory.appendingPathComponent("history.sqlite")
    }

    /// The newest schema this build knows. See `migrations`.
    static let schemaVersion: Int32 = 1

    let url: URL
    private let queue = DispatchQueue(label: "HistoryStore", qos: .utility)
    private var db: OpaquePointer?
    private var opened = false
    private(set) var hasFullTextIndex = false
    private static let log = FileLog("History")

    init(url: URL) {
        self.url = url
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Writing

    /// Store a new record. The ticket, if given, lets a later `setDelivered`
    /// find it.
    func insert(_ record: HistoryRecord, ticket: HistoryTicket? = nil) {
        queue.async {
            guard self.open() else { return }
            let id: Int64? = self.writing { () -> Int64? in
                let sql = """
                INSERT INTO history (record_version, app_version, created_at, trigger, app_bundle_id, app_name,
                  action_id, action_kind, action_title, action_symbol, action_json, category,
                  input, input_truncated, input_hash, provider, model, duration_ms,
                  outcome_type, output, outcome_json, deliver_mode, delivered, status)
                VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
                guard let stmt = self.prepare(sql) else { return nil }
                defer { sqlite3_finalize(stmt) }
                let extras = record.extras.isEmpty ? nil
                    : (try? JSONSerialization.data(withJSONObject: record.extras, options: [.sortedKeys]))
                        .flatMap { String(data: $0, encoding: .utf8) }
                let values: [SQLValue] = [
                    .text(Brand.version), .int(Int64(record.createdAt.timeIntervalSince1970 * 1000)),
                    .text(record.trigger), .optText(record.appBundleID), .optText(record.appName),
                    .optText(record.actionID), .text(record.actionKind), .text(record.actionTitle),
                    .text(record.actionSymbol), .text(record.actionJSON), .text(record.category),
                    .text(record.input), .int(record.inputTruncated ? 1 : 0), .text(Self.hash(record.input)),
                    .optText(record.provider), .optText(record.model), .optInt(record.durationMs.map(Int64.init)),
                    .text(record.outcomeType), .optText(record.output), .optText(extras),
                    .optText(record.deliverMode), .optText(record.delivered), .text(record.status),
                ]
                self.bind(values, to: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    self.logError("insert")
                    return nil
                }
                return sqlite3_last_insert_rowid(self.db)
            }
            ticket?.rowID = id
            if id != nil { self.notifyChanged() }
        }
    }

    /// Record what became of a result after it was stored.
    func setDelivered(_ delivered: HistoryRecord.Delivered, ticket: HistoryTicket) {
        queue.async {
            guard self.open(), let id = ticket.rowID else { return }
            let changed = self.writing { () -> Bool in
                guard let stmt = self.prepare("UPDATE history SET delivered = ? WHERE id = ?") else { return false }
                defer { sqlite3_finalize(stmt) }
                self.bind([.text(delivered.rawValue), .int(id)], to: stmt)
                return sqlite3_step(stmt) == SQLITE_DONE
            }
            if changed == true { self.notifyChanged() }
        }
    }

    /// Delete every record older than `cutoff`, in small batches so a page
    /// reading the history never waits behind one long delete.
    func deleteOlder(than cutoff: Date, completion: (() -> Void)? = nil) {
        queue.async {
            guard self.open() else { return self.finish(completion) }
            var total = 0
            while true {
                let n = self.writing { () -> Int? in
                    let sql = "DELETE FROM history WHERE id IN (SELECT id FROM history WHERE created_at < ? LIMIT 500)"
                    guard let stmt = self.prepare(sql) else { return nil }
                    defer { sqlite3_finalize(stmt) }
                    self.bind([.int(Int64(cutoff.timeIntervalSince1970 * 1000))], to: stmt)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { self.logError("prune"); return nil }
                    return Int(sqlite3_changes(self.db))
                } ?? 0
                total += n
                if n < 500 { break }
            }
            if total > 0 {
                Self.log.info("removed \(total) record(s) past the retention period")
                self.notifyChanged()
            }
            self.finish(completion)
        }
    }

    /// Delete everything, then compact the file so the text is really gone
    /// (`secure_delete` also zeroes the freed pages).
    func deleteAll(completion: (() -> Void)? = nil) {
        queue.async {
            guard self.open() else { return self.finish(completion) }
            while true {
                let n = self.writing { () -> Int? in
                    guard self.exec("DELETE FROM history WHERE id IN (SELECT id FROM history LIMIT 500)") else { return nil }
                    return Int(sqlite3_changes(self.db))
                } ?? 0
                if n < 500 { break }
            }
            if self.hasFullTextIndex { _ = self.exec("INSERT INTO history_fts(history_fts) VALUES('rebuild')") }
            _ = self.exec("VACUUM")
            Self.log.info("history cleared")
            self.notifyChanged()
            self.finish(completion)
        }
    }

    // MARK: - Reading

    struct Query: Equatable {
        var text = ""
        var category: HistoryRecord.Category?
        var appBundleID: String?
    }

    /// The newest records matching `query`, at most `limit`.
    func records(matching query: Query, limit: Int) async -> [HistoryRecord] {
        await onQueue { [self] in
            guard open() else { return [] }
            var (clause, values) = whereClause(query, includeCategory: true)
            values.append(.int(Int64(limit)))
            let sql = """
            SELECT id, created_at, trigger, app_bundle_id, app_name, action_id, action_kind, action_title,
              action_symbol, action_json, category, input, input_truncated, provider, model, duration_ms,
              outcome_type, output, outcome_json, deliver_mode, delivered, status
            FROM history \(clause) ORDER BY created_at DESC, id DESC LIMIT ?
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(values, to: stmt)
            var out: [HistoryRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(Self.read(stmt)) }
            return out
        }
    }

    /// How many records each category has among those the search and app
    /// filter let through, plus the total under `nil`.
    func counts(matching query: Query) async -> [HistoryRecord.Category?: Int] {
        await onQueue { [self] in
            guard open() else { return [:] }
            let (clause, values) = whereClause(query, includeCategory: false)
            guard let stmt = prepare("SELECT category, COUNT(*) FROM history \(clause) GROUP BY category") else { return [:] }
            defer { sqlite3_finalize(stmt) }
            bind(values, to: stmt)
            var out: [HistoryRecord.Category?: Int] = [nil: 0]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let n = Int(sqlite3_column_int64(stmt, 1))
                out[nil, default: 0] += n
                if let c = Self.text(stmt, 0).flatMap(HistoryRecord.Category.init(rawValue:)) { out[c, default: 0] += n }
            }
            return out
        }
    }

    /// Every app that has a record, newest first, with the name it was last seen under.
    func apps() async -> [(bundleID: String, name: String)] {
        await onQueue { [self] in
            guard open() else { return [] }
            let sql = """
            SELECT app_bundle_id, app_name, MAX(created_at) AS last FROM history
            WHERE app_bundle_id IS NOT NULL GROUP BY app_bundle_id ORDER BY last DESC
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [(String, String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = Self.text(stmt, 0) else { continue }
                out.append((id, Self.text(stmt, 1) ?? id))
            }
            return out
        }
    }

    /// The file's size on disk, write-ahead log included.
    func diskSize() async -> Int64 {
        await onQueue { [self] in
            ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
                let path = url.path + suffix
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
                return sum + size
            }
        }
    }

    /// Waits for every queued write. Called at quit, so a record made in the
    /// last moment is not lost.
    func flush() {
        queue.sync {}
    }

    // MARK: - Query building

    private func whereClause(_ query: Query, includeCategory: Bool) -> (String, [SQLValue]) {
        var parts: [String] = []
        var values: [SQLValue] = []
        if includeCategory, let c = query.category {
            parts.append("category = ?"); values.append(.text(c.rawValue))
        }
        if let app = query.appBundleID {
            parts.append("app_bundle_id = ?"); values.append(.text(app))
        }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let like = "%" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            if hasFullTextIndex, text.count >= 3 {
                // One quoted phrase: matched as a substring, punctuation and all.
                let phrase = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                parts.append("(id IN (SELECT rowid FROM history_fts WHERE history_fts MATCH ?) OR action_title LIKE ? ESCAPE '\\')")
                values += [.text(phrase), .text(like)]
            } else {
                parts.append("(input LIKE ? ESCAPE '\\' OR output LIKE ? ESCAPE '\\' OR action_title LIKE ? ESCAPE '\\')")
                values += [.text(like), .text(like), .text(like)]
            }
        }
        return (parts.isEmpty ? "" : "WHERE " + parts.joined(separator: " AND "), values)
    }

    // MARK: - Opening and migrating

    /// Opens the file on first use. A file that cannot be opened or read as a
    /// database is moved aside (`history.sqlite.bad-<time>`), never deleted, and
    /// a fresh one started.
    private func open() -> Bool {
        if opened { return db != nil }
        opened = true
        if openAndMigrate() { return true }
        if let db { sqlite3_close_v2(db) }
        db = nil
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try? FileManager.default.moveItem(atPath: url.path + suffix, toPath: url.path + ".bad-\(stamp)" + suffix)
        }
        Self.log.error("history file unreadable — moved aside as .bad-\(stamp), starting a new one")
        return openAndMigrate()
    }

    private func openAndMigrate() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            Self.log.error("cannot create the history folder: \(error.localizedDescription)")
            return false
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            logError("open")
            return false
        }
        sqlite3_busy_timeout(db, 2000)
        _ = exec("PRAGMA journal_mode=WAL")
        _ = exec("PRAGMA synchronous=NORMAL")
        _ = exec("PRAGMA secure_delete=ON")
        // A file that is not a database fails here, on the first real read.
        guard let current = userVersion() else { return false }
        if current > Self.schemaVersion {
            Self.log.warn("history file is schema \(current), this build knows \(Self.schemaVersion) — using it as is")
        } else if current < Self.schemaVersion {
            let ok = writing { () -> Bool in
                // Re-read inside the write lock: another build may have migrated
                // the file between the check above and getting the lock.
                var version = self.userVersion() ?? 0
                while version < Self.schemaVersion {
                    guard self.migrate(to: version + 1) else { return false }
                    version += 1
                    guard self.exec("PRAGMA user_version = \(version)") else { return false }
                }
                return true
            }
            guard ok == true else { return false }
        }
        hasFullTextIndex = tableExists("history_fts")
        if !hasFullTextIndex { Self.log.warn("no full-text index — search falls back to LIKE") }
        return true
    }

    /// The steps from one schema version to the next. ADD ONLY — never drop,
    /// rename, retype, or add a NOT NULL column without a default: an older
    /// build still inserts into this table.
    private func migrate(to version: Int32) -> Bool {
        switch version {
        case 1:
            let table = """
            CREATE TABLE IF NOT EXISTS history (
              id INTEGER PRIMARY KEY,
              record_version INTEGER NOT NULL DEFAULT 1,
              app_version TEXT,
              created_at INTEGER NOT NULL,
              trigger TEXT NOT NULL,
              app_bundle_id TEXT,
              app_name TEXT,
              action_id TEXT,
              action_kind TEXT NOT NULL,
              action_title TEXT,
              action_symbol TEXT,
              action_json TEXT NOT NULL,
              category TEXT NOT NULL,
              input TEXT NOT NULL,
              input_truncated INTEGER NOT NULL DEFAULT 0,
              input_hash TEXT,
              provider TEXT,
              model TEXT,
              duration_ms INTEGER,
              outcome_type TEXT NOT NULL,
              output TEXT,
              outcome_json TEXT,
              deliver_mode TEXT,
              delivered TEXT,
              status TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS history_created ON history(created_at);
            CREATE INDEX IF NOT EXISTS history_app ON history(app_bundle_id, created_at);
            CREATE INDEX IF NOT EXISTS history_category ON history(category, created_at);
            CREATE INDEX IF NOT EXISTS history_hash ON history(input_hash);
            """
            guard exec(table) else { return false }
            // The index is optional: without FTS5 compiled in, search uses LIKE.
            let fts = """
            CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(input, output,
              content='history', content_rowid='id', tokenize='trigram');
            CREATE TRIGGER IF NOT EXISTS history_ai AFTER INSERT ON history BEGIN
              INSERT INTO history_fts(rowid, input, output) VALUES (new.id, new.input, new.output);
            END;
            CREATE TRIGGER IF NOT EXISTS history_ad AFTER DELETE ON history BEGIN
              INSERT INTO history_fts(history_fts, rowid, input, output) VALUES ('delete', old.id, old.input, old.output);
            END;
            CREATE TRIGGER IF NOT EXISTS history_au AFTER UPDATE OF input, output ON history BEGIN
              INSERT INTO history_fts(history_fts, rowid, input, output) VALUES ('delete', old.id, old.input, old.output);
              INSERT INTO history_fts(rowid, input, output) VALUES (new.id, new.input, new.output);
            END;
            """
            if !exec(fts, quiet: true) {
                Self.log.warn("FTS5 trigram index unavailable — continuing without it")
            }
            return true
        default:
            return false
        }
    }

    // MARK: - SQLite helpers

    enum SQLValue {
        case text(String), int(Int64), null
        static func optText(_ s: String?) -> SQLValue { s.map(SQLValue.text) ?? .null }
        static func optInt(_ i: Int64?) -> SQLValue { i.map(SQLValue.int) ?? .null }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ values: [SQLValue], to stmt: OpaquePointer) {
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, Self.transient)
            case .int(let n):  sqlite3_bind_int64(stmt, index, n)
            case .null:        sqlite3_bind_null(stmt, index)
            }
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logError("prepare")
            return nil
        }
        return stmt
    }

    @discardableResult
    private func exec(_ sql: String, quiet: Bool = false) -> Bool {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            if !quiet { logError("exec") }
            return false
        }
        return true
    }

    /// Runs `body` in a write transaction taken up front (`BEGIN IMMEDIATE`), so
    /// with another process writing it waits for the lock instead of failing
    /// halfway. Rolled back when `body` returns nil or false.
    private func writing<T>(_ body: () -> T?) -> T? {
        guard exec("BEGIN IMMEDIATE") else { return nil }
        let result = body()
        if result == nil || (result as? Bool) == false {
            exec("ROLLBACK")
        } else if !exec("COMMIT") {
            exec("ROLLBACK")
            return nil
        }
        return result
    }

    private func userVersion() -> Int32? {
        guard let stmt = prepare("PRAGMA user_version") else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(stmt, 0)
    }

    private func tableExists(_ name: String) -> Bool {
        guard let stmt = prepare("SELECT 1 FROM sqlite_master WHERE name = ?") else { return false }
        defer { sqlite3_finalize(stmt) }
        bind([.text(name)], to: stmt)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// The error code and SQLite's own message — never the statement's values,
    /// which hold what the user selected.
    private func logError(_ what: String) {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
        let code = db.map { sqlite3_errcode($0) } ?? -1
        Self.log.error("\(what) failed (\(code)): \(message)")
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: c)
    }

    private static func read(_ s: OpaquePointer) -> HistoryRecord {
        func int(_ c: Int32) -> Int64? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : sqlite3_column_int64(s, c) }
        var extras: [String: String] = [:]
        if let json = text(s, 18), let data = json.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in object {
                if let string = value as? String { extras[key] = string }
                else if let number = value as? NSNumber { extras[key] = number.stringValue }
                else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
                    extras[key] = String(data: data, encoding: .utf8)
                }
            }
        }
        return HistoryRecord(
            id: sqlite3_column_int64(s, 0),
            createdAt: Date(timeIntervalSince1970: Double(int(1) ?? 0) / 1000),
            trigger: text(s, 2) ?? "",
            appBundleID: text(s, 3), appName: text(s, 4),
            actionID: text(s, 5), actionKind: text(s, 6) ?? "",
            actionTitle: text(s, 7) ?? "", actionSymbol: text(s, 8) ?? "",
            actionJSON: text(s, 9) ?? "", category: text(s, 10) ?? "",
            input: text(s, 11) ?? "", inputTruncated: (int(12) ?? 0) != 0,
            provider: text(s, 13), model: text(s, 14), durationMs: int(15).map(Int.init),
            outcomeType: text(s, 16) ?? "", output: text(s, 17), extras: extras,
            deliverMode: text(s, 19), delivered: text(s, 20), status: text(s, 21) ?? "ok")
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Calls back on the main queue — on every path, failure included, so a
    /// caller waiting on it (a disabled Clear button) is never left waiting.
    private func finish(_ completion: (() -> Void)?) {
        if let completion { DispatchQueue.main.async(execute: completion) }
    }

    private func notifyChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .historyDidChange, object: self) }
    }

    private func onQueue<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
