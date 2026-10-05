import Foundation

/// Thread-safe append-only file logger.
///
/// Writes to `~/Library/Logs/<AppName>/<AppName>.log` — the name follows the
/// bundle, so a Debug build never writes into the Release build's log. Use one
/// instance per component (the `category` shows up in every line):
///
///     private static let log = FileLog("LaunchManager")
///     Self.log.info("started up")
///     Self.log.error("failed: \(error)")
///
/// Tail live with: `tail -F "$(ls -td ~/Library/Logs/*/ | head -1)"*.log`
final class FileLog {

    private let category: String

    init(_ category: String = "App") {
        self.category = category
    }

    func debug(_ message: @autoclosure @escaping () -> String) { write("DEBUG", message) }
    func info (_ message: @autoclosure @escaping () -> String) { write("INFO",  message) }
    func warn (_ message: @autoclosure @escaping () -> String) { write("WARN",  message) }
    func error(_ message: @autoclosure @escaping () -> String) { write("ERROR", message) }

    /// The on-disk log path. Exposed for diagnostics / "Reveal log in Finder".
    static var url: URL { Self.logURL }

    // MARK: - Internals

    private static let queue = DispatchQueue(label: "\(Brand.baseID).filelog", qos: .utility)

    private static let logURL: URL = {
        let dir = Brand.logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(Brand.name).log")
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func write(_ level: String, _ messageProducer: @escaping () -> String) {
        let cat = category
        Self.queue.async {
            let line = "[\(Self.timeFormatter.string(from: Date()))] [\(level)] [\(cat)] \(messageProducer())\n"
            guard let data = line.data(using: .utf8) else { return }
            let url = Self.logURL
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
