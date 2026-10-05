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

    // MARK: - handleFlags tests

    func testHandleFlagsCompletesDoubleTap() {
        var d = detector()
        // Tap 1: press & release Command
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.0))
        XCTAssertTrue(d.commandWasDown)
        XCTAssertFalse(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.05))
        XCTAssertFalse(d.commandWasDown)
        // Tap 2: press & release Command within threshold
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.15))
        XCTAssertTrue(d.commandWasDown)
        XCTAssertTrue(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.25))
        XCTAssertFalse(d.commandWasDown)
    }

    func testHandleFlagsOtherModifierResets() {
        var d = detector()
        // Tap 1
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.0))
        XCTAssertFalse(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.05))
        // Introduce Option modifier
        XCTAssertFalse(d.handleFlags(commandDown: false, otherModifiers: true, at: 0.10))
        // Tap 2 now fails to complete double tap because Option interrupted
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.15))
        XCTAssertFalse(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.20))
    }

    func testHandleFlagsTooSlowDoesNotComplete() {
        var d = detector(threshold: 0.35)
        // Tap 1
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.0))
        XCTAssertFalse(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.05))
        // Tap 2 starts at 0.45s (interval > 0.35s)
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.45))
        XCTAssertFalse(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.50))
    }

    func testHandleFlagsOtherKeyCancels() {
        var d = detector()
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.0))
        // User presses 'c' while Command is down (⌘C)
        d.handle(.otherKeyDown, at: 0.05)
        // Release Command
        XCTAssertFalse(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.10))
        // Second tap
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.15))
        XCTAssertFalse(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.20))
    }

    func testHandleFlagsConsecutiveDoubleTaps() {
        var d = detector()
        // First double-tap
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.0))
        XCTAssertFalse(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.05))
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.15))
        XCTAssertTrue(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.20))

        // Second double-tap
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.40))
        XCTAssertFalse(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.45))
        XCTAssertFalse(d.handleFlags(commandDown: true, otherModifiers: false, at: 0.55))
        XCTAssertTrue(d.handleFlags(commandDown: false, otherModifiers: false, at: 0.60))
    }

    // MARK: - ModifierTapKey

    func testTapKeyPhysicalCodeMapping() {
        XCTAssertNil(ModifierTapKey.anyCommand.physicalCode)
        XCTAssertEqual(ModifierTapKey.leftCommand.physicalCode, ModifierTapKey.leftCommandCode)
        XCTAssertEqual(ModifierTapKey.rightCommand.physicalCode, ModifierTapKey.rightCommandCode)
        XCTAssertEqual(ModifierTapKey.leftOption.physicalCode, ModifierTapKey.leftOptionCode)
        XCTAssertEqual(ModifierTapKey.rightOption.physicalCode, ModifierTapKey.rightOptionCode)

        XCTAssertEqual(ModifierTapKey.physical(code: ModifierTapKey.leftCommandCode), ModifierTapKey.leftCommand)
        XCTAssertEqual(ModifierTapKey.physical(code: ModifierTapKey.rightCommandCode), ModifierTapKey.rightCommand)
        XCTAssertEqual(ModifierTapKey.physical(code: ModifierTapKey.leftOptionCode), ModifierTapKey.leftOption)
        XCTAssertEqual(ModifierTapKey.physical(code: ModifierTapKey.rightOptionCode), ModifierTapKey.rightOption)
        XCTAssertNil(ModifierTapKey.physical(code: 56))   // left Shift is not a trigger
        XCTAssertNil(ModifierTapKey.physical(code: 999))
    }

    // MARK: - Physical (side-specific) detector

    private func physical(_ key: ModifierTapKey,
                          threshold: TimeInterval = 0.35) -> PhysicalModifierDoubleTapDetector {
        PhysicalModifierDoubleTapDetector(key: key, threshold: threshold)
    }

    private func feed(_ d: inout PhysicalModifierDoubleTapDetector,
                      keyCode: UInt16, command: Bool,
                      option: Bool = false, shift: Bool = false, control: Bool = false,
                      at time: TimeInterval) -> Bool {
        d.handle(keyCode: keyCode, commandDown: command, optionDown: option,
                 shiftDown: shift, controlDown: control, at: time)
    }

    func testLeftCommandCompletesOnTwoLeftTaps() {
        var d = physical(.leftCommand)
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: true, at: 0.00))
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: false, at: 0.10))
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: true, at: 0.20))
        XCTAssertTrue(feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: false, at: 0.30))
    }

    func testRightCommandCompletesOnTwoRightTaps() {
        var d = physical(.rightCommand)
        _ = feed(&d, keyCode: ModifierTapKey.rightCommandCode, command: true, at: 0.00)
        _ = feed(&d, keyCode: ModifierTapKey.rightCommandCode, command: false, at: 0.10)
        _ = feed(&d, keyCode: ModifierTapKey.rightCommandCode, command: true, at: 0.20)
        XCTAssertTrue(feed(&d, keyCode: ModifierTapKey.rightCommandCode, command: false, at: 0.30))
    }

    func testLeftAndRightCommandAreNotInterchangeable() {
        var d = physical(.leftCommand)
        _ = feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: true, at: 0.00)
        _ = feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: false, at: 0.10)
        // The right key resets the left detector...
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.rightCommandCode, command: true, at: 0.20))
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.rightCommandCode, command: false, at: 0.30))
        // ...so a following single left tap is only a fresh first tap.
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: true, at: 0.40))
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: false, at: 0.50))
    }

    func testLeftOptionTreatsOptionAsTheGestureNotAnInterruption() {
        var d = physical(.leftOption)
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftOptionCode, command: false, option: true, at: 0.00))
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftOptionCode, command: false, option: false, at: 0.10))
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftOptionCode, command: false, option: true, at: 0.20))
        XCTAssertTrue(feed(&d, keyCode: ModifierTapKey.leftOptionCode, command: false, option: false, at: 0.30))
    }

    func testRightOptionDoesNotCompleteTheLeftOptionDetector() {
        var d = physical(.leftOption)
        _ = feed(&d, keyCode: ModifierTapKey.leftOptionCode, command: false, option: true, at: 0.00)
        _ = feed(&d, keyCode: ModifierTapKey.leftOptionCode, command: false, option: false, at: 0.10)
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.rightOptionCode, command: false, option: true, at: 0.20))
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.rightOptionCode, command: false, option: false, at: 0.30))
    }

    func testOptionDoubleTapIsCancelledByACommandInterruption() {
        var d = physical(.leftOption)
        _ = feed(&d, keyCode: ModifierTapKey.leftOptionCode, command: false, option: true, at: 0.00)
        _ = feed(&d, keyCode: ModifierTapKey.leftOptionCode, command: false, option: false, at: 0.05)
        // Command in between resets the candidate.
        _ = feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: true, at: 0.10)
        _ = feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: false, at: 0.15)
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftOptionCode, command: false, option: true, at: 0.20))
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftOptionCode, command: false, option: false, at: 0.25))
    }

    func testAnyCommandCompletesOnEitherCommandKey() {
        var d = physical(.anyCommand)
        _ = feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: true, at: 0.00)
        _ = feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: false, at: 0.05)
        _ = feed(&d, keyCode: ModifierTapKey.rightCommandCode, command: true, at: 0.15)
        XCTAssertTrue(feed(&d, keyCode: ModifierTapKey.rightCommandCode, command: false, at: 0.20))
    }

    func testAnyCommandIsCancelledByAnotherModifier() {
        var d = physical(.anyCommand)
        _ = feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: true, at: 0.00)
        _ = feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: false, at: 0.05)
        // Option joins the second tap: not a clean Command double-tap.
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: true, option: true, at: 0.15))
        XCTAssertFalse(feed(&d, keyCode: ModifierTapKey.leftCommandCode, command: false, option: true, at: 0.20))
    }

    // MARK: - Settings recorder (side detection)

    private func record(_ r: inout ModifierDoubleTapRecorder,
                        keyCode: UInt16, command: Bool,
                        option: Bool = false, shift: Bool = false, control: Bool = false,
                        at time: TimeInterval) -> ModifierTapKey? {
        r.handle(keyCode: keyCode, commandDown: command, optionDown: option,
                 shiftDown: shift, controlDown: control, at: time)
    }

    func testRecorderDetectsLeftCommand() {
        var r = ModifierDoubleTapRecorder()
        _ = record(&r, keyCode: ModifierTapKey.leftCommandCode, command: true, at: 0.00)
        _ = record(&r, keyCode: ModifierTapKey.leftCommandCode, command: false, at: 0.05)
        _ = record(&r, keyCode: ModifierTapKey.leftCommandCode, command: true, at: 0.15)
        XCTAssertEqual(record(&r, keyCode: ModifierTapKey.leftCommandCode, command: false, at: 0.20), ModifierTapKey.leftCommand)
    }

    func testRecorderDetectsRightCommand() {
        var r = ModifierDoubleTapRecorder()
        _ = record(&r, keyCode: ModifierTapKey.rightCommandCode, command: true, at: 0.00)
        _ = record(&r, keyCode: ModifierTapKey.rightCommandCode, command: false, at: 0.05)
        _ = record(&r, keyCode: ModifierTapKey.rightCommandCode, command: true, at: 0.15)
        XCTAssertEqual(record(&r, keyCode: ModifierTapKey.rightCommandCode, command: false, at: 0.20), ModifierTapKey.rightCommand)
    }

    func testRecorderDetectsLeftOption() {
        var r = ModifierDoubleTapRecorder()
        _ = record(&r, keyCode: ModifierTapKey.leftOptionCode, command: false, option: true, at: 0.00)
        _ = record(&r, keyCode: ModifierTapKey.leftOptionCode, command: false, option: false, at: 0.05)
        _ = record(&r, keyCode: ModifierTapKey.leftOptionCode, command: false, option: true, at: 0.15)
        XCTAssertEqual(record(&r, keyCode: ModifierTapKey.leftOptionCode, command: false, option: false, at: 0.20), ModifierTapKey.leftOption)
    }

    func testRecorderDetectsRightOption() {
        var r = ModifierDoubleTapRecorder()
        _ = record(&r, keyCode: ModifierTapKey.rightOptionCode, command: false, option: true, at: 0.00)
        _ = record(&r, keyCode: ModifierTapKey.rightOptionCode, command: false, option: false, at: 0.05)
        _ = record(&r, keyCode: ModifierTapKey.rightOptionCode, command: false, option: true, at: 0.15)
        XCTAssertEqual(record(&r, keyCode: ModifierTapKey.rightOptionCode, command: false, option: false, at: 0.20), ModifierTapKey.rightOption)
    }

    func testRecorderReportsNothingForASingleTap() {
        var r = ModifierDoubleTapRecorder()
        _ = record(&r, keyCode: ModifierTapKey.rightCommandCode, command: true, at: 0.00)
        XCTAssertNil(record(&r, keyCode: ModifierTapKey.rightCommandCode, command: false, at: 0.05))
    }

    func testRecorderStillDetectsTheSideAfterAStrayTapOfTheOtherSide() {
        var r = ModifierDoubleTapRecorder()
        // A lone right-Command tap must not be counted as a right-Command double-tap.
        _ = record(&r, keyCode: ModifierTapKey.rightCommandCode, command: true, at: 0.00)
        _ = record(&r, keyCode: ModifierTapKey.rightCommandCode, command: false, at: 0.05)
        // Then a clean left-Command double-tap.
        _ = record(&r, keyCode: ModifierTapKey.leftCommandCode, command: true, at: 0.10)
        _ = record(&r, keyCode: ModifierTapKey.leftCommandCode, command: false, at: 0.15)
        _ = record(&r, keyCode: ModifierTapKey.leftCommandCode, command: true, at: 0.20)
        XCTAssertEqual(record(&r, keyCode: ModifierTapKey.leftCommandCode, command: false, at: 0.25), ModifierTapKey.leftCommand)
    }
}
