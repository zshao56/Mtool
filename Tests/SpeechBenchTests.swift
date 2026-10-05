import XCTest

final class MarkAlignerTests: XCTestCase {

    private func located(_ text: String, _ words: [String]) -> [String?] {
        var aligner = MarkAligner(text: text)
        let ns = text as NSString
        return words.map { word in
            let m = aligner.place(word, startFrame: 0, endFrame: 0)
            return m.location.map { ns.substring(with: NSRange(location: $0, length: m.length)) }
        }
    }

    func testChineseCharactersWithAttachedPunctuation() {
        // Volcengine 2.0 sends words in the original text with punctuation glued on.
        XCTAssertEqual(located("今天天气不错，我们去散步。", ["今", "天", "天", "气", "不", "错，", "我们", "去", "散步。"]),
                       ["今", "天", "天", "气", "不", "错", "我们", "去", "散步"])
    }

    func testMixedScriptCaseAndWidthFolding() {
        XCTAssertEqual(located("用 Swift 写 macOS App", ["用", "swift", "写", "MACOS", "Ａpp"]),
                       ["用", "Swift", "写", "macOS", "App"])
    }

    func testUnmatchedWordDoesNotDerailTheRest() {
        // A word that is nowhere in the text is left unplaced; the rest still match.
        XCTAssertEqual(located("今年到了", ["今", "明", "年", "到", "了"]), ["今", nil, "年", "到", "了"])
    }

    func testRepeatedWordsMatchInOrder() {
        let text = "the cat and the dog"
        var aligner = MarkAligner(text: text)
        let locs = ["the", "cat", "and", "the", "dog"].map { aligner.place($0, startFrame: 0, endFrame: 0).location }
        XCTAssertEqual(locs, [0, 4, 8, 12, 16])
    }

    func testCharacterGrouperBuildsWordsAndSingleHanzi() {
        let format = TTSAudioFormat(sampleRate: 1000, channels: 1)
        var g = CharacterGrouper(text: "Hi 你好 there", format: format)
        let chars = ["H", "i", " ", "你", "好", " ", "t", "h", "e", "r", "e"]
        let times = chars.indices.map { Double($0) / 10 }
        var marks = g.push(chars: chars, starts: times, ends: times.map { $0 + 0.1 })
        marks += g.flush()
        XCTAssertEqual(marks.map(\.spoken), ["Hi", "你", "好", "there"])
        XCTAssertEqual(marks.map(\.location), [0, 3, 4, 6])
        XCTAssertEqual(marks.first?.startFrame, 0)
        XCTAssertEqual(marks.first?.endFrame, 200)   // "i" ends at 0.2 s
    }
}

final class TTSRunMetricsTests: XCTestCase {
    private let format = TTSAudioFormat(sampleRate: 1000, channels: 1)  // 1 frame = 1 ms

    func testKeepsUpWhenChunksArriveAheadOfPlayback() {
        // 3 × 500 ms of audio arriving at 400, 600, 800 ms.
        let r = TTSRunRecorder(format: format, chunks: [(400, 500), (600, 500), (800, 500)], marks: [], endMs: 850)
        let m = r.metrics(provider: "p", textId: "t", text: "x", attempt: 1, bufferBudgetMs: 0)
        XCTAssertEqual(m.firstAudioMs, 400)
        XCTAssertEqual(m.noStallStartMs, 400)
        XCTAssertEqual(m.bufferNeededMs, 0)
        XCTAssertEqual(m.keepsUpWithRealTime, true)
        XCTAssertEqual(m.audioSec, 1.5, accuracy: 1e-9)
        XCTAssertEqual(m.rtf!, 0.85 / 1.5, accuracy: 1e-9)
    }

    func testStallDetectedAndBufferNeededComputed() {
        // Second chunk arrives at 1200 ms but is due at 400 + 500 = 900 ms: 300 ms short.
        let r = TTSRunRecorder(format: format, chunks: [(400, 500), (1200, 500)], marks: [], endMs: 1200)
        let tight = r.metrics(provider: "p", textId: "t", text: "x", attempt: 1, bufferBudgetMs: 200)
        XCTAssertEqual(tight.bufferNeededMs, 300)
        XCTAssertEqual(tight.noStallStartMs, 700)
        XCTAssertEqual(tight.stallsAtBudget, 1)
        XCTAssertEqual(tight.stallMsAtBudget, 100, accuracy: 1e-9)
        XCTAssertEqual(tight.keepsUpWithRealTime, false)
        let loose = r.metrics(provider: "p", textId: "t", text: "x", attempt: 1, bufferBudgetMs: 300)
        XCTAssertEqual(loose.keepsUpWithRealTime, true)
    }

