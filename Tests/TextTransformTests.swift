import XCTest

/// The `transform` actions replace the user's selection with their output, so a
/// wrong result is written straight into someone's document. Each case pins the
/// behaviour that is easy to get subtly wrong.
final class TextTransformTests: XCTestCase {

    private func run(_ op: TextTransform, _ text: String) -> String? {
        try? op.apply(text).get()
    }

    func testCaseConversions() {
        XCTAssertEqual(run(.uppercase, "Hello world"), "HELLO WORLD")
        XCTAssertEqual(run(.sentenceCase, "HELLO THERE. how ARE you?"), "Hello there. How are you?")
        XCTAssertEqual(run(.camelCase, "user_account_id"), "userAccountId")
        XCTAssertEqual(run(.snakeCase, "userAccountID"), "user_account_id")
        XCTAssertEqual(run(.snakeCase, "HTTPServerError"), "http_server_error")
        XCTAssertEqual(run(.kebabCase, "Some Title Here"), "some-title-here")
        XCTAssertEqual(run(.snakeCase, "fooBar\nbazQux"), "foo_bar\nbaz_qux", "each line converted on its own")
    }

    func testLineOperations() {
        XCTAssertEqual(run(.sortLines, "file10\nfile2\nfile1"), "file1\nfile2\nfile10", "numbers sort as numbers")
        XCTAssertEqual(run(.uniqueLines, "b\na\nb\nc\na"), "b\na\nc", "first occurrence kept, order kept")
        XCTAssertEqual(run(.reverseLines, "1\n2\n3"), "3\n2\n1")
        XCTAssertEqual(run(.trim, "  a  \n\tb\n\n"), "a\nb")
    }

    func testJoinLinesHandlesEnglishChineseHyphensAndParagraphs() {
        XCTAssertEqual(run(.joinLines, "The quick brown\nfox jumps"), "The quick brown fox jumps")
        XCTAssertEqual(run(.joinLines, "这是第一行\n接着第二行"), "这是第一行接着第二行", "no space between CJK lines")
        XCTAssertEqual(run(.joinLines, "infor-\nmation"), "information", "hyphenated word rejoined")
        XCTAssertEqual(run(.joinLines, "one\ntwo\n\nthree\nfour"), "one two\n\nthree four", "paragraphs kept")
    }

    func testChineseConversions() {
        XCTAssertEqual(run(.toSimplified, "漢語 後來"), "汉语 后来")
        XCTAssertEqual(run(.toTraditional, "汉语 发展"), "漢語 發展")
        XCTAssertEqual(run(.pinyin, "拼音"), "pīn yīn")
        XCTAssertEqual(run(.spaceCJK, "用iPhone拍照，花了3分钟"), "用 iPhone 拍照，花了 3 分钟")
    }

    func testJSONKeepsKeyOrderAndRejectsGarbage() {
        XCTAssertEqual(run(.jsonMinify, "{ \"b\": 1,\n  \"a\": [1, 2] }"), "{\"b\":1,\"a\":[1,2]}")
        XCTAssertEqual(run(.jsonPretty, "{\"b\":1,\"a\":{},\"s\":\"x, {y}\"}"),
                       "{\n  \"b\": 1,\n  \"a\": {},\n  \"s\": \"x, {y}\"\n}")
        XCTAssertEqual(TextTransform.jsonPretty.apply("{not json"), .failure(.invalidJSON))
    }

    func testURLEncodingAndCleaning() {
        XCTAssertEqual(run(.urlEncode, "a b&c=d"), "a%20b%26c%3Dd")
        XCTAssertEqual(run(.urlDecode, "a%20b+c"), "a b c")
        XCTAssertEqual(run(.cleanURL, "see https://x.com/p?id=7&utm_source=tw&fbclid=abc now"),
                       "see https://x.com/p?id=7 now")
        XCTAssertEqual(run(.cleanURL, "https://x.com/p?utm_medium=a"), "https://x.com/p")
        XCTAssertEqual(run(.cleanURL, "Read https://x.com/p?utm_source=a. Then go."), "Read https://x.com/p. Then go.",
                       "the sentence's full stop stays")
        XCTAssertEqual(run(.cleanURL, "https://x.com/p?id=1"), "https://x.com/p?id=1", "clean links untouched")
    }

    func testCountsTreatEachCJKCharacterAsAWord() {
        let c = TextTransform.counts("Hello world\n你好")
        XCTAssertEqual(c.words, 4)
        XCTAssertEqual(c.lines, 2)
        XCTAssertEqual(c.characters, 14)
        XCTAssertEqual(c.charactersNoSpaces, 12)
        XCTAssertFalse(TextTransform.count.producesReplacement)
    }
}
