import AppKit

/// The app-lifetime coordinator that wires the layers together: it listens for
/// selection gestures (trigger), resolves the selected text (selection), and asks
/// the window manager to show / recycle the capsule. Per-window concerns (which
/// windows exist, pin promotion, each window's action/stream lifecycle) live in
/// `PopBarWindowManager` + `PopBarSession`, so multiple pinned windows can coexist
/// and a new selection never disturbs a pinned window (issue #13).
///
/// Main-thread only by convention (like `GuardianReaper`): `NSEvent` monitor
/// callbacks, SwiftUI callbacks, and `activate()` all arrive on main. The one
/// piece that runs off-main is the resolver `Task`, which hops back to main
/// before touching any window.
final class PopBarController {

    private static let log = FileLog("PopBar")

    private let resolver: SelectionResolver
    private let monitor: GlobalInputMonitor
    private let windows: PopBarWindowManager
    private let llm: LLMService
    private let actionStore: ActionStore
    /// The screenshot-OCR front-step (hotkey → drag-select → OCR → capsule). Reuses
    /// this controller's window manager + actions; its lifecycle is independent of the
    /// selection monitor (see `startOCRIfEnabled`).
    private let ocr: ScreenOCRController

    /// Mtool's three-scene router. Owns the clipboard and search panels; scenario
    /// 1 is presented through this controller's window manager.
    let router: ContextRouter

    /// The main shortcut (the app's one primary gesture). Registered while
    /// `MtoolPreferences.mainHotKeyEnabled` is on.
    private var mainHotKey: GlobalHotKey?
    /// The optional double-tap-Command trigger.
    private var doubleTap: ModifierDoubleTapMonitor?
    /// Screen point the transient capsule's CURRENT selection is anchored to (the
    /// selection's raw mouse-up location), used to suppress flicker from a
    /// double→triple-click re-trigger. Kept here (not on the window) because the
    /// window's own anchor may be offset to avoid overlapping a pinned window.
    private var lastAnchor: CGPoint = .zero
    /// How close a new trigger must be to the current capsule to be treated as
    /// the same selection (keep it, don't re-read/re-show).
    private let sameSelectionRadius: CGFloat = 40
    /// The popup hotkey (issue #4), registered while `popupHotKeyEnabled` is on.
    private var popupHotKey: GlobalHotKey?
    private var resolveTask: Task<Void, Never>?
    /// Bumped per trigger so a slow/canceled resolve can't act on the panel after
    /// a newer trigger has taken over.
    private var resolveGeneration = 0
    /// A popup's Pause action was used. The store answers it, because the paused
    /// state is the store's: it persists it and the menu bar and sidebar show it.
    var onPauseRequested: (() -> Void)?
    /// A popup's Settings action was used. The menu bar controller answers it,
    /// since it owns the settings window.
    var onSettingsRequested: (() -> Void)?

    init(llm: LLMService, actionStore: ActionStore) {
        self.llm = llm
        self.actionStore = actionStore
        self.windows = PopBarWindowManager(llm: llm)
        self.ocr = ScreenOCRController(windows: windows, actionStore: actionStore)
        resolver = SelectionResolver(strategies: [
            AccessibilityStrategy(),   // fast, side-effect-free; preferred
            CopyOnSelectStrategy(),    // terminals (OTTY) that copy-on-select; reads the clipboard directly
            ClipboardCopyStrategy(),   // fallback for browsers / Electron / custom views
        ])
        monitor = GlobalInputMonitor(gestures: [
            DragSelectGesture(),
            DoubleClickGesture(),
        ])
        // Mtool: the three-scene router owns the clipboard and search panels. It is
        // created before any closure that captures `self`, so every stored property
        // is initialized first.
        let router = ContextRouter(llm: llm, actionStore: actionStore, store: ClipboardStore.shared)
        self.router = router

        windows.onPause = { [weak self] in self?.onPauseRequested?() }
        windows.onOpenSettings = { [weak self] in self?.onSettingsRequested?() }
        monitor.onTrigger = { [weak self] in self?.handleTrigger() }
        monitor.onDismiss = { [weak self] event in self?.handleDismiss(event) }

        router.isSelectionVisible = { [weak self] in self?.windows.transientIsShowingActions ?? false }
        router.onResolveRequested = { [weak self] in self?.routeMainHotKey() }
        router.presentSelection = { [weak self] result, anchor in
            guard let self else { return }
            self.windows.showTransient(
                text: result.text, url: nil,
                source: SelectionSource.capture(element: result.sourceElement, pid: nil, via: result.via),
                element: result.sourceElement, anchor: anchor,
                actions: self.actionStore.actions, origin: nil)
        }
        router.closeSelection = { [weak self] in self?.windows.dismissTransient() }
    }

