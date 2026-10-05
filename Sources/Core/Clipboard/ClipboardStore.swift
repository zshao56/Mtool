import Foundation
import SQLite3
import CryptoKit

extension Notification.Name {
    /// Posted on the main queue after this process changed the clipboard store.
    static let clipboardDidChange = Notification.Name("ClipboardDidChange")
}

/// The local clipboard history and the user's snippets ("常用词"), in one SQLite
/// file under the app's shared support directory. Deliberately separate from
/// `HistoryStore`, which records AI action runs — the two share nothing but the
/// SQLite plumbing.
///
/// Privacy contract:
/// - everything is local; nothing is ever sent to a model or a server;
/// - secure/password content is never captured (the watcher's job, upstream);
/// - the store never logs content, only counts and kinds;
/// - images live as PNG files next to the database, the row holds the path.
///
/// Same conventions as `HistoryStore`: migrations ADD only, keyed by
/// `PRAGMA user_version`; one serial queue; value snapshots for the UI.
final class ClipboardStore {

    /// `MTOOL_CLIPBOARD_DB` points a build at a scratch copy for tests.
    static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["MTOOL_CLIPBOARD_DB"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Brand.sharedSupportDirectory.appendingPathComponent("clipboard.sqlite")
    }

    static let shared = ClipboardStore(url: ClipboardStore.defaultURL)

    /// The newest schema this build knows.
    static let schemaVersion: Int32 = 1

    let url: URL
    private let queue = DispatchQueue(label: "ClipboardStore", qos: .utility)
    private var db: OpaquePointer?
    private var opened = false
    private(set) var hasFullTextIndex = false
    private static let log = FileLog("Clipboard")

