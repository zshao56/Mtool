import Foundation
import NaturalLanguage

/// Splits text into sentences whose concatenation is exactly the original text
/// (the whitespace between sentences stays attached to the one before), so
/// offsets into the pieces add up to offsets into the whole.
enum TextChunker {
    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var cuts: [String.Index] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if range.lowerBound > text.startIndex { cuts.append(range.lowerBound) }
            return true
        }
        var pieces: [String] = []
        var start = text.startIndex
        for cut in cuts where cut > start {
            pieces.append(String(text[start..<cut]))
            start = cut
        }
        if start < text.endIndex { pieces.append(String(text[start...])) }
        return pieces.isEmpty ? [text] : pieces
    }

    /// The sentences, with the first one cut at its first comma-like break so
    /// the provider finishes — and reports word timings for — a short opening
    /// piece quickly. Timings arrive per piece, after the piece is synthesized,
    /// so a long first sentence means its first words play before their timings exist.
    static func quickStartPieces(_ text: String) -> [String] {
        var pieces = sentences(text)
        guard let first = pieces.first else { return pieces }
        let breaks: Set<Character> = ["，", ",", "；", ";", "：", ":", "、"]
        var count = 0
        for i in first.indices {
            count += 1
            if breaks.contains(first[i]), count >= 6 {
                let cut = first.index(after: i)
                guard cut < first.endIndex else { break }
                pieces.replaceSubrange(0...0, with: [String(first[..<cut]), String(first[cut...])])
                break
            }
        }
        return pieces
    }
}
