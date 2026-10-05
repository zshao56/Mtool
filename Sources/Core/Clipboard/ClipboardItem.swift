import Foundation

/// The kinds of clipboard content Mtool stores. Everything else is ignored on
/// purpose (rtf, html, file lists, PDFs …): the first version keeps text, links
/// and images only, which is what the panel can search and paste reliably.
enum ClipboardItemKind: String, Codable, CaseIterable {
    case text
    case url
    case image

    /// The nspasteboard.org / AppKit flavor this kind came from, for logging.
    var label: String {
        switch self {
        case .text:  return "text"
        case .url:   return "url"
        case .image: return "image"
        }
    }
}

/// One stored clipboard entry. `id` is the SQLite rowid (0 until inserted).
struct ClipboardItem: Identifiable, Equatable {
    var id: Int64
    var kind: ClipboardItemKind
    /// The text (or the link string) for `.text` / `.url`; nil for images.
    var text: String?
    /// Path to the PNG for `.image`; nil otherwise. Relative to the clipboard
    /// support directory, so the store can be moved without rewriting rows.
    var blobPath: String?
    /// A short, searchable label for an image (e.g. "Image 1440 × 900").
    var preview: String?
    var sourceBundleID: String?
    var createdAt: Date
    var lastUsedAt: Date?
    var pinned: Bool
    /// Content identity for de-duplication: for text/url the text itself, for an
    /// image a digest of the PNG bytes.
    var contentHash: String

    init(id: Int64 = 0,
         kind: ClipboardItemKind,
         text: String? = nil,
         blobPath: String? = nil,
         preview: String? = nil,
         sourceBundleID: String? = nil,
         createdAt: Date = Date(),
         lastUsedAt: Date? = nil,
         pinned: Bool = false,
         contentHash: String) {
        self.id = id
        self.kind = kind
        self.text = text
        self.blobPath = blobPath
        self.preview = preview
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.pinned = pinned
        self.contentHash = contentHash
    }

    /// What the panel's list shows for this row.
    var displayText: String {
        switch kind {
        case .image: return preview ?? "Image"
        case .text, .url: return text ?? preview ?? ""
        }
    }

    /// A single-line, length-capped form for a list row.
    func singleLine(limit: Int = 200) -> String {
        let cleaned = displayText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "⏎")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count <= limit ? cleaned : String(cleaned.prefix(limit)) + "…"
    }
}

/// A user-saved text fragment ("常用词"). Snippets are separate from history and
/// are never removed by retention or capacity pruning; the panel pins them above
/// the history.
struct Snippet: Identifiable, Equatable {
    var id: Int64
    var title: String
    var text: String
    var sortOrder: Int
    var createdAt: Date

    init(id: Int64 = 0, title: String, text: String, sortOrder: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
