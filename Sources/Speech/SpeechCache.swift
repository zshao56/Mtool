import Foundation
import CryptoKit

/// Finished reads on disk, so reading the same text with the same reader again
/// plays locally instead of asking the provider (and paying) twice.
///
/// One read = `<key>.pcm` (16-bit PCM exactly as streamed) + `<key>.json`
/// (format and word timings). The key hashes the reader's sound-defining
/// settings with the text, so changing voice or speed is a different entry.
/// Only complete reads are written — a read stopped halfway is not a cache
/// entry. Least recently played entries are removed once the total passes the
/// limit; playing an entry touches its date.
final class SpeechCache {
    static let shared = SpeechCache()
    static let limitBytes: Int64 = 500 * 1024 * 1024

    struct Entry: Codable {
        var format: TTSAudioFormat
        var marks: [TextMark]
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "SpeechCache", qos: .utility)
    private static let log = FileLog("Speech.Cache")

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Brand.name, isDirectory: true)
            .appendingPathComponent("Speech", isDirectory: true)
    }

    static func key(reader: SpeechReader, text: String) -> String {
        let digest = SHA256.hash(data: Data((reader.cacheIdentity + "\n" + text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The cached read, or nil. Touches the entry so it counts as recently used.
    func load(key: String) -> (entry: Entry, pcm: Data)? {
        let meta = directory.appendingPathComponent("\(key).json")
        let audio = directory.appendingPathComponent("\(key).pcm")
        guard let json = try? Data(contentsOf: meta),
              let entry = try? JSONDecoder().decode(Entry.self, from: json),
              let pcm = try? Data(contentsOf: audio), !pcm.isEmpty else { return nil }
        let now = Date()
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: meta.path)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: audio.path)
        return (entry, pcm)
    }

    func store(key: String, entry: Entry, pcm: Data) {
        queue.async { [directory] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Audio first, metadata last: an entry only counts once its
                // .json exists, so a crash in between leaves no half entry.
                try pcm.write(to: directory.appendingPathComponent("\(key).pcm"), options: .atomic)
                try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
                self.prune()
            } catch {
                Self.log.error("cache write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Total bytes on disk.
    func size() -> Int64 {
        files().reduce(0) { $0 + $1.size }
    }

    func clear() {
        queue.sync {
            for file in files() { try? FileManager.default.removeItem(at: file.url) }
        }
        Self.log.info("cache cleared")
    }

    private struct File { let url: URL; let size: Int64; let date: Date }

    private func files() -> [File] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return File(url: url, size: Int64(values?.fileSize ?? 0), date: values?.contentModificationDate ?? .distantPast)
        }
    }

    /// Delete whole entries, least recently used first, until under the limit.
    private func prune() {
        let all = files()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > Self.limitBytes else { return }
        let entries = Dictionary(grouping: all) { $0.url.deletingPathExtension().lastPathComponent }
            .map { (files: $0.value, date: $0.value.map(\.date).max() ?? .distantPast) }
            .sorted { $0.date < $1.date }
        for entry in entries where total > Self.limitBytes {
            for file in entry.files {
                try? FileManager.default.removeItem(at: file.url)
                total -= file.size
            }
        }
        Self.log.info("cache pruned to \(total / 1024 / 1024) MB")
    }
}
