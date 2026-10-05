import Foundation

extension String {
    /// True when a captured "selection" has nothing a person could act on: it is
    /// empty, or only whitespace, line breaks and invisible characters.
    ///
    /// Chrome is the case that needs this. Double-click an empty spot on a page and
    /// Accessibility reports no selection, yet the Copy command stays enabled, and
    /// ⌘C puts a single line break (U+000A) on the clipboard. That one character used
    /// to count as a selection and open the popup over nothing.
    var isBlankSelection: Bool {
        unicodeScalars.allSatisfy { u in
            if CharacterSet.whitespacesAndNewlines.contains(u) { return true }
            switch u.properties.generalCategory {
            // Zero-width space/joiners, BOM, soft hyphen, bidi marks; control characters.
            case .format, .control: return true
            default: break
            }
            // Object replacement character: an image or attachment, not text.
            return u.value == 0xFFFC
        }
    }
}