    /// Whether the global input monitor is on. It runs whenever the popup can
    /// open from a selection OR from the popup hotkey — see `wantsMonitor`.
    var isRunning: Bool { monitor.isRunning }

    /// The monitor is needed while paused too if the popup hotkey is on: it keeps
    /// the clipboard baseline at each mouse-down that the terminal read path
    /// compares against (`CopyOnSelectStrategy`), and it closes a popup the
    /// hotkey opened when the user clicks elsewhere. It only watches — a paused
    /// app still never reads a selection by itself (see `handleTrigger`).
    private var wantsMonitor: Bool {
        PopBarPreferences.popupEnabled || PopBarPreferences.popupHotKeyEnabled
    }

    // MARK: - Lifecycle (call on main)

    /// Start monitoring, unless the Accessibility permission is missing — without
    /// it there is nothing to monitor with — or the user paused the popup.
    ///
    /// A paused app sits in the menu bar doing nothing, so it must never look like
    /// the app doing something: the menu bar icon and the settings sidebar both
    /// say "paused" for as long as it is.
    ///
    /// `prompt: false` skips the system's Accessibility dialog: on a first launch
    /// the onboarding guide explains the permission first and asks from its own
    /// button, and the system shows that dialog only once per app.
    func startIfPermitted(prompt: Bool = true) {
        guard AccessibilityAuthorizer.isTrusted else {
            Self.log.info("not trusted for Accessibility yet — \(prompt ? "asking" : "not asking yet"), starting once granted")
            if prompt { AccessibilityAuthorizer.prompt() }
            return
        }
        start()
    }

    /// Start global monitoring. No-op without the Accessibility permission, and
    /// while paused with no popup hotkey — every start path comes through here, so
    /// this one check is what keeps a pause from being undone by a permission
    /// refresh.
    func start() {
        guard !monitor.isRunning else { return }
        guard wantsMonitor else {
            Self.log.info("paused — not starting")
            return
        }
        guard AccessibilityAuthorizer.isTrusted else {
            Self.log.warn("no Accessibility permission — not starting")
            return
        }
        monitor.start()
        Self.log.info("started\(PopBarPreferences.popupEnabled ? "" : " (paused; watching for the popup hotkey)")")
    }

    /// Close every popup and drop any read in flight, then keep the monitor only
    /// if the popup hotkey still needs it. What a pause does, and what turning
    /// the hotkey off while paused does.
    func stop() {
        resolveTask?.cancel()
        resolveGeneration &+= 1
        windows.closeAll()
        if wantsMonitor {
            Self.log.info("paused — monitor kept for the popup hotkey")
            return
        }
        monitor.stop()
        // OCR is deliberately NOT stopped here: its lifecycle is independent of the
        // selection monitor, so disabling the selection popup must not kill the OCR
        // hotkey. Full OCR teardown happens via `stopScreenOCR()` on tool shutdown.
        Self.log.info("stopped")
    }

    // MARK: - Screenshot OCR (independent front-step)

    /// Register the screenshot-OCR hotkey if the user opted in. Independent of the
    /// selection monitor — it needs Screen Recording (not Accessibility), so it starts
    /// even when the selection popup is off.
    func startOCRIfEnabled() { ocr.startIfEnabled() }

    /// Register the OCR hotkey now. Returns false if the combo is already taken.
    @discardableResult
    func startScreenOCR() -> Bool { ocr.start() }

    /// Unregister the OCR hotkey.
    func stopScreenOCR() { ocr.stop() }

    /// Start a screenshot-OCR capture right now, without the hotkey. The menu bar
    /// uses this: the hotkey is the fast path, but it should not be the ONLY path
    /// — a combo can be taken by another app, and then the feature is unreachable.
    func triggerScreenOCR() { ocr.triggerCapture() }

