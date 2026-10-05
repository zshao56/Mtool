import Foundation

/// What changed between a selection and the text an action produced, for the
/// `compare` output (issue #12): the popup shows the original with what was
/// removed marked, above the result with what was added marked.
///
/// The two texts are compared token by token, not character by character, so an
/// English correction reads as whole words swapped ("fail" → "fails") rather than
/// a scatter of single letters. Chinese and Japanese have no spaces to find words
/// by, so each of their characters is a token of its own.
enum TextDiff {

    /// A run of text that is either shared by both sides or only on this side.
    struct Segment: Equatable, Sendable {
        var text: String
        var changed: Bool
    }

    struct Comparison: Equatable, Sendable {
        /// The selection, with what the result no longer has marked `changed`.
        var original: [Segment]
        /// The result, with what it added marked `changed`.
        var revised: [Segment]
        /// The result says the same as the selection, give or take whitespace at
        /// either end — so replacing would change nothing the user can see.
        var isUnchanged: Bool
    }

    /// Past this many tokens on both sides together, the texts are not compared:
    /// the work grows with length times the number of differences, and two
    /// unrelated 6,000-character texts already take over a second. Both sides are
    /// then shown whole, marked as changed.
    static let maxTokens = 20_000

    static func compare(_ original: String, _ revised: String) -> Comparison {
        let old = tokens(original), new = tokens(revised)
        var removed = Set<Int>(), inserted = Set<Int>()
        if old.count + new.count > maxTokens {
            removed = Set(old.indices); inserted = Set(new.indices)
        } else {
            for change in new.difference(from: old) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
        }
        let unchanged = original.trimmingCharacters(in: .whitespacesAndNewlines)
            == revised.trimmingCharacters(in: .whitespacesAndNewlines)
        return Comparison(original: segments(old, changed: removed),
                          revised: segments(new, changed: inserted),
                          isUnchanged: unchanged)
    }

    /// Split into the units the comparison works on: a word of Latin letters or
    /// digits (an apostrophe inside it, as in "don't", is part of it), a run of
    /// whitespace, a single CJK character, or any other single character.
    static func tokens(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                out.append(String(chars[i..<j])); i = j
            } else if isWordCharacter(c) {
                var j = i + 1
                while j < chars.count {
                    if isWordCharacter(chars[j]) { j += 1; continue }
                    // An apostrophe joins the word only when a letter follows it.
                    if chars[j] == "'" || chars[j] == "’", j + 1 < chars.count, isWordCharacter(chars[j + 1]) {
                        j += 2; continue
                    }
                    break
                }
                out.append(String(chars[i..<j])); i = j
            } else {
                out.append(String(c)); i += 1
            }
        }
        return out
    }

    /// A letter, digit or underscore outside the scripts written without spaces.
    private static func isWordCharacter(_ c: Character) -> Bool {
        guard c.isLetter || c.isNumber || c == "_" else { return false }
        return !isUnspacedScript(c)
    }

    /// Chinese, Japanese kana and the full-width forms used with them. Korean is
    /// written with spaces, so it is compared by word like English.
    private static func isUnspacedScript(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x2E80...0x2FFF,    // CJK radicals, Kangxi radicals
             0x3000...0x30FF,    // CJK punctuation, hiragana, katakana
             0x3100...0x312F,    // bopomofo (0x3130–0x318F is Korean jamo: by word)
             0x31A0...0x31BF,    // bopomofo extended
             0x31F0...0x31FF,    // katakana phonetic extensions
             0x3400...0x4DBF,    // CJK extension A
             0x4E00...0x9FFF,    // CJK unified ideographs
             0xF900...0xFAFF,    // CJK compatibility ideographs
             0xFF00...0xFFEF,    // full-width and half-width forms
             0x20000...0x3FFFF:  // CJK extensions B and later
            return true
        default:
            return false
        }
    }

    /// Join the tokens into runs. Whitespace left unchanged between two changes is
    /// counted as changed too, so "fail on" → "fails at" reads as one marked run
    /// instead of two with a gap.
    private static func segments(_ tokens: [String], changed: Set<Int>) -> [Segment] {
        var out: [Segment] = []
        for (i, token) in tokens.enumerated() {
            var isChanged = changed.contains(i)
            if !isChanged, i > 0, i + 1 < tokens.count,
               token.allSatisfy(\.isWhitespace), changed.contains(i - 1), changed.contains(i + 1) {
                isChanged = true
            }
            if let last = out.last, last.changed == isChanged {
                out[out.count - 1].text += token
            } else {
                out.append(Segment(text: token, changed: isChanged))
            }
        }
        return out
    }
}
