import Foundation

/// The app's settings, as one file the user is meant to open and edit.
///
///     ~/.config/<slug>/config.json
///
/// `~/.config` rather than Application Support because the point is that this
/// file can be read, diffed, symlinked into a dotfiles repo and committed.
/// Application Support is hidden in Finder by default and is where apps put
/// things people are not supposed to touch; this is the opposite of that.
///
/// **Secrets never go in here.** API keys stay in the Keychain (`LLMKeyStore`)
/// precisely so this file is safe to commit.
///
/// The file is read ONCE, at launch. Editing it by hand takes effect the next
/// time the app starts — which is the deal, and it is worth what it saves. An app
/// that follows the file live has two ways for a setting to change, and every
/// setting with a side effect then needs its effect wired up twice: once for the
/// settings window, once for the reload. Miss one and a hand edit quietly does
/// nothing. Reading once means there is only ever one way in.
///
/// The document is held as a `JSONValue` tree rather than a typed struct, so a
/// key this build does not recognise is preserved rather than deleted on the next
/// save — see `JSONValue` for why that matters.
///
/// **Main thread only, including the disk work.** An earlier version wrote on a
/// background queue and grew a race at every step: the bytes it had promised were
/// on disk were not there yet, a reload could read the old file and undo a change,
/// quitting could kill the process before the write ran, and two file watches were
/// mutated from two threads at once. The file is a few kilobytes and a write is
/// debounced to at most one every 0.4s, so doing it in line costs nothing
/// measurable and removes all of that.
final class ConfigStore: ObservableObject {

    static let shared = ConfigStore()

    private static let log = FileLog("Config")

    /// The whole file. Read through the typed accessors below.
    @Published private(set) var document: JSONValue = .object([:])

    /// The path as configured — which may be a symlink into a dotfiles repo.
    var fileURL: URL { Brand.configDirectory.appendingPathComponent("config.json") }

    /// Where the bytes actually live. Everything that touches the file resolves
    /// this FIRST, because an atomic write to a symlink REPLACES THE SYMLINK with
    /// a regular file: the dotfiles copy would keep the old contents and the two
    /// would silently drift apart. Re-resolved every time, since the link can be
    /// re-pointed while the app is running.
    private var resolvedFileURL: URL { fileURL.resolvingSymlinksInPath() }

    /// Exactly the bytes we last wrote or last successfully read. Content identity
    /// is the loop breaker: a file whose bytes are these is one we already know
    /// about, whoever wrote it.
    private var lastKnownBytes: Data?

    private var saveWorkItem: DispatchWorkItem?

    /// How long to sit on a change before writing. Dragging a slider produces a
    /// change per frame; without this the file would be rewritten sixty times a
    /// second and an editor watching it would flicker.
    private static let saveDebounce: TimeInterval = 0.4

    private init() {
        load()
        writeSchema()
    }

    // MARK: - Reading

    func bool(_ path: String, default fallback: Bool) -> Bool {
        document[path: path]?.boolValue ?? fallback
    }

    func double(_ path: String, default fallback: Double) -> Double {
        document[path: path]?.doubleValue ?? fallback
    }

    func string(_ path: String, default fallback: String) -> String {
        document[path: path]?.stringValue ?? fallback
    }

    /// Nil for both "absent" and "explicitly null", which is what the one setting
    /// that needs it means: `general.language: null` is "follow the system".
    func optionalString(_ path: String) -> String? {
        guard let value = document[path: path], !value.isNull else { return nil }
        return value.stringValue
    }

    /// The strings of an array setting. A non-string element is skipped rather
    /// than failing the whole list — one typo must not empty it.
    func stringArray(_ path: String) -> [String] {
        (document[path: path]?.arrayValue ?? []).compactMap { $0.stringValue }
    }

    func value(_ path: String) -> JSONValue? { document[path: path] }

    // MARK: - Writing

    func set(_ path: String, _ value: JSONValue) {
        guard document[path: path] != value else { return }   // no-op writes must not dirty the file
        document.set(path: path, to: value)
        scheduleSave()
    }

    func set(_ path: String, _ value: Bool)   { set(path, .bool(value)) }
    func set(_ path: String, _ value: Double) { set(path, .number(value)) }
    func set(_ path: String, _ value: String) { set(path, .string(value)) }
    func set(_ path: String, _ value: [String]) { set(path, .array(value.map(JSONValue.string))) }

    /// Clears a setting back to "unset". Used for "follow the system", which is
    /// meaningfully different from any particular value.
    func setNull(_ path: String) { set(path, .null) }

