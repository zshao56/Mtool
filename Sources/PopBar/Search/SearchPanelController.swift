import AppKit
import SwiftUI

/// Hosts the quick-search panel (scenario 3) and drives the LLM behind it.
/// Non-activating like the clipboard panel, so the app the user was in stays
/// frontmost.
final class SearchPanelController {

    private static let log = FileLog("Search.Panel")

    let model = SearchPanelModel()
    private let llm: LLMService
    private let actionStore: ActionStore
    private let screenshot: ScreenshotCopyController
    private var panel: MtoolFloatingPanel?
    private var escapeMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var streamTask: Task<Void, Never>?

    var onCloseRequested: (() -> Void)?

    init(llm: LLMService, actionStore: ActionStore, screenshot: ScreenshotCopyController) {
        self.llm = llm
        self.actionStore = actionStore
        self.screenshot = screenshot
        model.onClose = { [weak self] in self?.onCloseRequested?() }
        model.onSubmit = { [weak self] text, mode in self?.run(text: text, mode: mode) }
        model.onScreenshot = { [weak self] in self?.beginScreenshot() }
        model.onResize = { [weak self] in self?.resizePanel() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(near anchor: CGPoint) {
        let panel = ensurePanel()
        model.resetForOpen()
        // Refresh the mode list from the current actions each time it opens.
        model.loadModes(from: actionStore.actions)
        position(panel, near: anchor)
        // Activate so the query field can take keystrokes.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installEscMonitor()
        Self.log.debug("search panel shown")
    }

    func hide() {
        streamTask?.cancel()
        streamTask = nil
        removeEscMonitor()
        panel?.orderOut(nil)
    }

    // MARK: - Screenshot shortcut

    private func beginScreenshot() {
        onCloseRequested?()   // the plan: clicking screenshot closes the search box first
        screenshot.begin { ok in
            if ok == false {
                Self.log.info("screenshot not copied (permission or capture failure)")
            }
        }
    }

    // MARK: - LLM

    private func run(text: String, mode: SearchMode) {
        guard let config = llm.defaultConfig() else {
            model.finish(result: nil, error: L("popbar.error.nokey"))
            return
        }
        streamTask?.cancel()
        model.busy = true
        let system = mode.prompt
        let user = text
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.llm.stream(config, system: system, user: user) { displayed in
                    Task { @MainActor in self.model.appendStream(displayed) }
                }
                await MainActor.run {
                    self.model.finish(result: output, error: output.isEmpty ? L("popbar.error.empty") : nil)
                }
            } catch is CancellationError {
                await MainActor.run { self.model.busy = false }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self.model.finish(result: nil, error: message) }
            }
        }
    }

    // MARK: - Panel construction

    private func ensurePanel() -> MtoolFloatingPanel {
        if let panel { return panel }
        let hosting = NSHostingController(rootView: SearchPanelView(model: model))
        let panel = MtoolFloatingPanel(contentViewController: hosting)
        panel.setContentSize(NSSize(width: 560, height: 160))
        panel.contentView?.layer?.cornerRadius = 24
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        self.panel = panel
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.onCloseRequested?()
        }
        return panel
    }

    private func resizePanel() {
        guard let panel else { return }
        panel.setContentSize(NSSize(width: 560, height: model.showsOutput ? 370 : 160))
    }

    private func position(_ panel: NSPanel, near anchor: CGPoint) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }
        var x = anchor.x + 16
        var y = anchor.y - 40
        if x + size.width > frame.maxX - 8 { x = anchor.x - size.width - 16 }
        if y + size.height > frame.maxY - 8 { y = frame.maxY - size.height - 8 }
        if y < frame.minY + 8 { y = frame.minY + 8 }
        x = min(max(x, frame.minX + 8), frame.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installEscMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {   // Esc
                self?.onCloseRequested?()
                return nil
            }
            return event
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
