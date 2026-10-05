import XCTest

/// A double-click on empty page space in Chrome copies a lone line break. Text
/// like that must count as "nothing selected", or the popup opens over nothing.
final class BlankSelectionTests: XCTestCase {

    func testNothingAPersonCouldActOnIsBlank() {
        for s in ["", "\n", "\r\n", " ", "\t", "\n\n  \n", "\u{00A0}", "\u{3000}",
                  "\u{200B}", "\u{FEFF}", "\u{200D}", "\u{FFFC}", " \u{200B}\n"] {
            XCTAssertTrue(s.isBlankSelection, "should be blank: \(s.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    func testAnyVisibleCharacterIsASelection() {
        for s in ["a", "字", "1", ".", "—", "😀", "❤️", "👨‍👩‍👧‍👦", "🇺🇸", "1️⃣", " a ", "\nx\n", "・", "\u{200B}b"] {
            XCTAssertFalse(s.isBlankSelection, "should not be blank: \(s)")
        }
    }
}
