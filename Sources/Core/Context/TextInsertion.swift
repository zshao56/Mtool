import Foundation

/// Pure text insertion used when a clipboard entry is written through the
/// accessibility `AXValue` path.
///
/// The rule this exists to enforce: **never append blindly**. An `AXValue` write
/// is only position-correct when the app also told us where the caret / selection
/// is. This helper does the actual splice into a known UTF-16 range, and returns
/// nil for any range that is not a valid position in the text, so the caller can
/// fall back to a safe path instead of writing something in the wrong place.
///
/// Accessibility text ranges are expressed in UTF-16 offsets (the same units as
/// `NSRange` over an `NSString`), which is why the math below works on
/// `utf16` and not on `Character` counts — a CJK or emoji string would otherwise
/// be off by a different amount per code point.
enum TextInsertion {

    /// Insert `insertion` into `existing`, replacing the UTF-16 range `range`
    /// (a zero-length range inserts at the caret). Returns nil when the range
    /// does not fit the text.
    static func insert(_ insertion: String, into existing: String, atUTF16 range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let units = Array(existing.utf16)
        let end = range.location + range.length
        guard range.location <= units.count, end <= units.count else { return nil }

        var out = Array(units[0..<range.location])
        out.append(contentsOf: insertion.utf16)
        out.append(contentsOf: units[end...])
        return String(decoding: out, as: UTF16.self)
    }
}
