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
        search.onClipboardRequested = { [weak self] in self?.showClipboardFromSearch() }
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

    /// Switch from the editable-context question box to clipboard history while
    /// retaining the captured input element for a validated paste.
    private func showClipboardFromSearch() {
        guard scene == .clipboard else { return }
        search.hide()
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
            Self.log.debug("discarding stale route (gen \(snapshot.generation) ≠ \(self.generation))")
            return
        }
        // The read was asynchronous: if the user switched apps while it was in
        // flight, the result describes a context that is no longer current and
        // must not open a panel over the new frontmost app.
        let nowPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard ContextRouting.isCurrent(frontPIDAtTrigger: snapshot.frontAppPID, frontPIDNow: nowPID) else {
            Self.log.info("discarding stale route — frontmost pid changed (\(nowPID.map(String.init) ?? "nil") ≠ \(snapshot.frontAppPID.map(String.init) ?? "nil"))")
            return
        }
        var snap = snapshot
        snap.selectedText = result?.text
        self.snapshot = snap
        self.snapshotElement = element

        let routed = ContextRouting.scene(for: snap)
        scene = routed
        Self.log.info("routed scene=\(routed.rawValue) selected=\(ContextRouting.hasActionableSelection(result?.text)) editable=\(snap.focused?.looksEditable ?? false)")

        switch routed {
        case .selection:
            if let result {
                presentSelection?(result, anchor, snap.frontAppPID.map { pid_t($0) })
            }
        case .clipboard:
            search.show(near: anchor, allowsClipboard: true)
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
        // Images have no text to write through AX, but can still be pasted into a
        // confirmed target through a transient clipboard.
        let isImage = item.kind == .image
        if !isImage, (item.text?.isEmpty ?? true) {
            copyOnly(item)
            return
        }
        guard let snap = snapshot, let pid = snap.frontAppPID, let captured = snapshotElement else {
            Self.log.info("no captured editable target — copying only")
            copyOnly(item)
            return
        }
        let target = NSRunningApplication(processIdentifier: pid_t(pid))
        guard target?.bundleIdentifier == snap.frontAppBundleID,
              !FocusedInputInspector.isSecureInputActive(),
              !FocusedInputInspector.inspect(captured).isSecure else {
            Self.log.info("paste target no longer valid — copying only")
            copyOnly(item)
            return
        }

        // Dismiss our panel and hand focus back BEFORE re-reading, so the
        // focused-element query describes the original app, not our panel.
        closeAll()
        let pasteGeneration = generation
        target?.activate(options: [])
        waitForFocusAndPaste(item: item, captured: captured, targetPID: pid_t(pid),
                             expectedGeneration: pasteGeneration,
                             deadline: Date().addingTimeInterval(1.0))
    }

    /// Poll (briefly) for focus to return to the captured element, then paste.
    ///
    /// The wait is bounded: every 50 ms we re-check that the user has not
    /// re-triggered (generation), that no third app came forward, and that the
    /// system-wide focused element is the captured one. On timeout, on a
    /// frontmost-app change, or on a generation change we copy only — nothing is
    /// ever typed into a window we could not re-validate.
    private func waitForFocusAndPaste(item: ClipboardItem, captured: AXUIElement,
                                      targetPID: pid_t, expectedGeneration: Int,
                                      deadline: Date) {
        guard generation == expectedGeneration else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication {
            let frontPID = front.processIdentifier
            if frontPID != targetPID && frontPID != ownPID {
                Self.log.info("a different app came forward during the paste wait — copying only")
                copyOnly(item)
                return
            }
        }

        if let focused = FocusedInputInspector.focusedElement(),
           FocusedInputInspector.isSameElement(focused, captured) {
            pasteIntoConfirmedElement(item: item, element: focused)
            return
        }

        guard Date() < deadline else {
            Self.log.info("focus did not return to the captured element within 1s — copying only")
            copyOnly(item)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForFocusAndPaste(item: item, captured: captured, targetPID: targetPID,
                                       expectedGeneration: expectedGeneration, deadline: deadline)
        }
    }

    private func pasteIntoConfirmedElement(item: ClipboardItem, element: AXUIElement) {
        // Text: prefer a position-correct accessibility write.
        if let text = item.text, !text.isEmpty,
           FocusedInputInspector.writeText(text, to: element) {
            store.markUsed(id: item.id)
            Self.log.info("pasted via AX (\(text.count) chars)")
            return
        }

        // Text write refused, or the entry is an image: paste through a transient
        // clipboard. Focus is confirmed, so it lands in the right place.
        synthesizePaste(item: item)
    }

    /// What goes on the pasteboard for a synthesised paste.
    private enum PasteboardPayload {
        case text(String)
        case image(Data)

        func write(to pasteboard: NSPasteboard) {
            switch self {
            case .text(let string): pasteboard.setString(string, forType: .string)
            case .image(let data): pasteboard.setData(data, forType: .png)
            }
        }
    }

    private func payload(for item: ClipboardItem) -> PasteboardPayload? {
        if item.kind == .image {
            guard let path = item.blobPath,
                  let data = try? Data(contentsOf: store.blobURL(for: path)) else { return nil }
            return .image(data)
        }
        guard let text = item.text, !text.isEmpty else { return nil }
        return .text(text)
    }

    private func synthesizePaste(item: ClipboardItem) {
        guard let payload = payload(for: item) else {
            copyOnly(item)
            return
        }
        let backup = Pasteboard.backup()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        payload.write(to: pasteboard)
        // Tag it transient so the watcher (and compliant managers) skip it.
        pasteboard.setData(Data(), forType: Pasteboard.Marker.transient)
        // Remember exactly what our write produced: if the count moved again by
        // the time we would restore, the user copied something of their own and
        // their clipboard must win.
        let ourChangeCount = pasteboard.changeCount
        watcher.resync()

        // Focus was already restored and verified; post the paste without
        // re-activating anything (which could move focus again).
        KeySender.paste()
        store.markUsed(id: item.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if NSPasteboard.general.changeCount == ourChangeCount {
                Pasteboard.restore(backup)
            } else {
                Self.log.info("clipboard changed after our paste — not restoring")
            }
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
        Self.log.info("copied clipboard entry (kind \(item.kind.rawValue))")
        closeAll()
    }
}
