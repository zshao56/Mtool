import XCTest

/// The pure clipboard rules: image limits, retention, capacity overflow and
/// content de-duplication.
final class ClipboardPolicyTests: XCTestCase {

    func testImageSizeLimit() {
        let policy = ClipboardPolicy(maxItems: 500, retentionDays: 30,
                                     maxImageBytes: 1024 * 1024)
        XCTAssertTrue(ClipboardPolicyEngine.shouldStoreImage(byteCount: 1024, policy: policy))
        XCTAssertFalse(ClipboardPolicyEngine.shouldStoreImage(byteCount: 2 * 1024 * 1024, policy: policy))
        // 0 = store no images.
        XCTAssertFalse(ClipboardPolicyEngine.shouldStoreImage(
            byteCount: 1, policy: ClipboardPolicy(maxItems: 1, retentionDays: 1, maxImageBytes: 0)))
    }

    func testRetention() {
        let policy = ClipboardPolicy(maxItems: 500, retentionDays: 30, maxImageBytes: 0)
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let fresh = now.addingTimeInterval(-10 * 86_400)
        let old = now.addingTimeInterval(-40 * 86_400)
        XCTAssertFalse(ClipboardPolicyEngine.isExpired(createdAt: fresh, now: now, policy: policy))
        XCTAssertTrue(ClipboardPolicyEngine.isExpired(createdAt: old, now: now, policy: policy))
        // 0 = keep forever.
        XCTAssertFalse(ClipboardPolicyEngine.isExpired(
            createdAt: old, now: now,
            policy: ClipboardPolicy(maxItems: 500, retentionDays: 0, maxImageBytes: 0)))
    }

    func testCapacityOverflow() {
        let policy = ClipboardPolicy(maxItems: 10, retentionDays: 0, maxImageBytes: 0)
        XCTAssertEqual(ClipboardPolicyEngine.overflowCount(nonPinnedStored: 8, policy: policy), 0)
        XCTAssertEqual(ClipboardPolicyEngine.overflowCount(nonPinnedStored: 12, policy: policy), 2)
        // 0 = no cap.
        XCTAssertEqual(ClipboardPolicyEngine.overflowCount(
            nonPinnedStored: 999,
            policy: ClipboardPolicy(maxItems: 0, retentionDays: 0, maxImageBytes: 0)), 0)
    }

    func testDedupeKeys() {
        XCTAssertEqual(ClipboardPolicyEngine.dedupeKey(kind: .text, text: "hello", imageDigest: nil),
                       ClipboardPolicyEngine.dedupeKey(kind: .text, text: "hello", imageDigest: nil))
        XCTAssertNotEqual(ClipboardPolicyEngine.dedupeKey(kind: .text, text: "hello", imageDigest: nil),
                          ClipboardPolicyEngine.dedupeKey(kind: .text, text: "world", imageDigest: nil))
        XCTAssertNotEqual(ClipboardPolicyEngine.dedupeKey(kind: .text, text: "x", imageDigest: nil),
                          ClipboardPolicyEngine.dedupeKey(kind: .url, text: "x", imageDigest: nil))
        XCTAssertEqual(ClipboardPolicyEngine.dedupeKey(kind: .image, text: nil, imageDigest: "abc"),
                       ClipboardPolicyEngine.dedupeKey(kind: .image, text: nil, imageDigest: "abc"))
    }

    func testPolicyClamps() {
        let wild = ClipboardPolicy(maxItems: -5, retentionDays: 100_000, maxImageBytes: -1)
        XCTAssertEqual(wild.clamped.maxItems, 0)
        XCTAssertEqual(wild.clamped.retentionDays, 365)
        XCTAssertEqual(wild.clamped.maxImageBytes, 0)
    }
}
