import XCTest

/// The UTF-16 splice used before an accessibility `AXValue` write. Getting this
/// wrong would paste at the wrong offset (or corrupt a multi-byte character), so
/// it is tested directly, including CJK and an emoji.
final class TextInsertionTests: XCTestCase {

    func testInsertAtCaretInTheMiddle() {
        XCTAssertEqual(TextInsertion.insert("X", into: "hello", atUTF16: NSRange(location: 2, length: 0)),
                       "heXllo")
    }

    func testInsertAtStartAndEnd() {
        XCTAssertEqual(TextInsertion.insert("X", into: "hello", atUTF16: NSRange(location: 0, length: 0)),
                       "Xhello")
        XCTAssertEqual(TextInsertion.insert("X", into: "hello", atUTF16: NSRange(location: 5, length: 0)),
                       "helloX")
    }

    func testReplaceASelection() {
        XCTAssertEqual(TextInsertion.insert("X", into: "hello", atUTF16: NSRange(location: 1, length: 3)),
                       "hXo")
    }

    func testInsertIntoEmptyString() {
        XCTAssertEqual(TextInsertion.insert("X", into: "", atUTF16: NSRange(location: 0, length: 0)), "X")
    }

    func testCJKObeysUTF16Offsets() {
        // "中文" is two UTF-16 units; a caret at 1 is between the two characters.
        XCTAssertEqual(TextInsertion.insert("X", into: "中文", atUTF16: NSRange(location: 1, length: 0)),
                       "中X文")
        XCTAssertEqual(TextInsertion.insert("X", into: "中文", atUTF16: NSRange(location: 2, length: 0)),
                       "中文X")
    }

    func testEmojiIsSurrogatePair() {
        // "🙂" is one Character but two UTF-16 units. Replacing the whole cluster
        // (length 2) must work, and inserting after it uses offset 2.
        XCTAssertEqual(TextInsertion.insert("X", into: "a🙂b", atUTF16: NSRange(location: 1, length: 2)),
                       "aXb")
        XCTAssertEqual(TextInsertion.insert("X", into: "a🙂b", atUTF16: NSRange(location: 3, length: 0)),
                       "a🙂Xb")
    }

    func testOutOfBoundsReturnsNil() {
        XCTAssertNil(TextInsertion.insert("X", into: "hello", atUTF16: NSRange(location: 6, length: 0)))
        XCTAssertNil(TextInsertion.insert("X", into: "hello", atUTF16: NSRange(location: 3, length: 5)))
        XCTAssertNil(TextInsertion.insert("X", into: "hello", atUTF16: NSRange(location: -1, length: 0)))
        XCTAssertNil(TextInsertion.insert("X", into: "hello", atUTF16: NSRange(location: 2, length: -1)))
    }

    /// The `end == count` boundary: the implementation slices `units[end...]`,
    /// which is the empty suffix at the end of the string. Verified safe under
    /// Swift 5.10; this test pins it so a future refactor cannot break the
    /// caret-at-end case.
    func testRangeEndingExactlyAtCountIsSafe() {
        XCTAssertEqual(TextInsertion.insert("X", into: "hello", atUTF16: NSRange(location: 5, length: 0)),
                       "helloX")
        XCTAssertEqual(TextInsertion.insert("X", into: "hello", atUTF16: NSRange(location: 3, length: 2)),
                       "helX")
        XCTAssertEqual(TextInsertion.insert("", into: "hello", atUTF16: NSRange(location: 5, length: 0)),
                       "hello")
    }
}
