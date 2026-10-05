import XCTest

/// The `compare` output (issue #12) marks what a rewrite removed and added. These
/// pin down the units it compares by — whole words for English, single
/// characters for Chinese — since that decides what the user sees marked.
final class TextDiffTests: XCTestCase {

    /// Each side rendered with its changed runs in brackets.
    private func marked(_ segments: [TextDiff.Segment]) -> String {
        segments.map { $0.changed ? "[\($0.text)]" : $0.text }.joined()
    }

    func testEnglishIsComparedByWord() {
        let c = TextDiff.compare("Their are several reason why the build fail.",
                                 "There are several reasons why the build fails.")
        XCTAssertEqual(marked(c.original), "[Their] are several [reason] why the build [fail].")
        XCTAssertEqual(marked(c.revised), "[There] are several [reasons] why the build [fails].")
        XCTAssertFalse(c.isUnchanged)
    }

    func testChineseIsComparedByCharacter() {
        let c = TextDiff.compare("我们的主要的目的是为了帮助用户。", "主要目的是帮助用户。")
        XCTAssertEqual(marked(c.original), "[我们的]主要[的]目的是[为了]帮助用户。")
        XCTAssertEqual(marked(c.revised), "主要目的是帮助用户。")
    }

    func testMixedTextKeepsEnglishWordsWhole() {
        let c = TextDiff.compare("打开 build settings，改为 Swift 6", "打开 Build Settings，改成 Swift 6")
        XCTAssertEqual(marked(c.original), "打开 [build settings]，改[为] Swift 6")
        XCTAssertEqual(marked(c.revised), "打开 [Build Settings]，改[成] Swift 6")
    }

    func testKoreanJamoIsComparedByWord() {
        XCTAssertEqual(TextDiff.tokens("정말 ㅋㅋㅋ 웃겨"), ["정말", " ", "ㅋㅋㅋ", " ", "웃겨"])
    }

    func testApostropheStaysInsideAWord() {
        XCTAssertEqual(TextDiff.tokens("don't 'x'"), ["don't", " ", "'", "x", "'"])
    }

    func testWhitespaceAtTheEndsIsNotAChange() {
        XCTAssertTrue(TextDiff.compare("same text\n", "same text").isUnchanged)
        XCTAssertFalse(TextDiff.compare("same text", "same text!").isUnchanged)
    }

    func testEachSideJoinsBackToItsText() {
        let a = "Their are several reason 为了 帮助\n用户", b = "There are reasons 帮助用户。"
        let c = TextDiff.compare(a, b)
        XCTAssertEqual(c.original.map(\.text).joined(), a)
        XCTAssertEqual(c.revised.map(\.text).joined(), b)
    }

    func testVeryLongTextIsShownWholeWithoutComparing() {
        let a = String(repeating: "字", count: TextDiff.maxTokens), b = a + "。"
        let c = TextDiff.compare(a, b)
        XCTAssertEqual(c.original, [TextDiff.Segment(text: a, changed: true)])
        XCTAssertEqual(c.revised, [TextDiff.Segment(text: b, changed: true)])
    }
}
