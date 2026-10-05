import CoreGraphics
import Foundation

/// Whether a screen point lies on one of Mtool's own windows — asked before any
/// accessibility call that hit-tests the screen from a background thread.
///
/// `AXUIElementCopyElementAtPosition` on a point over our own window (the ring sits
/// right at the cursor) is answered inside this process, on the calling thread. The
/// resolver runs off the main thread, so AppKit and SwiftUI then read and lay out our
/// window off-main: AppKit throws "NSWindow geometry should only be modified on the
/// main thread", SwiftUI's render lock is left held, and the next display cycle on the
/// main thread waits on it forever — the app freezes with the ring stuck on screen.
///
/// Uses the window server's list (safe on any thread), never `NSApp.windows`.
enum OwnWindowHit {
    /// `point` is in window-server coordinates: top-left origin of the primary
    /// display, the same space as AX positions and `kCGWindowBounds`.
    static func coversNow(_ point: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return covers(point, windows: list, ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Any on-screen, visible window of ours containing the point counts, whatever its
    /// stacking: another app's click-through overlay may sit above ours, and a false
    /// "ours" only skips one link lookup.
    static func covers(_ point: CGPoint, windows: [[String: Any]], ownPID: pid_t) -> Bool {
        windows.contains { w in
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid == ownPID,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return false }
            if let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha == 0 { return false }
            return bounds.contains(point)
        }
    }
}
