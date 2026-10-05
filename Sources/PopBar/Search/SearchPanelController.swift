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
    private var lastAnchor: CGPoint?

    var onCloseRequested: (() -> Void)?
    var onClipboardRequested: (() -> Void)?
    var onEditModesRequested: (() -> Void)?

    init(llm: LLMService, actionStore: ActionStore, screenshot: ScreenshotCopyController) {
        self.llm = llm
        self.actionStore = actionStore
        self.screenshot = screenshot
        model.onClose = { [weak self] in self?.onCloseRequested?() }
        model.onSubmit = { [weak self] text, mode in self?.run(text: text, mode: mode) }
        model.onScreenshot = { [weak self] in self?.beginScreenshot() }
        model.onClipboard = { [weak self] in self?.onClipboardRequested?() }
        model.onEditModes = { [weak self] in self?.onEditModesRequested?() }
        model.onResize = { [weak self] in self?.resizePanel() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(near anchor: CGPoint, allowsClipboard: Bool = false, selectedModeID: String? = nil) {
        let panel = ensurePanel()
        lastAnchor = anchor
        model.resetForOpen()
        model.showsClipboardButton = allowsClipboard
        // Refresh the mode list from the current actions each time it opens.
        model.loadModes(from: actionStore.actions)
        if let selectedModeID, model.modes.contains(where: { $0.id == selectedModeID }) {
            model.selectedModeID = selectedModeID
            model.toolbarSelection = selectedModeID
        } else {
            model.selectedModeID = "ask"
            model.toolbarSelection = "ask"
        }
        position(panel, near: anchor)
        // Activate so the query field can take keystrokes.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // A reused SwiftUI text field can appear before this panel becomes key.
        // Request focus again on the next run loop, after AppKit has made it key.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard panel?.isVisible == true else { return }
            self?.model.focusRequestID = UUID()
        }
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
        let config = mode.modelOverride.flatMap {
            llm.config(forProvider: $0.provider, model: $0.model, effort: $0.reasoningEffort)
        } ?? (mode.modelOverride == nil ? llm.defaultConfig() : nil)
        guard let config else {
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
        panel.setContentSize(SearchPanelLayout.size(showsOutput: false))
        panel.contentView?.layer?.cornerRadius = 24
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        self.panel = panel
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.onCloseRequested?()
        }
        return panel
    }

    private func resizePanel() {
        guard let panel else { return }
        let target = SearchPanelLayout.size(showsOutput: model.showsOutput)
        let current = panel.contentRect(forFrameRect: panel.frame).size
        guard current != target else { return }
        panel.setContentSize(target)
        clampToVisibleScreen(panel)
    }

    private func position(_ panel: NSPanel, near anchor: CGPoint) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        var x = anchor.x + 16
        var y = anchor.y - 40
        if x + size.width > frame.maxX - 8 { x = anchor.x - size.width - 16 }
        if y + size.height > frame.maxY - 8 { y = frame.maxY - size.height - 8 }
        if y < frame.minY + 8 { y = frame.minY + 8 }
        x = min(max(x, frame.minX + 8), frame.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func clampToVisibleScreen(_ panel: NSPanel) {
        let frame = panel.frame
        let screen = NSScreen.screens.filter { $0.frame.intersects(frame) }.max { lhs, rhs in
            let lhsArea = lhs.frame.intersection(frame)
            let rhsArea = rhs.frame.intersection(frame)
            return lhsArea.width * lhsArea.height < rhsArea.width * rhsArea.height
        }
            ?? lastAnchor.flatMap { anchor in NSScreen.screens.first { $0.frame.contains(anchor) } }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        let y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installEscMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {   // Esc
                self.onCloseRequested?()
                return nil
            }
            if !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                return event
            }
            switch event.keyCode {
            case 123: self.model.moveToolbarSelection(-1); return nil
            case 124: self.model.moveToolbarSelection(1); return nil
            case 36, 76: self.model.activateToolbarSelection(); return nil
            default: break
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