    func testMarksArrivingAfterTheirWordIsAudibleCountAsLate() {
        let early = TTSRunRecorder.MarkArrival(arrivalMs: 400,
            mark: TextMark(location: 0, length: 2, spoken: "ab", startFrame: 0, endFrame: 100))
        // Word at 300 ms into the audio plays at 400 + 300 = 700 ms; the mark came at 1000.
        let late = TTSRunRecorder.MarkArrival(arrivalMs: 1000,
            mark: TextMark(location: 3, length: 2, spoken: "cd", startFrame: 300, endFrame: 400))
        let r = TTSRunRecorder(format: format, chunks: [(400, 1000)], marks: [early, late], endMs: 1000)
        let m = r.metrics(provider: "p", textId: "t", text: "ab cd", attempt: 1, bufferBudgetMs: 0)
        XCTAssertEqual(m.marksLate, 1)
        XCTAssertEqual(m.worstMarkLateMs!, 300, accuracy: 1e-9)
        XCTAssertEqual(m.markCoverage, 1)
    }

    func testCoverageIgnoresPunctuationAndSpaces() {
        let marks = [TextMark(location: 0, length: 1, spoken: "你", startFrame: 0, endFrame: 0)]
        XCTAssertEqual(TTSRunRecorder.coverage(text: "你好。", marks: marks), 0.5)
    }
}

final class PCMPlumbingTests: XCTestCase {
    func testAssemblerCarriesHalfSamples() {
        var a = PCMAssembler(format: TTSAudioFormat(sampleRate: 24000, channels: 1))
        XCTAssertEqual(a.push(Data([1, 2, 3])), Data([1, 2]))
        XCTAssertNil(a.push(Data()))
        XCTAssertEqual(a.push(Data([4])), Data([3, 4]))
        XCTAssertEqual(a.framesEmitted, 2)
    }

    func testHexDecoding() {
        XCTAssertEqual(Data(hex: "00ff10Ab"), Data([0x00, 0xFF, 0x10, 0xAB]))
        XCTAssertNil(Data(hex: "zz"))
    }

    func testPreviewHidesAudioPayloads() {
        let line = #"{"data":"\#(String(repeating: "A", count: 500))","code":0}"#
        XCTAssertEqual(previewOfMessage(line), #"{"data":"<long string>","code":0}"#)
    }
}

final class NumberAlignmentTests: XCTestCase {
    private func located(_ text: String, _ words: [String]) -> [String?] {
        var aligner = MarkAligner(text: text)
        let ns = text as NSString
        return words.map { word in
            let m = aligner.place(word, startFrame: 0, endFrame: 0)
            return m.location.map { ns.substring(with: NSRange(location: $0, length: m.length)) }
        }
    }

    func testSpokenChineseDigitsHighlightTheDigitRun() {
        // The aligner must not jump to the 零 of 零下 further on.
        XCTAssertEqual(located("2024年，零下5度", ["二", "零", "二", "四", "年", "零", "下", "五", "度"]),
                       ["2024", "2024", "2024", "2024", "年", "零", "下", "5", "度"])
    }

    func testDecimalAndEnglishNumberWords() {
        XCTAssertEqual(located("costs 3.5 dollars in 2024", ["costs", "three", "point", "five", "dollars", "in", "twenty", "twenty-four"]),
                       ["costs", "3.5", "3.5", "3.5", "dollars", "in", "2024", "2024"])
    }

    func testDigitsTheProviderKeptAreMatchedDirectly() {
        XCTAssertEqual(located("版本 v2.8.1 发布", ["版本", "v2.8.1", "发布"]), ["版本", "v2.8.1", "发布"])
    }

    /// MiniMax times pieces of English words; each piece is widened to its word.
    func testWordPiecesWidenToTheWholeWord() {
        func widened(_ text: String, _ pieces: [String]) -> [String] {
            var aligner = MarkAligner(text: text)
            return pieces.map { piece in
                let mark = aligner.widenedToWord(aligner.place(piece, startFrame: 0, endFrame: 0))
                return mark.location.map { (text as NSString).substring(with: NSRange(location: $0, length: mark.length)) } ?? "✗"
            }
        }
        XCTAssertEqual(widened("to your customer portal.", ["to", "your", "cus", "to", "mer", "portal"]),
                       ["to", "your", "customer", "customer", "customer", "portal"])
        XCTAssertEqual(widened("\"We're on 7 of 10 benchmarks,", ["We", "re", "7", "10", "ben", "ch", "mar", "ks"]),
                       ["We're", "We're", "7", "10", "benchmarks", "benchmarks", "benchmarks", "benchmarks"])
        XCTAssertEqual(widened("打开 Build Settings，然后", ["打", "开", "Sett", "ings", "然"]),
                       ["打", "开", "Settings", "Settings", "然"])
    }
}
