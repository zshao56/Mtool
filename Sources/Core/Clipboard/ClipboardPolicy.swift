import Foundation

/// The numbers the clipboard store obeys, kept as plain values (not read from
/// the config here) so the eviction and de-duplication rules are pure functions
/// the unit tests can exercise without a database or a config file.
struct ClipboardPolicy: Equatable {
    /// Maximum number of non-pinned history rows. 0 disables the cap.
    var maxItems: Int
    /// Days a row is kept. 0 keeps everything until the cap evicts it.
    var retentionDays: Int
    /// Largest image, in bytes, that will be stored. 0 stores no images.
    var maxImageBytes: Int

    static let `default` = ClipboardPolicy(maxItems: 500, retentionDays: 30,
                                           maxImageBytes: 20 * 1024 * 1024)

    var maxItemsRange: ClosedRange<Int> { 10...5000 }
    var retentionDaysRange: ClosedRange<Int> { 0...365 }

    /// A policy with its values clamped to the allowed ranges, so a hand-edited
    /// config file cannot put the store into a state it cannot recover from.
    var clamped: ClipboardPolicy {
        ClipboardPolicy(
            maxItems: max(0, min(maxItems, maxItemsRange.upperBound)),
            retentionDays: max(0, min(retentionDays, retentionDaysRange.upperBound)),
            maxImageBytes: max(0, maxImageBytes))
    }
}

/// Pure policy decisions, split from the store so they are testable in isolation.
enum ClipboardPolicyEngine {

    /// Whether an image of `byteCount` bytes should be kept at all.
    static func shouldStoreImage(byteCount: Int, policy: ClipboardPolicy) -> Bool {
        let p = policy.clamped
        return p.maxImageBytes > 0 && byteCount >= 0 && byteCount <= p.maxImageBytes
    }

    /// Whether an item created at `createdAt` has outlived the retention window.
    /// Pinned items are handled by the caller (they are never passed here).
    static func isExpired(createdAt: Date, now: Date, policy: ClipboardPolicy) -> Bool {
        let p = policy.clamped
        guard p.retentionDays > 0 else { return false }
        let cutoff = now.addingTimeInterval(-Double(p.retentionDays) * 86_400)
        return createdAt < cutoff
    }

    /// How many of the OLDEST non-pinned rows must be evicted given the current
    /// number of stored non-pinned rows (after an insert).
    static func overflowCount(nonPinnedStored: Int, policy: ClipboardPolicy) -> Int {
        let p = policy.clamped
        guard p.maxItems > 0 else { return 0 }
        return max(0, nonPinnedStored - p.maxItems)
    }

    /// The key a piece of content de-duplicates on. Text and URLs use their text;
    /// images use a digest supplied by the caller. Two entries with the same key
    /// are the same clipboard content and only the newest copy is kept.
    static func dedupeKey(kind: ClipboardItemKind, text: String?, imageDigest: String?) -> String {
        switch kind {
        case .text, .url:
            return "\(kind.rawValue):\(text ?? "")"
        case .image:
            return "image:\(imageDigest ?? "")"
        }
    }

    /// Whether two captured entries are the same content.
    static func isDuplicate(_ a: ClipboardItem, _ b: ClipboardItem) -> Bool {
        a.contentHash == b.contentHash
    }
}
