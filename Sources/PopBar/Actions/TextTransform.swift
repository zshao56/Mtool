import Foundation

/// The local, offline text operations behind the `transform` kind of action.
///
/// Pure functions of the selected text — no clipboard, no UI, no disk — so the
/// whole set is exercised by unit tests and compiles straight into the test
/// bundle. Each operation either returns the new text or a reason it could not
/// (malformed JSON, nothing to decode), which the caller shows instead.
enum TextTransform: String, CaseIterable, Codable {

    case uppercase, lowercase, titleCase, sentenceCase
    case camelCase, snakeCase, kebabCase
    case sortLines, uniqueLines, reverseLines
    /// Merge hard line breaks inside a paragraph — what copying out of a PDF
    /// leaves behind. A blank line still separates paragraphs.
    case joinLines
    case trim
    case toSimplified, toTraditional, pinyin
    /// Put a space between CJK and Latin letters or digits ("用iPhone拍照" →
    /// "用 iPhone 拍照").
    case spaceCJK
    case jsonPretty, jsonMinify
    case urlEncode, urlDecode
    /// Strip tracking parameters (utm_*, fbclid, …) from every link in the text.
    case cleanURL
    /// Characters, words and lines, as a small report. The one operation whose
    /// result is meant to be read, not put back in place of the selection.
    case count

    enum Failure: Error, Equatable {
        case invalidJSON
        case notDecodable
    }

    /// Whether the result stands in for the selection (and so is worth replacing
    /// it with) or is a report about it. Decides the default output.
    var producesReplacement: Bool { self != .count }

