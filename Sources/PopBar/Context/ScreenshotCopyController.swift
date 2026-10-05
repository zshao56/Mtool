import AppKit

/// Scenario-3 screenshot shortcut: drag a region, and the pixels are copied to
/// the clipboard as a PNG. Reuses the upstream region selector and capture
/// service; adds the "raw image straight to the pasteboard" path the plan asks
/// for. Cancelling (Esc / right-click / a tiny drag) changes nothing.
final class ScreenshotCopyController {

    private static let log = FileLog("ScreenshotCopy")

    private let store: ClipboardStore
    private var selector: RegionSelectionController?
    private var capturing = false

    init(store: ClipboardStore) {
        self.store = store
    }

    /// Whether a capture is in flight (prevents a second overlay).
    var isCapturing: Bool { capturing }

    /// Begin a capture. `completion` is called on the main thread with whether an
    /// image was copied; nil when the user cancelled.
    func begin(completion: ((Bool?) -> Void)? = nil) {
        guard !capturing else { return }
        guard ScreenRecordingAuthorizer.isAuthorized else {
            log.warn("no Screen Recording permission — requesting")
            if !ScreenRecordingAuthorizer.request() {
                ScreenRecordingAuthorizer.openSettings()
            }
            completion?(false)
            return
        }
        capturing = true
        let selector = RegionSelectionController()
        self.selector = selector
        selector.begin { [weak self] selection in
            guard let self else { return }
            self.selector = nil
            self.capturing = false
            guard let selection else { completion?(nil); return }

            let rect = selection.globalCocoaRect
            guard let image = ScreenCaptureService.capture(globalCocoaRect: rect, on: selection.screen) else {
                self.log.warn("screen capture returned nil")
                RegionToast.show(L("screenshot.copy.failed"),
                                 atGlobalCocoa: CGPoint(x: rect.midX, y: rect.maxY))
                completion?(false)
                return
            }
            guard let png = Self.pngData(from: image) else {
                RegionToast.show(L("screenshot.copy.failed"),
                                 atGlobalCocoa: CGPoint(x: rect.midX, y: rect.maxY))
                completion?(false)
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            // Also offer the image as an NSImage representation for apps that
            // only look at the legacy types.
            let nsImage = NSImage(cgImage: image, size: .zero)
            pasteboard.writeObjects([nsImage])

            let anchor = CGPoint(x: rect.midX, y: rect.maxY)
            RegionToast.show(L("screenshot.copy.done"), atGlobalCocoa: anchor)
            self.log.info("copied screenshot \(image.width)×\(image.height) to the clipboard")
            completion?(true)
        }
    }

    private static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
