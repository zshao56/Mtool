import AppKit

/// Owns the Mtool panels and the three-scene state machine.
///
/// Flow on a main-shortcut press:
///   1. if a panel or the selection bar is already showing → close it (toggle);
///   2. otherwise ask `PopBarController` to resolve the current selection;
///   3. that resolver calls `route(snapshot:result:element:anchor:)`, which picks
///      the scene with the pure `ContextRouting` and shows the matching surface.
///
/// Scenario 1 (the action bar) is presented by `PopBarController` through the
/// `presentSelection` closure; the clipboard and search panels are owned here.
final class ContextRouter {

    private static let log = FileLog("ContextRouter")

    private(set) var scene: ContextScene = .hidden

    let clipboard: ClipboardPanelController
    let search: SearchPanelController
    let screenshot: ScreenshotCopyController

    /// Set by `PopBarController`: resolve the current selection now.
    var onResolveRequested: (() -> Void)?
    /// Set by `PopBarController`: show the action bar for a resolved selection.
    /// The pid lets the bar's Replace button write back into the source app.
    var presentSelection: ((SelectionResult, CGPoint, pid_t?) -> Void)?
    /// Set by `PopBarController`: dismiss the action bar.
    var closeSelection: (() -> Void)?
    /// Set by `PopBarController`: whether the action bar is currently showing.
    var isSelectionVisible: (() -> Bool)?

    private let store: ClipboardStore
    private let watcher: ClipboardWatcher

    /// The snapshot taken when the trigger fired, used to validate a paste.
    private var snapshot: ContextSnapshot?
    private var snapshotElement: AXUIElement?
    /// Bumped on every open/close so a stale async read is discarded.
    private var generation = 0
    /// Guards against re-entrant closes (hiding a panel can post a resign-key
    /// notification that asks to close again).
    private var isClosing = false

    init(llm: LLMService, actionStore: ActionStore, store: ClipboardStore) {
        self.store = store
        self.watcher = ClipboardWatcher(store: store)
        self.screenshot = ScreenshotCopyController(store: store)
        self.clipboard = ClipboardPanelController(store: store)
        self.search = SearchPanelController(llm: llm, actionStore: actionStore, screenshot: screenshot)

        clipboard.model.onPaste = { [weak self] item in self?.paste(item) }
        clipboard.model.onCopy = { [weak self] item in self?.copyOnly(item) }
        clipboard.model.onTogglePin = { [weak self] item in
            self?.store.setPinned(id: item.id, pinned: !item.pinned)
            self?.clipboard.model.reload()
        }
        clipboard.model.onDelete = { [weak self] item in
            self?.store.delete(id: item.id)
            self?.clipboard.model.reload()
        }
        clipboard.onCloseRequested = { [weak self] in self?.closeAll() }
        search.onCloseRequested = { [weak self] in self?.closeAll() }
        watcher.onChange = { [weak self] in
            guard let self, self.clipboard.isVisible else { return }
            self.clipboard.model.reload()
        }
    }

    // MARK: - Lifecycle

    func startClipboard() {
        guard ClipboardPreferences.enabled else { return }
        watcher.start()
        store.prune(policy: ClipboardPreferences.policy)
    }

    func stopClipboard() { watcher.stop() }

    var isAnyPanelVisible: Bool { clipboard.isVisible || search.isVisible }

    var currentGeneration: Int { generation }

    // MARK: - Main shortcut

    /// The main shortcut was pressed (or double-Command fired).
    func handleMainHotKey() {
        if isAnyPanelVisible || scene == .selection || (isSelectionVisible?() ?? false) {
            closeAll()
            return
        }
        generation &+= 1
        onResolveRequested?()
    }

    /// Close every Mtool surface and return to the hidden state. Safe to call from
    /// any scene.
    func closeAll() {
        guard !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        generation &+= 1
        clipboard.hide()
        search.hide()
        closeSelection?()
        scene = .hidden
        snapshot = nil
        snapshotElement = nil
    }

    // MARK: - Direct entry points (menu bar)

    /// Open the quick-search box without a selection snapshot (from the menu).
    func showSearch() {
        generation &+= 1
        scene = .search
        search.show(near: NSEvent.mouseLocation)
    }

    /// Open the clipboard panel without a selection snapshot (from the menu).
    func showClipboard() {
        generation &+= 1
        scene = .clipboard
        clipboard.show(near: NSEvent.mouseLocation)
    }

    // MARK: - Routing

