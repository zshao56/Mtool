import XCTest
import CoreGraphics

/// The link resolver's point tier asks accessibility "what is under the cursor?".
/// When the answer is one of Mtool's own windows (the ring is usually right there),
/// macOS services that question inside Mtool, on the resolver's background thread,
/// and AppKit/SwiftUI then touch the window off the main thread. That froze the app
/// with the ring stuck on screen. So the tier must first see that the point is ours.
final class OwnWindowHitTests: XCTestCase {
    private let me: pid_t = 4242
    private func win(pid: pid_t, _ r: CGRect, alpha: Double = 1) -> [String: Any] {
        [kCGWindowOwnerPID as String: Int(pid),
         kCGWindowBounds as String: r.dictionaryRepresentation,
         kCGWindowAlpha as String: alpha]
    }

    func testPointInsideOurWindowIsOurs() {
        let list = [win(pid: 99, CGRect(x: 0, y: 0, width: 2000, height: 1200)),   // the browser under it
                    win(pid: me, CGRect(x: 700, y: 450, width: 300, height: 300))] // our ring
        XCTAssertTrue(OwnWindowHit.covers(CGPoint(x: 840, y: 577), windows: list, ownPID: me))
    }

    func testOurWindowCountsEvenBehindAnotherAppsWindow() {
        // Z-order is not trusted: another app's click-through overlay may sit above us.
        let list = [win(pid: 99, CGRect(x: 0, y: 0, width: 2000, height: 1200)),
                    win(pid: me, CGRect(x: 700, y: 450, width: 300, height: 300))]
        XCTAssertTrue(OwnWindowHit.covers(CGPoint(x: 710, y: 460), windows: list, ownPID: me))
    }

    func testPointOutsideOurWindowsIsNotOurs() {
        let list = [win(pid: 99, CGRect(x: 0, y: 0, width: 2000, height: 1200)),
                    win(pid: me, CGRect(x: 700, y: 450, width: 300, height: 300))]
        XCTAssertFalse(OwnWindowHit.covers(CGPoint(x: 100, y: 100), windows: list, ownPID: me))
    }

    func testFullyTransparentWindowOfOursIsIgnored() {
        let list = [win(pid: me, CGRect(x: 0, y: 0, width: 2000, height: 1200), alpha: 0)]
        XCTAssertFalse(OwnWindowHit.covers(CGPoint(x: 100, y: 100), windows: list, ownPID: me))
    }

    func testMalformedEntriesAreSkipped() {
        let list: [[String: Any]] = [[kCGWindowOwnerPID as String: Int(me)],   // no bounds
                                     [kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 10, height: 10).dictionaryRepresentation]]
        XCTAssertFalse(OwnWindowHit.covers(CGPoint(x: 5, y: 5), windows: list, ownPID: me))
    }
}
