import Cocoa
import SwiftUI

// MARK: - OnboardingWindowController
//
// The first-run guide: its own fixed-size window, the same family as the
// settings window (sidebar, colored tiles, aurora). Closing it is always fine —
// everything it did has already taken effect, and progress is remembered.
final class OnboardingWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let model: OnboardingModel
    /// Permissions are granted in System Settings, in another process, and the
    /// app is never told — so the guide polls while it is on screen, once a
    /// second, and also checks the moment the app becomes active again.
    private var poll: Timer?
    private var activeObserver: NSObjectProtocol?

    init(appState: AppState) {
        model = OnboardingModel(appState: appState)

        let root = OnboardingView(model: model)
        let hosting = NSHostingController(rootView: root)
        // The window is a fixed 740×520 (below); the view fills it rather than
        // asking to be some size of its own.
        hosting.sizingOptions = []

        window = NSWindow(contentViewController: hosting)
        window.title = L("onboarding.windowTitle")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 740, height: 520))
        window.center()
        super.init()
        window.delegate = self
        model.requestClose = { [weak self] in self?.window.performClose(nil) }
    }

    var isVisible: Bool { window.isVisible }

    func show(reason: OnboardingOpenReason) {
        // Already up: just bring it forward, without moving it to another page.
        if !window.isVisible {
            model.opened(reason: reason)
            window.center()
            startPolling()
        }
        // Same order as the settings window (MainWindowController.show): front
        // first, then activate, or macOS 14+ can leave it behind the previous app.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        model.closed()
    }

    private func startPolling() {
        stopPolling()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.model.refresh()
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.model.refresh()
        }
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }
}