    func apply(_ text: String) -> Result<String, Failure> {
        switch self {
        case .uppercase:     return .success(text.uppercased())
        case .lowercase:     return .success(text.lowercased())
        case .titleCase:     return .success(text.localizedCapitalized)
        case .sentenceCase:  return .success(Self.sentenceCase(text))
        case .camelCase:     return .success(Self.lines(text) { Self.camel(Self.words($0)) })
        case .snakeCase:     return .success(Self.lines(text) { Self.words($0).map { $0.lowercased() }.joined(separator: "_") })
        case .kebabCase:     return .success(Self.lines(text) { Self.words($0).map { $0.lowercased() }.joined(separator: "-") })
        case .sortLines:
            return .success(Self.splitLines(text)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: "\n"))
        case .uniqueLines:
            var seen = Set<String>()
            return .success(Self.splitLines(text).filter { seen.insert($0).inserted }.joined(separator: "\n"))
        case .reverseLines:  return .success(Self.splitLines(text).reversed().joined(separator: "\n"))
        case .joinLines:     return .success(Self.joinLines(text))
        case .trim:
            return .success(Self.splitLines(text)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        case .toSimplified:
            return .success(text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text)
        case .toTraditional:
            return .success(text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? text)
        case .pinyin:
            return .success(text.applyingTransform(.mandarinToLatin, reverse: false) ?? text)
        case .spaceCJK:      return .success(Self.spaceCJK(text))
        case .jsonPretty:    return Self.reformatJSON(text, pretty: true)
        case .jsonMinify:    return Self.reformatJSON(text, pretty: false)
        case .urlEncode:
            return .success(text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? text)
        case .urlDecode:
            guard let decoded = text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                return .failure(.notDecodable)
            }
            return .success(decoded)
        case .cleanURL:      return .success(Self.cleanURLs(in: text))
        case .count:         return .success(Self.countReport(text))
        }
    }

    // MARK: - Lines

    /// Lines without their terminators. `\r\n` counts as one break.
    static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private static func lines(_ text: String, _ each: (String) -> String) -> String {
        splitLines(text).map(each).joined(separator: "\n")
    }

    // MARK: - Case

    private static func sentenceCase(_ text: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in text.lowercased() {
            if capitalizeNext, ch.isLetter {
                out += String(ch).uppercased()
                capitalizeNext = false
            } else {
                out.append(ch)
            }
            if ".!?".contains(ch) || ch == "\n" { capitalizeNext = true }
        }
        return out
    }

    /// Words of an identifier or phrase: split on anything that is not a letter
    /// or digit, and on lower→upper boundaries ("fooBar" → foo, Bar) and on the
    /// end of an acronym ("HTTPServer" → HTTP, Server).
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if let last = current.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let lowerToUpper = last.isLowercase && ch.isUppercase
                let acronymEnd = last.isUppercase && ch.isUppercase && (next?.isLowercase ?? false)
                let letterDigit = last.isNumber != ch.isNumber
                if lowerToUpper || acronymEnd || letterDigit {
                    words.append(current); current = ""
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func camel(_ words: [String]) -> String {
        words.enumerated().map { i, w in
            i == 0 ? w.lowercased() : w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }.joined()
    }

    // MARK: - Join lines

    private static func joinLines(_ text: String) -> String {
        // Paragraphs are separated by one or more blank lines; keep those.
        let paragraphs = splitLines(text).split(omittingEmptySubsequences: false) {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return paragraphs
            .map { lines -> String in
                var out = ""
                for raw in lines {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard let first = line.first else { continue }
                    guard let last = out.last else { out = line; continue }
                    if last == "-", first.isLowercase, out.dropLast().last?.isLetter == true {
                        // A word hyphenated across the break: "infor-" + "mation".
                        out.removeLast()
                    } else if !(isCJK(last) || isCJK(first)) {
                        out += " "
                    }
                    out += line
                }
                return out
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - CJK spacing

    static func isCJK(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { s in
            switch s.value {
            case 0x3040...0x30FF,   // Hiragana, Katakana
                 0x3400...0x4DBF,   // CJK Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xF900...0xFAFF,   // CJK Compatibility Ideographs
                 0xAC00...0xD7AF,   // Hangul syllables
                 0x20000...0x2FA1F: // CJK Extensions B–F and supplement
                return true
            default:
                return false
            }
        }
    }

    private static func isLatinOrDigit(_ ch: Character) -> Bool {
        ch.isASCII && (ch.isLetter || ch.isNumber)
    }

    private static func spaceCJK(_ text: String) -> String {
        var out = ""
        var previous: Character?
        for ch in text {
            if let p = previous,
               (isCJK(p) && isLatinOrDigit(ch)) || (isLatinOrDigit(p) && isCJK(ch)) {
                out += " "
            }
            out.append(ch)
            previous = ch
        }
        return out
    }

    // MARK: - JSON

    /// Re-indents or compacts JSON WITHOUT parsing it into dictionaries — a round
    /// trip through `JSONSerialization` would reorder every object's keys, which is
    /// the last thing anyone formatting JSON wants. It is validated first, so the
    /// token walk below only ever sees well-formed input.
    private static func reformatJSON(_ text: String, pretty: Bool) -> Result<String, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])) != nil else {
            return .failure(.invalidJSON)
        }
        var out = ""
        var depth = 0
        var inString = false
        var escaped = false
        let indent = "  "
        let chars = Array(trimmed)
        func newline() { out += "\n" + String(repeating: indent, count: depth) }

        for (i, ch) in chars.enumerated() {
            if inString {
                out.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"":
                inString = true
                out.append(ch)
            case " ", "\t", "\n", "\r":
                continue
            case "{", "[":
                out.append(ch)
                depth += 1
                // An empty object or array stays on one line: {} and [].
                let next = chars[(i + 1)...].first { !" \t\n\r".contains($0) }
                if pretty, next != "}", next != "]" { newline() }
            case "}", "]":
                depth -= 1
                if pretty, let prev = out.last, prev != "{", prev != "[" { newline() }
                out.append(ch)
            case ",":
                out.append(ch)
                if pretty { newline() }
            case ":":
                out += pretty ? ": " : ":"
            default:
                out.append(ch)
            }
        }
        return .success(out)
    }

    // MARK: - Links

    /// Query parameters that exist only to track the click.
    private static let trackingParams: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid",
        "igshid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "spm", "si", "ref_src",
    ]

    private static func isTracking(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("utm_") || trackingParams.contains(n)
    }

    static func cleanURL(_ url: String) -> String {
        guard var comps = URLComponents(string: url), let items = comps.queryItems else { return url }
        let kept = items.filter { !isTracking($0.name) }
        guard kept.count != items.count else { return url }
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.string ?? url
    }

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"'）)\]]+"#)

    private static func cleanURLs(in text: String) -> String {
        let ns = text as NSString
        var out = text
        // Back to front, so earlier ranges stay valid as later ones change length.
        for match in urlPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            // A link at the end of a sentence swallows the full stop; it belongs
            // to the sentence, so it is left out of what gets rewritten.
            var matched = ns.substring(with: match.range)
            while let last = matched.last, ".,;:!?。，；：！？".contains(last) { matched.removeLast() }
            let urlRange = NSRange(location: match.range.location, length: (matched as NSString).length)
            let cleaned = cleanURL(matched)
            guard cleaned != matched, let range = Range(urlRange, in: out) else { continue }
            out.replaceSubrange(range, with: cleaned)
        }
        return out
    }

    // MARK: - Count

    struct Counts: Equatable {
        var characters: Int
        var charactersNoSpaces: Int
        /// Latin words plus one per CJK character — how word counts are usually
        /// reckoned for mixed Chinese/Japanese and English text.
        var words: Int
        var lines: Int
    }

    static func counts(_ text: String) -> Counts {
        var words = 0
        var inWord = false
        for ch in text {
            if isCJK(ch) {
                words += 1
                inWord = false
            } else if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
                if !inWord { words += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return Counts(
            characters: text.count,
            charactersNoSpaces: text.filter { !$0.isWhitespace }.count,
            words: words,
            lines: text.isEmpty ? 0 : splitLines(text).count)
    }

    /// The count as a small Markdown table. Labels are passed in so this file
    /// stays free of the app's localization (it also compiles into the tests).
    static func countReport(_ text: String,
                            labels: (characters: String, noSpaces: String, words: String, lines: String)
                                = ("Characters", "Characters (no spaces)", "Words", "Lines")) -> String {
        let c = counts(text)
        return """
        | | |
        |---|---:|
        | \(labels.characters) | \(c.characters) |
        | \(labels.noSpaces) | \(c.charactersNoSpaces) |
        | \(labels.words) | \(c.words) |
        | \(labels.lines) | \(c.lines) |
        """
    }
}

private extension CharacterSet {
    /// Characters that may stand unescaped inside ONE query value: `&`, `=`, `+`
    /// and `#` would change the query's meaning, so they are encoded too.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?/")
        return set
    }()
}