    /// Persist + re-register the OCR hotkey. Returns false if the new combo is taken
    /// (the previous one is kept registered so the user is never left without one).
    @discardableResult
    func setScreenOCRHotKey(_ combo: KeyCombo) -> Bool { ocr.setHotKey(combo) }

    /// Whether the OCR global hotkey is currently registered (may be false even when
    /// `screenOCREnabled` is true, if the combo was taken at launch).
    var screenOCRIsRegistered: Bool { ocr.isEnabled }

    /// Stop everything, the monitor included (app shutdown).
    func shutdown() {
        resolveTask?.cancel()
        resolveGeneration &+= 1
        monitor.stop()
        windows.closeAll()
        popupHotKey?.invalidate()
        popupHotKey = nil
        mainHotKey?.invalidate()
        mainHotKey = nil
        doubleTap?.stop()
        doubleTap = nil
        router.stopClipboard()
        router.closeAll()
    }

    // MARK: - Popup hotkey (issue #4)

    /// Register the popup hotkey if the user turned it on and recorded one (app
    /// launch). Needs no permission to register; reading the selection when it is
    /// pressed needs Accessibility, like every read.
    func startPopupHotKeyIfEnabled() {
        guard PopBarPreferences.popupHotKeyEnabled else { return }
        _ = registerPopupHotKey()
    }

    /// Whether the popup hotkey is registered right now. False while it is off,
    /// while none is recorded, and when the recorded combo is taken.
    var popupHotKeyIsRegistered: Bool { popupHotKey != nil }

    /// Turn the popup hotkey on or off (already persisted by the caller). Returns
    /// false when turning it on could not register the combo — or there is none
    /// yet, which the settings page shows as "record one" rather than an error.
    @discardableResult
    func setPopupHotKeyEnabled(_ on: Bool) -> Bool {
        let ok: Bool
        if on {
            ok = registerPopupHotKey()
            start()   // the monitor may be needed now (paused + hotkey)
        } else {
            popupHotKey?.invalidate()
            popupHotKey = nil
            ok = true
            // Paused: nothing needs the monitor any more. Open windows stay.
            if !wantsMonitor { monitor.stop() }
        }
        return ok
    }

    /// Persist + re-register a new popup hotkey. Returns false (keeping the
    /// previous combo, registered and persisted) when the new one is taken.
    @discardableResult
    func setPopupHotKey(_ combo: KeyCombo) -> Bool {
        guard PopBarPreferences.popupHotKeyEnabled else {
            PopBarPreferences.popupHotKey = combo
            return true
        }
        let previous = popupHotKey
        previous?.invalidate()
        guard let registered = GlobalHotKey(combo: combo, onPressed: { [weak self] in self?.handlePopupHotKey() }) else {
            Self.log.warn("popup hotkey \(combo.display) is taken — keeping the previous one")
            popupHotKey = nil
            _ = registerPopupHotKey()
            return false
        }
        popupHotKey = registered
        PopBarPreferences.popupHotKey = combo
        Self.log.info("popup hotkey set: \(combo.display)")
        return true
    }

    private func registerPopupHotKey() -> Bool {
        if popupHotKey != nil { return true }
        guard let combo = PopBarPreferences.popupHotKey else {
            Self.log.info("popup hotkey on, but none recorded yet")
            return false
        }
        popupHotKey = GlobalHotKey(combo: combo) { [weak self] in self?.handlePopupHotKey() }
        guard popupHotKey != nil else {
            Self.log.warn("failed to register popup hotkey \(combo.display) — likely taken")
            return false
        }
        Self.log.info("popup hotkey registered: \(combo.display)")
        return true
    }

    private func handlePopupHotKey() {
        guard AccessibilityAuthorizer.isTrusted else {
            Self.log.warn("popup hotkey pressed without the Accessibility permission — nothing can be read")
            return
        }
        handleTrigger(.hotKey)
    }

    // MARK: - Mtool main shortcut (three-scene routing)

    /// Start the clipboard watcher and register the main trigger(s). Called from
    /// `AppState.activate`, independently of the popup pause — clipboard history
    /// and quick search are useful even while the selection popup is paused.
    func startMtoolFeatures() {
        router.startClipboard()
        startMainHotKeyIfEnabled()
        startDoubleCommandIfEnabled()
    }

