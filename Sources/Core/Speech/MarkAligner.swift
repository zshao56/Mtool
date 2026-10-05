import Foundation

/// Finds where each word a provider says it spoke sits in the original text.
///
/// Providers report timings against their own view of the text: their own word
/// split, sometimes numbers spelled out ("2024" → 二零二四), punctuation dropped,
/// whitespace collapsed. Offsets they send cannot be trusted to line up with
/// ours, so the words are searched for, in order, from a moving cursor: a word
/// is looked for a short way ahead of the previous match, compared with case and
/// width folded and punctuation ignored. A word that cannot be found yields a
/// mark with no location (the highlight falls back to the sentence) instead of
/// a wrong one — and the cursor does not move, so one miss cannot derail the rest.
struct MarkAligner {
    private let text: NSString
    private var cursor = 0
    /// How far ahead of the cursor a word may be found. Bounded so a common
    /// word ("the", 的) cannot latch onto an occurrence a paragraph later.
    private let window = 80
    /// The digits in the text that spoken number words are currently being
    /// matched to: providers say "二零二四" or "twenty twenty-four" for "2024",
    /// word by word, and all of those words belong to the one run of digits.
    private var numberRun: NSRange?

    init(text: String) { self.text = text as NSString }

    /// `mark` grown to the whole Latin word around it: ASCII letters and digits,
    /// with apostrophes between them ("We're"). For providers that time pieces
    /// of a word ("cus", "to", "mer" — MiniMax does), so the highlight covers
    /// the word, not half of it. Marks on anything else (Chinese, punctuation,
    /// unplaced) come back unchanged.
    func widenedToWord(_ mark: TextMark) -> TextMark {
        guard let location = mark.location, mark.length > 0 else { return mark }
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let scalar = Unicode.Scalar(text.character(at: i)) else { return false }
            return scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
        }
        func isApostrophe(_ i: Int) -> Bool {
            guard i >= 0, i < text.length else { return false }
            let c = text.character(at: i)
            return c == 0x27 || c == 0x2019
        }
        guard (location..<location + mark.length).contains(where: isWord) else { return mark }
        var start = location, end = location + mark.length
        while isWord(start - 1) || (isApostrophe(start - 1) && isWord(start - 2)) { start -= 1 }
        while isWord(end) || (isApostrophe(end) && isWord(end + 1)) { end += 1 }
        return TextMark(location: start, length: end - start, spoken: mark.spoken,
                        startFrame: mark.startFrame, endFrame: mark.endFrame)
    }

    mutating func place(_ spoken: String, startFrame: Int, endFrame: Int) -> TextMark {
        let needle = Self.fold(spoken)
        guard !needle.isEmpty else {
            return TextMark(location: nil, length: 0, spoken: spoken, startFrame: startFrame, endFrame: endFrame)
        }
        if Self.isNumberWord(needle) {
            if numberRun == nil { numberRun = digitRun(at: cursor) }
            if let run = numberRun {
                return TextMark(location: run.location, length: run.length, spoken: spoken,
                                startFrame: startFrame, endFrame: endFrame)
            }
        }
        if let run = numberRun {           // the number is over; resume after it
            cursor = max(cursor, run.location + run.length)
            numberRun = nil
        }
        let limit = min(text.length, cursor + window + needle.count * 2)
        var start = cursor
        while start < limit {
            if let length = matchLength(needle, at: start) {
                cursor = start + length
                return TextMark(location: start, length: length, spoken: spoken,
                                startFrame: startFrame, endFrame: endFrame)
            }
            start += text.rangeOfComposedCharacterSequence(at: start).length
        }
        return TextMark(location: nil, length: 0, spoken: spoken, startFrame: startFrame, endFrame: endFrame)
    }

    /// The run of digits (with `.`/`,` between them) at `start`, skipping
    /// spaces and punctuation before it; nil if the next thing is not a digit.
    private func digitRun(at start: Int) -> NSRange? {
        var i = start
        while i < text.length, Self.fold(text.substring(with: NSRange(location: i, length: 1))).isEmpty { i += 1 }
        func isDigit(_ j: Int) -> Bool { j < text.length && (48...57).contains(text.character(at: j)) }
        guard isDigit(i) else { return nil }
        var end = i
        while isDigit(end) || (end < text.length && [46, 44].contains(text.character(at: end)) && isDigit(end + 1)) {
            end += 1
        }
        return NSRange(location: i, length: end - i)
    }

    private static let chineseNumerals = Set("零〇一二两三四五六七八九十百千万亿点")
    private static let englishNumbers: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "point", "and",
    ]

    /// A word a provider may have said for digits in the text.
    static func isNumberWord(_ folded: [Character]) -> Bool {
        if folded.allSatisfy({ chineseNumerals.contains($0) }) { return true }
        // "twenty-four" folds to "twentyfour": split it back on known words.
        var rest = Substring(String(folded))
        while !rest.isEmpty {
            guard let word = englishNumbers.sorted(by: { $0.count > $1.count }).first(where: { rest.hasPrefix($0) }) else {
                return false
            }
            rest = rest.dropFirst(word.count)
        }
        return true
    }

    /// If the text at `start` spells `needle` (skipping punctuation and spaces
    /// in the text), how many UTF-16 units it spans.
    private func matchLength(_ needle: [Character], at start: Int) -> Int? {
        guard start < text.length else { return nil }
        // The match must begin on a character the needle starts with, not on
        // skipped punctuation, or the highlight would include it.
        var i = start
        var n = 0
        while n < needle.count {
            guard i < text.length else { return nil }
            let range = text.rangeOfComposedCharacterSequence(at: i)
            let ch = Self.fold(text.substring(with: range))
            if ch.isEmpty {
                if n == 0 { return nil }
                i += range.length
                continue
            }
            for c in ch {
                guard n < needle.count, needle[n] == c else { return nil }
                n += 1
            }
            i += range.length
        }
        return i - start
    }

    /// Lower-cased, width-folded characters with punctuation and whitespace removed.
    static func fold(_ s: String) -> [Character] {
        let folded = s.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        return folded.filter { ch in
            !ch.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.symbols.contains($0) }
        }.map { $0 }
    }
}

/// Groups per-character timings into words: letters/digits run together until a
/// space or punctuation; each CJK character is a word of its own.
struct CharacterGrouper {
    private var aligner: MarkAligner
    private let format: TTSAudioFormat
    private var word = ""
    private var wordStart = 0.0
    private var wordEnd = 0.0

    init(text: String, format: TTSAudioFormat) {
        aligner = MarkAligner(text: text)
        self.format = format
    }

    mutating func push(chars: [String], starts: [Double], ends: [Double]) -> [TextMark] {
        var out: [TextMark] = []
        for i in chars.indices {
            let c = chars[i]
            let folded = MarkAligner.fold(c)
            if folded.isEmpty {                       // space or punctuation ends a word
                if let m = flushWord() { out.append(m) }
                continue
            }
            let isCJK = c.unicodeScalars.contains { $0.value >= 0x2E80 }
            if isCJK, let m = flushWord() { out.append(m) }
            if word.isEmpty { wordStart = starts[i] }
            word += c
            wordEnd = ends[i]
            if isCJK, let m = flushWord() { out.append(m) }
        }
        return out
    }

    mutating func flush() -> [TextMark] { flushWord().map { [$0] } ?? [] }

    private mutating func flushWord() -> TextMark? {
        guard !word.isEmpty else { return nil }
        defer { word = "" }
        return aligner.place(word, startFrame: format.frames(seconds: wordStart), endFrame: format.frames(seconds: wordEnd))
    }
}
