import XCTest

/// The three-scene routing priority: a selection always wins (even in an input
/// control), then an editable focused control, then the search box. Anything the
/// inspector could not read reliably must fall through to the search box.
///
/// Editable detection is "known text role + a writable attribute", not the
/// non-standard `AXEditable` attribute, because browsers and Electron apps
/// (WeChat) expose `AXTextField`/`AXTextArea`/`AXSearchField` with a writable
/// value but no `AXEditable`.
final class ContextRoutingTests: XCTestCase {

    private func focus(role: String? = "AXTextField",
                       subrole: String? = nil,
                       secure: Bool = false,
                       enabled: Bool = true,
                       editable: Bool? = nil,
                       selectedTextSettable: Bool = false,
                       valueSettable: Bool = false,
                       fallback: Bool = false) -> FocusedInputInfo {
        FocusedInputInfo(role: role, subrole: subrole, enabled: enabled,
                         editable: editable,
                         selectedTextSettable: selectedTextSettable,
                         valueSettable: valueSettable,
                         isSecure: secure,
                         isBrowserOrElectronFallback: fallback)
    }

    func testSelectionWinsEvenInsideAnInput() {
        let snapshot = ContextSnapshot(frontAppBundleID: "com.apple.Safari",
                                       selectedText: "hello",
                                       focused: focus(selectedTextSettable: true))
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .selection)
    }

    func testEditableWithNoSelectionGoesToClipboard() {
        let snapshot = ContextSnapshot(frontAppBundleID: "com.apple.TextEdit",
                                       selectedText: nil,
                                       focused: focus(selectedTextSettable: true))
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
        let snapshot = ContextSnapshot(selectedText: nil,
                                       focused: focus(secure: true, selectedTextSettable: true))
        XCTAssertFalse(snapshot.focused!.looksEditable)
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .search)
    }

    func testDisabledFieldIsNeverEditable() {
        let snapshot = ContextSnapshot(selectedText: nil,
                                       focused: focus(enabled: false, selectedTextSettable: true))
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .search)
    }

    /// A role with no writable attribute must not be pasted into — this is the
    /// "never paste on role alone" rule. A read-only `AXTextArea` looks the same.
    func testRoleAloneIsNotEnough() {
        let snapshot = ContextSnapshot(selectedText: nil, focused: focus(role: "AXTextArea"))
        XCTAssertFalse(snapshot.focused!.looksEditable)
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .search)
    }

    /// The browser/Electron case: a known text role plus a writable value, with
    /// no `AXEditable` at all.
    func testKnownTextRolePlusWritableIsEditable() {
        let searchField = ContextSnapshot(selectedText: nil,
                                          focused: focus(role: "AXSearchField", valueSettable: true))
        XCTAssertEqual(ContextRouting.scene(for: searchField), .clipboard)

        let textArea = ContextSnapshot(selectedText: nil,
                                       focused: focus(role: "AXTextArea", selectedTextSettable: true))
        XCTAssertEqual(ContextRouting.scene(for: textArea), .clipboard)
    }

    /// A missing `AXEditable` attribute must not block a known text role with a
    /// writable value (the exact case the tri-state exists for).
    func testMissingEditableWithKnownRoleIsAllowed() {
        let snapshot = ContextSnapshot(selectedText: nil,
                                       focused: focus(role: "AXTextField", editable: nil,
                                                      valueSettable: true))
        XCTAssertTrue(snapshot.focused!.looksEditable)
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .clipboard)
    }

    /// An explicit `AXEditable = false` is a read-only control: scenario 2 must
    /// be refused even though the role is a text role and the value is settable.
    func testExplicitNotEditableRefusesScenarioTwo() {
        let snapshot = ContextSnapshot(selectedText: nil,
                                       focused: focus(role: "AXTextField", editable: false,
                                                      valueSettable: true))
        XCTAssertFalse(snapshot.focused!.looksEditable)
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .search)
    }

    /// An unfamiliar role with a writable attribute is not enough on its own; it
    /// needs `AXEditable` or the browser/Electron evidence.
    func testUnknownRolePlusWritableIsNotEditable() {
        let snapshot = ContextSnapshot(selectedText: nil,
                                       focused: focus(role: "AXWebArea", valueSettable: true))
        XCTAssertFalse(snapshot.focused!.looksEditable)
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .search)
    }

    func testEditableAttributeIsExtraEvidence() {
        let snapshot = ContextSnapshot(selectedText: nil,
                                       focused: focus(role: "AXCustomText", editable: true,
                                                      valueSettable: true))
        XCTAssertEqual(ContextRouting.scene(for: snapshot), .clipboard)
    }

    func testBlankSelectionIsNotASelection() {
        XCTAssertFalse(ContextRouting.hasActionableSelection(nil))
        XCTAssertFalse(ContextRouting.hasActionableSelection(""))
        XCTAssertFalse(ContextRouting.hasActionableSelection("  \n\t "))
        XCTAssertTrue(ContextRouting.hasActionableSelection("x"))
        let snapshot = ContextSnapshot(selectedText: "\n",
                                       focused: focus(selectedTextSettable: true))
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