    /// The main shortcut was pressed: close anything showing, or begin a route.
    func mainHotKeyPressed() {
        router.handleMainHotKey()
    }

    /// Menu-bar entry points for the two panels.
    func showQuickSearchNow() { router.showSearch() }
    func showClipboardNow() { router.showClipboard() }

    /// Whether the main shortcut is registered right now.
    var mainHotKeyIsRegistered: Bool { mainHotKey != nil }

    func startMainHotKeyIfEnabled() {
        guard MtoolPreferences.mainHotKeyEnabled else { return }
        _ = registerMainHotKey()
    }

    @discardableResult
    func setMainHotKeyEnabled(_ on: Bool) -> Bool {
        MtoolPreferences.mainHotKeyEnabled = on
        if on { return registerMainHotKey() }
        mainHotKey?.invalidate()
        mainHotKey = nil
        return true
    }

    /// Record a new main shortcut. Returns false (keeping the previous one) when
    /// the combo is taken by another app or clashes with the OCR shortcut.
    @discardableResult
    func setMainHotKey(_ combo: KeyCombo) -> Bool {
        guard combo != PopBarPreferences.screenOCRHotKey else { return false }
        let previous = mainHotKey
        previous?.invalidate()
        guard let registered = GlobalHotKey(combo: combo, onPressed: { [weak self] in self?.mainHotKeyPressed() }) else {
            Self.log.warn("main shortcut \(combo.display) is taken — keeping the previous one")
            mainHotKey = nil
            _ = registerMainHotKey()
            return false
        }
        mainHotKey = registered
        MtoolPreferences.mainHotKey = combo
        Self.log.info("main shortcut set: \(combo.display)")
        return true
    }

    private func registerMainHotKey() -> Bool {
        if mainHotKey != nil { return true }
        let combo = MtoolPreferences.mainHotKey
        mainHotKey = GlobalHotKey(combo: combo) { [weak self] in self?.mainHotKeyPressed() }
        guard mainHotKey != nil else {
            Self.log.warn("failed to register main shortcut \(combo.display) — likely taken")
            return false
        }
        Self.log.info("main shortcut registered: \(combo.display)")
        return true
    }

    // MARK: - Double Command (optional trigger)

    var doubleCommandAvailable: Bool { doubleTap?.isAvailable ?? false }

    func startDoubleCommandIfEnabled() {
        guard MtoolPreferences.doubleCommandEnabled else { return }
        _ = setDoubleCommandEnabled(true)
    }

    @discardableResult
    func setDoubleCommandEnabled(_ on: Bool) -> Bool {
        MtoolPreferences.doubleCommandEnabled = on
        if on {
            if doubleTap == nil {
                let monitor = ModifierDoubleTapMonitor(threshold: MtoolPreferences.doubleCommandThreshold)
                monitor.onTriggered = { [weak self] in self?.mainHotKeyPressed() }
                doubleTap = monitor
            }
            doubleTap?.setThreshold(MtoolPreferences.doubleCommandThreshold)
            doubleTap?.start()
            return doubleTap?.isAvailable ?? false
        }
        doubleTap?.stop()
        doubleTap = nil
        return true
    }

    func setDoubleCommandThreshold(_ threshold: TimeInterval) {
        MtoolPreferences.doubleCommandThreshold = threshold
        doubleTap?.setThreshold(MtoolPreferences.doubleCommandThreshold)
    }

