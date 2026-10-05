import XCTest

/// The double-tap-Command gesture: only Command down/up/down/up within the
/// threshold completes it, and anything else in between resets it.
final class ModifierDoubleTapTests: XCTestCase {

    private func detector(threshold: TimeInterval = 0.35) -> ModifierDoubleTapDetector {
        ModifierDoubleTapDetector(threshold: threshold)
    }

    func testCompletesOnTheSecondRelease() {
        var d = detector()
        XCTAssertFalse(d.handle(.commandDown, at: 0.0))
        XCTAssertFalse(d.handle(.commandUp, at: 0.10))
        XCTAssertFalse(d.handle(.commandDown, at: 0.20))
        XCTAssertTrue(d.handle(.commandUp, at: 0.30))
    }

    func testTooSlowDoesNotComplete() {
        var d = detector(threshold: 0.35)
        _ = d.handle(.commandDown, at: 0.0)
        _ = d.handle(.commandUp, at: 0.05)
        _ = d.handle(.commandDown, at: 0.45)   // beyond the threshold, restarts
        XCTAssertFalse(d.handle(.commandUp, at: 0.50))
    }

    func testAnotherKeyResets() {
        var d = detector()
        _ = d.handle(.commandDown, at: 0.0)
        _ = d.handle(.commandUp, at: 0.05)
        _ = d.handle(.otherKeyDown, at: 0.08)
        _ = d.handle(.commandDown, at: 0.10)
        XCTAssertFalse(d.handle(.commandUp, at: 0.12))
    }

    func testOtherModifierResets() {
        var d = detector()
        _ = d.handle(.commandDown, at: 0.0)
        _ = d.handle(.otherModifierChanged, at: 0.02)
        _ = d.handle(.commandUp, at: 0.05)
        _ = d.handle(.commandDown, at: 0.10)
        XCTAssertFalse(d.handle(.commandUp, at: 0.12))
    }

    func testFocusChangeResets() {
        var d = detector()
        _ = d.handle(.commandDown, at: 0.0)
        _ = d.handle(.commandUp, at: 0.05)
        _ = d.handle(.focusChanged, at: 0.06)
        _ = d.handle(.commandDown, at: 0.10)
        XCTAssertFalse(d.handle(.commandUp, at: 0.12))
    }

    func testSecureInputResets() {
        var d = detector()
        _ = d.handle(.commandDown, at: 0.0)
        _ = d.handle(.commandUp, at: 0.05)
        _ = d.handle(.secureInputActive, at: 0.06)
        _ = d.handle(.commandDown, at: 0.10)
        XCTAssertFalse(d.handle(.commandUp, at: 0.12))
    }

    func testASecondDoubleTapWorksAfterTheFirst() {
        var d = detector()
        _ = d.handle(.commandDown, at: 0.0)
        _ = d.handle(.commandUp, at: 0.05)
        _ = d.handle(.commandDown, at: 0.10)
        XCTAssertTrue(d.handle(.commandUp, at: 0.15))
        XCTAssertFalse(d.handle(.commandDown, at: 0.30))
        XCTAssertFalse(d.handle(.commandUp, at: 0.35))
        XCTAssertFalse(d.handle(.commandDown, at: 0.40))
        XCTAssertTrue(d.handle(.commandUp, at: 0.45))
    }

    func testTimeoutResets() {
        var d = detector()
        _ = d.handle(.commandDown, at: 0.0)
        _ = d.handle(.commandUp, at: 0.05)
        _ = d.handle(.timeout, at: 1.0)
        _ = d.handle(.commandDown, at: 1.1)
        XCTAssertFalse(d.handle(.commandUp, at: 1.12))
    }
}