    /// Write now rather than on the debounce. Called at termination, where there
    /// is no later — which is why the write is synchronous: an asynchronous one
    /// would still be sitting in a queue when the process goes away.
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        writeNow()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveWorkItem = nil
            self?.writeNow()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: item)
    }

    private func writeNow() {
        guard let data = encoded() else { return }
        guard data != lastKnownBytes else { return }          // nothing actually changed

        let url = resolvedFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)

            // Somebody edited the file since we last read it and we are about to
            // overwrite them. Their version is kept, always — losing an edit
            // someone typed is not a thing to trade for tidiness.
            if let onDisk = try? Data(contentsOf: url), onDisk != lastKnownBytes {
                let backup = url.appendingPathExtension("bak-" + Self.timestamp())
                try? onDisk.write(to: backup, options: .atomic)
                Self.log.warn("the config changed underneath us — kept that version as \(backup.lastPathComponent) before writing")
            }

            // Atomic: a crash mid-write must not leave a truncated config, and an
            // editor watching the file must never see a partial document.
            try data.write(to: url, options: .atomic)
            // Only NOW is this true. Recording it before the write meant a failed
            // write left the app believing the file said something it did not, and
            // every later save was skipped as "unchanged".
            lastKnownBytes = data
        } catch {
            Self.log.error("could not write \(url.path): \(error)")
        }
    }

    private func encoded() -> Data? {
        let encoder = JSONEncoder()
        // Sorted keys so a save produces a MINIMAL git diff instead of reshuffling
        // the whole file; pretty-printed because a person reads it.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(document)
            data.append(0x0A)   // POSIX trailing newline, so the last line diffs like any other
            return data
        } catch {
            Self.log.error("could not encode the config: \(error)")
            return nil
        }
    }

    // MARK: - Loading

    /// Whether a config file was already on disk when the app started, as opposed
    /// to one seeded from defaults just now. The first-run check needs this: by
    /// the time it runs, a seeded file already holds the default actions, so
    /// "the config has actions" alone cannot tell a new install from one whose
    /// config was brought from another Mac.
    private(set) var fileExistedAtLaunch = false

    private func load() {
        let url = resolvedFileURL
        fileExistedAtLaunch = FileManager.default.fileExists(atPath: url.path)
        guard let data = try? Data(contentsOf: url) else {
            // No file yet: build one from the defaults plus whatever the app has
            // already stored in UserDefaults, so nothing is lost on the way over.
            document = ConfigSeed.initialDocument()
            Self.log.info("no config at \(url.path) — seeding a new one")
            writeNow()
            return
        }
        guard let decoded = decode(data) else {
            document = ConfigSeed.initialDocument()
            lastKnownBytes = nil
            return
        }
        document = decoded
        lastKnownBytes = data
        Self.log.info("loaded \(url.path)")
    }

    // `popup.enabled` used to be retired here (removed on every load) after the
    // on/off switch went away in 0a0cbee. The pause (a0ab948) brought the key
    // back with a new meaning, and the retirement kept deleting it — a pause was
    // silently undone on every launch. Retirement is gone; the key is live.

    /// Decode, or keep a copy of what could not be read and return nil.
    ///
    /// NEVER overwrite an unreadable file with defaults: it is the user's work,
    /// and the mistake in it is probably one comma.
    private func decode(_ data: Data) -> JSONValue? {
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              decoded.objectValue != nil else {
            let url = resolvedFileURL
            let backup = url.appendingPathExtension("bad-" + Self.timestamp())
            try? data.write(to: backup, options: .atomic)
            Self.log.error("\(url.lastPathComponent) is not valid JSON — kept a copy as \(backup.lastPathComponent), running from the last good settings")
            return nil
        }
        return decoded
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: - Schema

    /// Write the schema beside the config and point at it from the document.
    ///
    /// JSON has no comments, which is the one real cost of choosing it. A schema
    /// buys back more than comments would: an editor gives completion for every
    /// key, the allowed values of an enum, and the documentation on hover — and
    /// unlike comments it survives the app rewriting the file.
    ///
    /// Written beside the RESOLVED file, so a config symlinked into a dotfiles
    /// repo gets its schema in that repo too, and the relative `$schema` reference
    /// resolves from either path.
    private func writeSchema() {
        let url = resolvedFileURL.deletingLastPathComponent()
            .appendingPathComponent("config.schema.json")
        guard let data = ConfigSchema.json.data(using: .utf8) else { return }
        // Only when it differs, so an unchanged schema does not touch the mtime of
        // a file sitting in a git repo.
        if let existing = try? Data(contentsOf: url), existing == data { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("could not write the schema: \(error)")
        }
    }
}