    init(url: URL) {
        self.url = url
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Writing history

    /// Insert a new entry, de-duplicating against existing content. Returns the
    /// rowid of the (possibly pre-existing) row on success. `policy` is applied
    /// afterwards by the caller via `prune`.
    @discardableResult
    func insert(_ item: ClipboardItem) -> Int64? {
        queue.sync {
            guard open() else { return nil }
            let result: Int64? = writing { () -> Int64? in
                // De-dupe: if this exact content is already stored, refresh it and
                // move it to the top instead of adding a second row.
                if let existing = self.rowID(forHash: item.contentHash) {
                    guard let stmt = self.prepare(
                        "UPDATE clipboard_items SET created_at = ?, last_used_at = ? WHERE id = ?")
                    else { return existing }
                    defer { sqlite3_finalize(stmt) }
                    self.bind([.int(Self.ms(item.createdAt)), .int(Self.ms(item.createdAt)), .int(existing)], to: stmt)
                    _ = sqlite3_step(stmt)
                    return existing
                }
                let sql = """
                INSERT INTO clipboard_items
                  (kind, text, blob_path, preview, source_bundle_id, created_at, last_used_at, pinned, content_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
                guard let stmt = self.prepare(sql) else { return nil }
                defer { sqlite3_finalize(stmt) }
                self.bind([
                    .text(item.kind.rawValue), .optText(item.text), .optText(item.blobPath),
                    .optText(item.preview), .optText(item.sourceBundleID),
                    .int(Self.ms(item.createdAt)), .optInt(item.lastUsedAt.map(Self.ms)),
                    .int(item.pinned ? 1 : 0), .text(item.contentHash),
                ], to: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    self.logError("insert")
                    return nil
                }
                return sqlite3_last_insert_rowid(self.db)
            }
            if result != nil { notifyChanged() }
            return result
        }
    }

    func setPinned(id: Int64, pinned: Bool) {
        queue.async {
            guard self.open() else { return }
            let changed = self.writing { () -> Bool in
                guard let stmt = self.prepare("UPDATE clipboard_items SET pinned = ? WHERE id = ?") else { return false }
                defer { sqlite3_finalize(stmt) }
                self.bind([.int(pinned ? 1 : 0), .int(id)], to: stmt)
                return sqlite3_step(stmt) == SQLITE_DONE
            }
            if changed == true { self.notifyChanged() }
        }
    }

    func markUsed(id: Int64, at date: Date = Date()) {
        queue.async {
            guard self.open() else { return }
            _ = self.writing { () -> Bool in
                guard let stmt = self.prepare("UPDATE clipboard_items SET last_used_at = ? WHERE id = ?") else { return false }
                defer { sqlite3_finalize(stmt) }
                self.bind([.int(Self.ms(date)), .int(id)], to: stmt)
                return sqlite3_step(stmt) == SQLITE_DONE
            }
        }
    }

    /// Delete one row and its image file (if any).
    func delete(id: Int64) {
        queue.async {
            guard self.open() else { return }
            let changed = self.writing { () -> Bool in
                if let item = self.item(id: id), let path = item.blobPath { self.removeBlob(path) }
                guard let stmt = self.prepare("DELETE FROM clipboard_items WHERE id = ?") else { return false }
                defer { sqlite3_finalize(stmt) }
                self.bind([.int(id)], to: stmt)
                return sqlite3_step(stmt) == SQLITE_DONE
            }
            if changed == true { self.notifyChanged() }
        }
    }

    /// Delete every non-pinned row. Pinned items and snippets survive.
    func clearHistory(completion: (() -> Void)? = nil) {
        queue.async {
            guard self.open() else { return self.finish(completion) }
            _ = self.writing { () -> Bool in
                for path in self.nonPinnedBlobPaths() { self.removeBlob(path) }
                return self.exec("DELETE FROM clipboard_items WHERE pinned = 0")
            }
            if self.hasFullTextIndex { _ = self.exec("INSERT INTO clipboard_items_fts(clipboard_items_fts) VALUES('rebuild')") }
            _ = self.exec("VACUUM")
            Self.log.info("clipboard history cleared")
            self.notifyChanged()
            self.finish(completion)
        }
    }

    // MARK: - Pruning

    /// Apply retention and capacity. Pinned rows are never touched. Returns the
    /// number of rows removed; also removes their orphan image files.
    @discardableResult
    func prune(policy: ClipboardPolicy, now: Date = Date()) -> Int {
        queue.sync {
            guard open() else { return 0 }
            let p = policy.clamped
            var removed = 0
            _ = writing { () -> Bool in
                if p.retentionDays > 0 {
                    let cutoff = now.addingTimeInterval(-Double(p.retentionDays) * 86_400)
                    if let stmt = self.prepare(
                        "SELECT id, blob_path FROM clipboard_items WHERE pinned = 0 AND created_at < ?") {
                        defer { sqlite3_finalize(stmt) }
                        self.bind([.int(Self.ms(cutoff))], to: stmt)
                        var ids: [Int64] = []
                        while sqlite3_step(stmt) == SQLITE_ROW {
                            ids.append(sqlite3_column_int64(stmt, 0))
                            if let c = sqlite3_column_text(stmt, 1) { self.removeBlob(String(cString: c)) }
                        }
                        removed += self.deleteRows(ids)
                    }
                }
                if p.maxItems > 0 {
                    // Keep the newest maxItems non-pinned rows; delete the rest.
                    let overflow = self.nonPinnedCount() - p.maxItems
                    if overflow > 0 {
                        if let stmt = self.prepare(
                            "SELECT id, blob_path FROM clipboard_items WHERE pinned = 0 ORDER BY created_at ASC, id ASC LIMIT ?") {
                            defer { sqlite3_finalize(stmt) }
                            self.bind([.int(Int64(overflow))], to: stmt)
                            var ids: [Int64] = []
                            while sqlite3_step(stmt) == SQLITE_ROW {
                                ids.append(sqlite3_column_int64(stmt, 0))
                                if let c = sqlite3_column_text(stmt, 1) { self.removeBlob(String(cString: c)) }
                            }
                            removed += self.deleteRows(ids)
                        }
                    }
                }
                return true
            }
            if removed > 0 { Self.log.info("pruned \(removed) clipboard row(s)"); notifyChanged() }
            return removed
        }
    }

    private func nonPinnedCount() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM clipboard_items WHERE pinned = 0") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func deleteRows(_ ids: [Int64]) -> Int {
        guard !ids.isEmpty else { return 0 }
        let list = ids.map(String.init).joined(separator: ",")
        return exec("DELETE FROM clipboard_items WHERE id IN (\(list))") ? ids.count : 0
    }

    // MARK: - Reading

    /// The newest entries matching an optional text query. Pinned rows are
    /// returned first (newest first within each group).
    func items(matching query: String = "", limit: Int = 200) -> [ClipboardItem] {
        queue.sync {
            guard open() else { return [] }
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var clause = ""
            var values: [SQLValue] = []
            if !text.isEmpty {
                let like = "%" + text.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_") + "%"
                if hasFullTextIndex, text.count >= 3 {
                    let phrase = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    clause = "WHERE (id IN (SELECT rowid FROM clipboard_items_fts WHERE clipboard_items_fts MATCH ?) OR text LIKE ? ESCAPE '\\' OR preview LIKE ? ESCAPE '\\')"
                    values += [.text(phrase), .text(like), .text(like)]
                } else {
                    clause = "WHERE (text LIKE ? ESCAPE '\\' OR preview LIKE ? ESCAPE '\\')"
                    values += [.text(like), .text(like)]
                }
            }
            values.append(.int(Int64(limit)))
            let sql = """
            SELECT id, kind, text, blob_path, preview, source_bundle_id, created_at, last_used_at, pinned, content_hash
            FROM clipboard_items \(clause)
            ORDER BY pinned DESC, created_at DESC, id DESC LIMIT ?
            """
            guard let stmt = prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(values, to: stmt)
            var out: [ClipboardItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(Self.read(stmt)) }
            return out
        }
    }

    func item(id: Int64) -> ClipboardItem? {
        guard open(), let stmt = prepare(
            "SELECT id, kind, text, blob_path, preview, source_bundle_id, created_at, last_used_at, pinned, content_hash FROM clipboard_items WHERE id = ?")
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind([.int(id)], to: stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? Self.read(stmt) : nil
    }

    func count() -> Int {
        queue.sync {
            guard open(), let stmt = prepare("SELECT COUNT(*) FROM clipboard_items") else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    // MARK: - Snippets

    @discardableResult
    func upsertSnippet(_ snippet: Snippet) -> Int64? {
        queue.sync {
            guard open() else { return nil }
            let id: Int64? = writing { () -> Int64? in
                if snippet.id > 0 {
                    guard let stmt = self.prepare(
                        "UPDATE snippets SET title = ?, text = ?, sort_order = ? WHERE id = ?") else { return nil }
                    defer { sqlite3_finalize(stmt) }
                    self.bind([.text(snippet.title), .text(snippet.text), .int(Int64(snippet.sortOrder)), .int(snippet.id)], to: stmt)
                    return sqlite3_step(stmt) == SQLITE_DONE ? snippet.id : nil
                }
                let order = snippet.sortOrder != 0 ? snippet.sortOrder : self.nextSnippetOrder()
                guard let stmt = self.prepare(
                    "INSERT INTO snippets (title, text, sort_order, created_at) VALUES (?, ?, ?, ?)") else { return nil }
                defer { sqlite3_finalize(stmt) }
                self.bind([.text(snippet.title), .text(snippet.text), .int(Int64(order)), .int(Self.ms(snippet.createdAt))], to: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
                return sqlite3_last_insert_rowid(self.db)
            }
            if id != nil { notifyChanged() }
            return id
        }
    }

    func snippets() -> [Snippet] {
        queue.sync {
            guard open(), let stmt = prepare(
                "SELECT id, title, text, sort_order, created_at FROM snippets ORDER BY sort_order ASC, id ASC")
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [Snippet] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Snippet(
                    id: sqlite3_column_int64(stmt, 0),
                    title: Self.text(stmt, 1) ?? "",
                    text: Self.text(stmt, 2) ?? "",
                    sortOrder: Int(sqlite3_column_int64(stmt, 3)),
                    createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)) / 1000)))
            }
            return out
        }
    }

    func deleteSnippet(id: Int64) {
        queue.async {
            guard self.open() else { return }
            let changed = self.writing { () -> Bool in
                guard let stmt = self.prepare("DELETE FROM snippets WHERE id = ?") else { return false }
                defer { sqlite3_finalize(stmt) }
                self.bind([.int(id)], to: stmt)
                return sqlite3_step(stmt) == SQLITE_DONE
            }
            if changed == true { self.notifyChanged() }
        }
    }

    /// Persist a new snippet order. `ordered` is the full list as the user wants
    /// it; each row's `sort_order` is rewritten to its index. Unknown ids are
    /// ignored, so a stale list cannot delete anything.
    func reorderSnippets(_ ordered: [Snippet]) {
        queue.sync {
            guard open() else { return }
            _ = writing { () -> Bool in
                for (index, snippet) in ordered.enumerated() {
                    guard let stmt = self.prepare("UPDATE snippets SET sort_order = ? WHERE id = ?") else { continue }
                    defer { sqlite3_finalize(stmt) }
                    self.bind([.int(Int64(index)), .int(snippet.id)], to: stmt)
                    if sqlite3_step(stmt) != SQLITE_DONE { return false }
                }
                return true
            }
            self.notifyChanged()
        }
    }

    private func nextSnippetOrder() -> Int {
        guard let stmt = prepare("SELECT COALESCE(MAX(sort_order), 0) + 1 FROM snippets") else { return 1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 1
    }

    // MARK: - Files

    /// The directory image blobs live in (next to the database).
    var blobDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("clipboard-images", isDirectory: true) }

    /// Absolute URL for a stored relative blob path.
    func blobURL(for path: String) -> URL { blobDirectory.appendingPathComponent(path) }

    private func removeBlob(_ relative: String) {
        try? FileManager.default.removeItem(at: blobURL(for: relative))
    }

    private func nonPinnedBlobPaths() -> [String] {
        guard let stmt = prepare("SELECT blob_path FROM clipboard_items WHERE pinned = 0 AND blob_path IS NOT NULL") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    // MARK: - Lifecycle

    func flush() { queue.sync {} }

    // MARK: - Opening and migrating

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
        Self.log.error("clipboard file unreadable — moved aside as .bad-\(stamp), starting a new one")
        return openAndMigrate()
    }

    private func openAndMigrate() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true)
        } catch {
            Self.log.error("cannot create the clipboard folder: \(error.localizedDescription)")
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
        guard let current = userVersion() else { return false }
        if current > Self.schemaVersion {
            Self.log.warn("clipboard file is schema \(current), this build knows \(Self.schemaVersion) — using it as is")
        } else if current < Self.schemaVersion {
            let ok = writing { () -> Bool in
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
        hasFullTextIndex = tableExists("clipboard_items_fts")
        return true
    }

    private func migrate(to version: Int32) -> Bool {
        switch version {
        case 1:
            let schema = """
            CREATE TABLE IF NOT EXISTS clipboard_items (
              id INTEGER PRIMARY KEY,
              kind TEXT NOT NULL,
              text TEXT,
              blob_path TEXT,
              preview TEXT,
              source_bundle_id TEXT,
              created_at INTEGER NOT NULL,
              last_used_at INTEGER,
              pinned INTEGER NOT NULL DEFAULT 0,
              content_hash TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS clipboard_created ON clipboard_items(created_at);
            CREATE INDEX IF NOT EXISTS clipboard_hash ON clipboard_items(content_hash);
            CREATE INDEX IF NOT EXISTS clipboard_pinned ON clipboard_items(pinned, created_at);
            CREATE TABLE IF NOT EXISTS snippets (
              id INTEGER PRIMARY KEY,
              title TEXT NOT NULL,
              text TEXT NOT NULL,
              sort_order INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS snippets_order ON snippets(sort_order);
            """
            guard exec(schema) else { return false }
            let fts = """
            CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_items_fts USING fts5(text, preview,
              content='clipboard_items', content_rowid='id', tokenize='trigram');
            CREATE TRIGGER IF NOT EXISTS clipboard_ai AFTER INSERT ON clipboard_items BEGIN
              INSERT INTO clipboard_items_fts(rowid, text, preview) VALUES (new.id, new.text, new.preview);
            END;
            CREATE TRIGGER IF NOT EXISTS clipboard_ad AFTER DELETE ON clipboard_items BEGIN
              INSERT INTO clipboard_items_fts(clipboard_items_fts, rowid, text, preview) VALUES ('delete', old.id, old.text, old.preview);
            END;
            CREATE TRIGGER IF NOT EXISTS clipboard_au AFTER UPDATE OF text, preview ON clipboard_items BEGIN
              INSERT INTO clipboard_items_fts(clipboard_items_fts, rowid, text, preview) VALUES ('delete', old.id, old.text, old.preview);
              INSERT INTO clipboard_items_fts(rowid, text, preview) VALUES (new.id, new.text, new.preview);
            END;
            """
            if !exec(fts, quiet: true) { Self.log.warn("FTS5 trigram index unavailable — search falls back to LIKE") }
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

    private static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

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

    private func rowID(forHash hash: String) -> Int64? {
        guard let stmt = prepare("SELECT id FROM clipboard_items WHERE content_hash = ? LIMIT 1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind([.text(hash)], to: stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private func logError(_ what: String) {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
        let code = db.map { sqlite3_errcode($0) } ?? -1
        Self.log.error("\(what) failed (\(code)): \(message)")
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: c)
    }

    private static func read(_ s: OpaquePointer) -> ClipboardItem {
        func int(_ c: Int32) -> Int64? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : sqlite3_column_int64(s, c) }
        let kind = ClipboardItemKind(rawValue: text(s, 1) ?? "text") ?? .text
        return ClipboardItem(
            id: sqlite3_column_int64(s, 0),
            kind: kind,
            text: text(s, 2),
            blobPath: text(s, 3),
            preview: text(s, 4),
            sourceBundleID: text(s, 5),
            createdAt: Date(timeIntervalSince1970: Double(int(6) ?? 0) / 1000),
            lastUsedAt: int(7).map { Date(timeIntervalSince1970: Double($0) / 1000) },
            pinned: (int(8) ?? 0) != 0,
            contentHash: text(s, 9) ?? "")
    }

    /// SHA-256 used for both text and image identity.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func finish(_ completion: (() -> Void)?) {
        if let completion { DispatchQueue.main.async(execute: completion) }
    }

    private func notifyChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .clipboardDidChange, object: self) }
    }
}