    /// Called by `PopBarController` once the selection read has finished.
    func route(snapshot: ContextSnapshot,
               result: SelectionResult?,
               element: AXUIElement?,
               anchor: CGPoint) {
        // Ignore a read that belongs to an older generation.
        guard snapshot.generation == generation else {
            log.debug("discarding stale route (gen \(snapshot.generation) ≠ \(generation))")
            return
        }
        // The read was asynchronous: if the user switched apps while it was in
        // flight, the result describes a context that is no longer current and
        // must not open a panel over the new frontmost app.
        let nowPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard ContextRouting.isCurrent(frontPIDAtTrigger: snapshot.frontAppPID, frontPIDNow: nowPID) else {
            log.info("discarding stale route — frontmost pid changed (\(nowPID.map(String.init) ?? "nil") ≠ \(snapshot.frontAppPID.map(String.init) ?? "nil"))")
            return
        }
        var snap = snapshot
        snap.selectedText = result?.text
        self.snapshot = snap
        self.snapshotElement = element

        let routed = ContextRouting.scene(for: snap)
        scene = routed
        log.info("routed scene=\(routed.rawValue) selected=\(ContextRouting.hasActionableSelection(result?.text)) editable=\(snap.focused?.looksEditable ?? false)")

        switch routed {
        case .selection:
            if let result {
                presentSelection?(result, anchor, snap.frontAppPID.map { pid_t($0) })
            }
        case .clipboard:
            clipboard.show(near: anchor)
        case .search:
            search.show(near: anchor)
        case .hidden:
            break
        }
    }

    // MARK: - Paste

    /// Paste a history/snippet entry into the original target, validating first.
    ///
    /// Safety is enforced in two stages:
    ///  1. the captured snapshot must still describe a running, non-secure
    ///     element in the same app;
    ///  2. our panel is closed and the original app is brought back, and only
    ///     after focus has settled do we re-read the system-wide focused element
    ///     and require it to be the *same* element (pid + identity). Only then do
    ///     we write, or fall back to a synthesised ⌘V. On any mismatch the entry
    ///     is copied and the user is told — nothing is typed into another window.
    private func paste(_ item: ClipboardItem) {
        guard let text = item.text, !text.isEmpty else {
            // Images cannot be pasted through a text field; copy them instead.
            copyOnly(item)
            return
        }
        guard let snap = snapshot, let pid = snap.frontAppPID, let captured = snapshotElement else {
            log.info("no captured editable target — copying only")
            copyOnly(item)
            return
        }
        let target = NSRunningApplication(processIdentifier: pid_t(pid))
        guard target?.bundleIdentifier == snap.frontAppBundleID,
              !FocusedInputInspector.isSecureInputActive(),
              !FocusedInputInspector.inspect(captured).isSecure else {
            log.info("paste target no longer valid — copying only")
            copyOnly(item)
            return
        }

        // Dismiss our panel and hand focus back BEFORE re-reading, so the
        // focused-element query describes the original app, not our panel.
        closeAll()
        let pasteGeneration = generation
        target?.activate(options: [])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == pasteGeneration else { return }
            self.finishPaste(text, item: item, captured: captured)
        }
    }

    /// Re-read the system focus after it has been restored and only proceed when
    /// it is the captured element.
    private func finishPaste(_ text: String, item: ClipboardItem, captured: AXUIElement) {
        let current = FocusedInputInspector.focusedElement()
        guard let current, FocusedInputInspector.isSameElement(current, captured) else {
            log.info("focus did not return to the captured element — copying only")
            copyOnly(item)
            return
        }

        // Preferred: a position-correct accessibility write.
        if FocusedInputInspector.writeText(text, to: current) {
            store.markUsed(id: item.id)
            log.info("pasted via AX (\(text.count) chars)")
            return
        }

        // Focus is confirmed, so a transient-clipboard ⌘V lands in the right place.
        synthesizePaste(text, item: item)
    }

    private func synthesizePaste(_ text: String, item: ClipboardItem) {
        let backup = Pasteboard.backup()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Tag it transient so the watcher (and compliant managers) skip it.
        pasteboard.setData(Data(), forType: Pasteboard.Marker.transient)
        watcher.resync()

        // Focus was already restored and verified; post the paste without
        // re-activating anything (which could move focus again).
        KeySender.paste()
        store.markUsed(id: item.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            Pasteboard.restore(backup)
            self.watcher.resync()
        }
    }

    /// Copy an entry to the clipboard without touching the original target.
    private func copyOnly(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if item.kind == .image, let path = item.blobPath,
           let data = try? Data(contentsOf: store.blobURL(for: path)) {
            pasteboard.setData(data, forType: .png)
        } else {
            pasteboard.setString(item.text ?? item.displayText, forType: .string)
        }
        pasteboard.setData(Data(), forType: Pasteboard.Marker.transient)
        watcher.resync()
        RegionToast.show(L("clipboard.copied"), atGlobalCocoa: NSEvent.mouseLocation)
        log.info("copied clipboard entry (kind \(item.kind.rawValue))")
        closeAll()
    }
}
