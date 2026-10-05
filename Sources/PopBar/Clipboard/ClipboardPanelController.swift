import AppKit
import SwiftUI

/// Hosts `ClipboardPanelView` in a non-activating floating panel, so typing in the
/// search field never steals focus from the app the user was in — which is what
/// keeps the scenario-2 paste target valid.
///
/// Closes on Esc, on an outside click (the panel resigning key), and when the main
/// shortcut is pressed again.
final class ClipboardPanelController {

    private static let log = FileLog("Clipboard.Panel")

    let model: ClipboardPanelModel
    private var panel: NSPanel?
    private var escapeMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// Fired when the panel wants to be dismissed (Esc / close button).
    var onCloseRequested: (() -> Void)?

    init(store: ClipboardStore) {
        self.model = ClipboardPanelModel(store: store)
        model.onClose = { [weak self] in self?.onCloseRequested?() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(near anchor: CGPoint) {
        let panel = ensurePanel()
        // Refresh before showing so the list is current.
        model.reload()
        position(panel, near: anchor)
        // Activate so the search field can take keystrokes. The scenario-2
        // snapshot (pid + AX element) is kept separately, so activating Mtool
        // does not lose the original paste target.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installEscMonitor()
        log.debug("clipboard panel shown")
    }

    func hide() {
        removeEscMonitor()
        panel?.orderOut(nil)
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let hosting = NSHostingController(rootView: ClipboardPanelView(model: model))
        let panel = MtoolFloatingPanel(contentViewController: hosting)
        panel.setContentSize(NSSize(width: 440, height: 500))
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        self.panel = panel
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // An outside click resigns key; treat it as "close".
            self?.onCloseRequested?()
        }
        return panel
    }

    /// Place the panel near the pointer but fully on a screen, preferring below
    /// the anchor and nudging up when there is no room.
    private func position(_ panel: NSPanel, near anchor: CGPoint) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }
        var x = anchor.x + 16
        var y = anchor.y - size.height - 16
        if y < frame.minY + 8 { y = frame.minY + 8 }
        if x + size.width > frame.maxX - 8 { x = anchor.x - size.width - 16 }
        x = min(max(x, frame.minX + 8), frame.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Esc

    private func installEscMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:   // Esc
                self.onCloseRequested?()
                return nil
            case 126:  // Up
                self.model.moveSelection(-1)
                return nil
            case 125:  // Down
                self.model.moveSelection(1)
                return nil
            case 36, 76:   // Return / Enter
                self.model.activateSelection()
                return nil
            default:
                return event
            }
        }
    }

    private func removeEscMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    deinit {
        removeEscMonitor()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

/// A borderless, non-activating panel that CAN become key (borderless windows
/// refuse it by default) so its text field receives keystrokes without the app
/// becoming active.
final class MtoolFloatingPanel: NSPanel {
    init(contentViewController: NSViewController) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = true
        // A rounded, material-backed card rather than a plain rectangle.
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 12
        contentView?.layer?.masksToBounds = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
