import XCTest

/// The three-scene routing priority: a selection always wins (even in an input
/// control), then an editable focused control, then the search box. Anything the
/// inspector could not read reliably must fall through to the search box.
final class ContextRoutingTests: XCTestCase {

    private func editable(secure: Bool = false, enabled: Bool = true,
                          editable: Bool = true, settable: Bool = true,
                          fallback: Bool = false) -> FocusedInputInfo {
        FocusedInputInfo(role: "AXTextField", subrole: nil, enabled: enabled,
                         editable: editable, selectedTextSettable: settable,
                         valueSettable: settable, isSecure: secure,
                         isBrowserOrElectronFallback: fallback)
    }

    func testSelectionWinsEvenInsideAnInput() {
        let snapshot = ContextSnapshot(frontAppBundleID: "com.apple.Safari",
                                       selectedText: "hello", focused: editable())
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .selection)
    }

    func testEditableWithNoSelectionGoesToClipboard() {
        let snapshot = ContextSnapshot(frontAppBundleID: "com.apple.TextEdit",
                                       selectedText: nil, focused: editable())
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .clipboard)
    }

    func testNoFocusGoesToSearch() {
        let snapshot = ContextSnapshot(frontAppBundleID: "com.apple.finder",
                                       selectedText: nil, focused: nil)
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .search)
    }

    func testUnknownElementIsNeverEditable() {
        let snapshot = ContextSnapshot(selectedText: nil, focused: .unknown)
        XCTAssertFalse(FocusedInputInfo.unknown.looksEditable)
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .search)
    }

    func testSecureFieldIsNeverEditable() {
        let snapshot = ContextSnapshot(selectedText: nil, focused: editable(secure: true))
        XCTAssertFalse(snapshot.focused!.looksEditable)
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .search)
    }

    func testDisabledFieldIsNeverEditable() {
        let snapshot = ContextSnapshot(selectedText: nil, focused: editable(enabled: false))
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .search)
    }

    func testRoleAloneIsNotEnough() {
        // AXTextArea with no settable attribute must not be treated as editable:
        // a read-only text area reports the same role.
        let snapshot = ContextSnapshot(selectedText: nil,
                                       focused: editable(editable: false, settable: false))
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .search)
    }

    func testBlankSelectionIsNotASelection() {
        XCTAssertFalse(ContextRouting.hasActionableSelection(nil))
        XCTAssertFalse(ContextRouting.hasActionableSelection(""))
        XCTAssertFalse(ContextRouting.hasActionableSelection("  \n\t "))
        XCTAssertTrue(ContextRouting.hasActionableSelection("x"))
        let snapshot = ContextSnapshot(selectedText: "\n", focused: editable())
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .clipboard)
    }

    func testBrowserFallbackRequiresVerifiedFlag() {
        let snapshot = ContextSnapshot(selectedText: nil,
                                       focused: editable(editable: false, settable: false, fallback: true))
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .clipboard)
    }

    func testStaleAppResultIsDiscarded() {
        // Same frontmost app → the read is still current.
        XCTAssertTrue(ContextRouting.isCurrent(frontPIDAtTrigger: 42, frontPIDNow: 42))
        // A different app came forward while the read was in flight → discard.
        XCTAssertFalse(ContextRouting.isCurrent(frontPIDAtTrigger: 42, frontPIDNow: 43))
        // Could not capture a pid at trigger time → nothing to compare; keep it.
        XCTAssertTrue(ContextRouting.isCurrent(frontPIDAtTrigger: nil, frontPIDNow: 43))
        // Could not read the frontmost app right now → do not drop a valid result.
        XCTAssertTrue(ContextRouting.isCurrent(frontPIDAtTrigger: 42, frontPIDNow: nil))
    }
}