    /// Resolve the current context and hand it to the router. Always reads the
    /// selection first, so an input control with highlighted text still goes to
    /// scenario 1.
    private func routeMainHotKey() {
        let front = NSWorkspace.shared.frontmostApplication
            ?? NSWorkspace.shared.menuBarOwningApplication
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        let element = AXSelectionProbe.focusedElement()
        let info = FocusedInputInspector.inspect(element)
        let loc = NSEvent.mouseLocation
        let frontID = front?.bundleIdentifier
        let resolvesLinks = actionStore.actions.contains {
            $0.kind == .webPreview || $0.children.contains { $0.kind == .webPreview }
        }
        let context = SelectionContext(
            frontmostApp: front,
            mouseLocation: loc,
            clipboardChangeCountAtGestureStart: monitor.gestureStartClipboardChangeCount,
            resolvesLinks: resolvesLinks,
            allowsSimulatedCopy: PopBarPreferences.simulateCopy,
            isTerminalApp: frontID.map { id in
                PopBarPreferences.terminalApps.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
            } ?? false)
        let generation = router.currentGeneration
        Self.log.debug("main shortcut — front=\(frontID ?? "nil") editable=\(info.looksEditable)")

        resolveTask?.cancel()
        resolveGeneration &+= 1
        let localGeneration = resolveGeneration
        resolveTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.resolver.resolve(context)
            if Task.isCancelled { return }
            await MainActor.run {
                guard localGeneration == self.resolveGeneration else { return }
                let snapshot = ContextSnapshot(
                    frontAppBundleID: frontID,
                    frontAppPID: front?.processIdentifier,
                    selectedText: result?.text,
                    focused: info,
                    timestamp: Date(),
                    generation: generation)
                self.router.route(snapshot: snapshot, result: result, element: element, anchor: loc)
            }
        }
    }

    // MARK: - Trigger → resolve → show

    /// What opened the popup. The two share ONE read path; they differ only in
    /// which of the "do not open here" checks apply. See `docs/popup-hotkey.html`.
    private enum TriggerSource {
        /// A selection gesture (drag, double / triple click): the popup opening by
        /// itself. Stopped by the pause, excluded apps and the ignore rules.
        case gesture
        /// The popup hotkey: pressed on purpose, so none of those apply.
        case hotKey
    }

    private func handleTrigger(_ source: TriggerSource = .gesture) {
        // Paused: the popup does not open by itself, and the selection is not even
        // read — reading can press ⌘C for the user, which a paused app must not do.
        // Checked here, before anything else, and not later when showing.
        if source == .gesture, !(PopBarPreferences.popupEnabled && MtoolPreferences.autoPopupOnSelect) { return }
        // `frontmostApplication` can momentarily return nil; fall back to the
        // menu-bar-owning app so the Electron AX-enable + self-skip still work.
        let front = NSWorkspace.shared.frontmostApplication
            ?? NSWorkspace.shared.menuBarOwningApplication
        // Never read our own UI. (The one exception, the onboarding guide's sample
        // text, does not come through here — see `showForOnboardingSample`.)
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        // Apps the user excluded in Settings: selecting there never opens the popup.
        // Case-insensitive: the list is hand-editable, and bundle IDs are too.
        if source == .gesture, let id = front?.bundleIdentifier,
           PopBarPreferences.excludedApps.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) {
            Self.log.debug("trigger ignored — \(id) is excluded")
            // A read still running for an earlier selection must not land on top
            // of the excluded app, and neither may a popup left from before.
            resolveTask?.cancel()
            resolveGeneration &+= 1
            windows.dismissTransient()
            return
        }
        // Places the popup should stay away from (a browser's address bar, the
        // user's own rules). Read here; matched off the main thread below, since
        // it asks the other app over accessibility.
        let ignoreRules = source == .gesture ? PopBarPreferences.activeIgnoreRules : []
        let frontID = front?.bundleIdentifier

        // A gesture ends where the mouse was released. A hotkey has no gesture, so
        // the popup opens at the pointer — never at the selection: the ring is
        // reached with the mouse, and opening it away from the pointer means a
        // long move across other apps (which can dismiss it), or the pointer
        // already resting on a sub-ring slot and opening that submenu.
        let loc = source == .gesture ? monitor.lastMouseUpLocation : NSEvent.mouseLocation
        // Same spot + the transient already showing its actions → this is a
        // re-trigger for the SAME selection growing (e.g. double-click then triple-
        // click). We re-read so the action uses the LATEST selection (the whole
        // line), but we update the captured text *in place* — no hide/reposition —
        // so the window stays put and doesn't flicker. Pinned windows are never the
        // target of a re-trigger; the transient is.
        let inPlace = source == .gesture
            && windows.transientIsShowingActions
            && hypot(loc.x - lastAnchor.x, loc.y - lastAnchor.y) < sameSelectionRadius

        // Only resolve the associated link when a web-preview action is actually on
        // the wheel — otherwise the strategies attach no material and `LinkResolver`
        // never runs, so the feature costs nothing when it isn't in use.
        let resolvesLinks = actionStore.actions.contains {
            $0.kind == .webPreview || $0.children.contains { $0.kind == .webPreview }
        }
        // AX's global origin is the top-left of the PRIMARY display — the one at Cocoa
        // origin (0,0). `NSScreen.screens.first` is NOT guaranteed to be that screen,
        // so pick the origin-zero one explicitly; its height is the correct flip
        // reference for a cursor on ANY display (including vertically-offset
        // secondaries), since the flip `primaryHeight - cocoaY` is anchored there.
        // Captured on the main thread so `LinkResolver` can flip off-main.
        let flipHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.maxY ?? 0
        let context = SelectionContext(
            frontmostApp: front,
            mouseLocation: loc,
            clipboardChangeCountAtGestureStart: monitor.gestureStartClipboardChangeCount,
            resolvesLinks: resolvesLinks,
            allowsSimulatedCopy: PopBarPreferences.simulateCopy,
            isTerminalApp: frontID.map { id in
                PopBarPreferences.terminalApps.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
            } ?? false)
        Self.log.debug("trigger (\(source == .gesture ? "selection" : "hotkey")) — front=\(front?.bundleIdentifier ?? front?.localizedName ?? "nil") inPlace=\(inPlace) resolvesLinks=\(resolvesLinks)")

        let isHotKey = source == .hotKey
        let origin = HistoryOrigin(trigger: isHotKey ? .hotkey : .selection, app: front)
        resolveTask?.cancel()
        resolveGeneration &+= 1
        let generation = resolveGeneration
        resolveTask = Task { [weak self] in
            guard let self else { return }
            // The element the selection is in: what ignore rules match and what
            // the Inspect action reports.
            let focused = AXSelectionProbe.focusedElement()
            if Task.isCancelled { return }
            if let focused, !ignoreRules.isEmpty,
               let rule = SelectionIgnoreRules.match(focused, bundleID: frontID, rules: ignoreRules) {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard generation == self.resolveGeneration else { return }
                    self.resolveGeneration &+= 1
                    Self.log.debug("trigger ignored — \(rule.name)")
                    // Growing the same selection in place leaves its popup be,
                    // as a failed in-place read does.
                    if !inPlace { self.windows.dismissTransient() }
                }
                return
            }
            let result = await self.resolver.resolve(context)
            if Task.isCancelled { return }
            // Resolve the associated link at trigger time (off-main), only when a
            // web-preview action is on the wheel. The URL is consumed lazily — the
            // preview window only opens if the user taps the web-preview action.
            var url: URL?
            if resolvesLinks, let result, !result.text.isEmpty {
                let probe = LinkProbe(text: result.text, mouseLocation: loc, screenFlipHeight: flipHeight,
                                      focusedElement: result.focusedElement, html: result.htmlData, rtf: result.rtfData,
                                      pointerIsOnSelection: !isHotKey)
                url = LinkResolver.resolve(probe).url
            }
            // Where the text came from, for putting a result back in its place.
            // Read here, off the main thread, like the link: it is one or two AX
            // calls against the app that owns the selection.
            let source = SelectionSource.capture(element: result?.sourceElement, pid: context.pid, via: result?.via)
            if Task.isCancelled { return }
            await MainActor.run {
                // A pause (or shutdown) bumps the generation, so a read that was
                // still running when it happened is dropped here.
                guard generation == self.resolveGeneration else { return }
                guard let result, !result.text.isEmpty else {
                    if !inPlace { self.windows.dismissTransient() }   // don't tear down on an in-place refresh miss
                    return
                }
                if inPlace {
                    // Only refresh the captured text; the window doesn't move, so
                    // its placed anchor stays put. `lastAnchor` still tracks the raw
                    // selection location for the NEXT re-trigger's proximity check.
                    self.lastAnchor = loc
                    self.windows.refreshTransientSelection(text: result.text, url: url, source: source, element: focused,
                                                           origin: origin)
                } else {
                    self.lastAnchor = loc
                    self.windows.showTransient(text: result.text, url: url, source: source, element: focused, anchor: loc,
                                               actions: self.actionStore.actions, origin: origin)
                }
            }
        }
    }

    private func handleDismiss(_ event: InputEvent) {
        // Only the transient (unpinned) window auto-dismisses; pinned windows
        // persist until their own close button.
        guard windows.hasDismissableWindow else { return }
        // A multi-click continuation (e.g. double-click then an accidental triple)
        // shouldn't dismiss — that would hide then immediately reshow (flicker).
        if case let .mouseDown(nsEvent) = event, nsEvent.clickCount >= 2 { return }
        windows.dismissOnOutsideClick()
    }

    // MARK: - Onboarding sample

    /// Show the popup for text selected in the onboarding guide's "Try it" sample.
    ///
    /// This is the single exception to "never read our own UI", and it is narrow
    /// by construction: the global monitor never sees clicks in our own windows,
    /// so nothing here is triggered by a gesture. Only the sample text view calls
    /// this, handing over the text it knows is selected — no selection strategy
    /// runs and no other window of ours can reach it.
    func showForOnboardingSample(text: String, anchor: CGPoint) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        resolveTask?.cancel()
        resolveGeneration &+= 1
        lastAnchor = anchor
        windows.showTransient(text: trimmed, url: nil, anchor: anchor, actions: actionStore.actions)
        Self.log.debug("onboarding sample popup — \(trimmed.count) chars")
    }

    // MARK: - Preview (verification affordance)

    /// Show the popup at screen center with sample text — used by the
    /// `--popbar-preview` launch flag. Lets the UI be seen (and filmed) without
    /// performing a real system-wide selection. The General page has its own
    /// preview drawn in the page (`PopBarStylePreview`) and never calls this.
    func showPreview() {
        let anchor = previewAnchor()
        lastAnchor = anchor
        windows.showTransient(text: L("popbar.preview.sample"), url: nil, anchor: anchor, actions: actionStore.actions)
        // The anchor is worth logging: the preview is meant to land dead centre of
        // one screen, and "which screen" is the only thing that can be surprising.
        Self.log.info("showing preview capsule at \(anchor)")
    }

    /// Anchor the preview popup dead centre of the screen the settings window is
    /// on — the same spot every time, on the display being looked at.
    ///
    /// It used to sit BESIDE the window (right if there was room, else left) so it
    /// never covered the sliders being dragged. Centring gives that up on purpose:
    /// a preview that lands in the same place every time is one that can be
    /// filmed, and the window can always be moved aside while tuning.
    ///
    /// `NSWindow.screen` is the display holding most of the window, and is nil for
    /// a window that is minimised or off screen — hence the fall back to the main
    /// display, which also covers the preview being fired with no window at all.
    private func previewAnchor() -> CGPoint {
        // `NSScreen.main` is the screen with the key window, and this app can
        // easily have no window at all — it is a menu-bar app, and the preview can
        // be fired from a launch flag before anything is on screen. Falling
        // through to `.zero` put the popup in the bottom-left corner of the
        // primary display instead of the middle of anything.
        let window = NSApp.mainWindow ?? NSApp.keyWindow
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = screen?.frame else { return .zero }
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// Push a live auto-expand preference change (from settings) onto every open
    /// window so an already-open result honors it without waiting for the next popup.
    func setAutoExpandHeight(_ on: Bool) {
        windows.setAutoExpandHeight(on)
    }

    /// Push a live result-font-size change (from settings) onto every open window so
    /// an already-open result re-renders at the new size (issue #14).
    func setResultFontSize(_ size: Double) {
        windows.setResultFontSize(size)
    }

    /// Push a live wheel-geometry change (from the settings sliders) onto any popup
    /// that is showing its ring, so it follows the slider in place. Popups shown
    /// later read the geometry at show time anyway.
    func updateShowingWheel() {
        windows.setWheelLayout(PopBarPreferences.ring(PopBarPreferences.style).layout)
    }

    /// The same for the capsule's icon / caption sizes: a showing bar re-fits to
    /// its new button size in place.
    func updateShowingCapsule() {
        windows.setCapsuleSizes(icon: PopBarPreferences.capsuleIconSize,
                                label: PopBarPreferences.capsuleLabelSize)
    }

    /// Dismiss the sample popup — used when the onboarding guide moves on or
    /// closes, so its sample isn't left orphaned over the rest of the app.
    func dismissPreview() {
        windows.dismissTransient()
    }
}
