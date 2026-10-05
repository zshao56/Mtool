import AppKit

/// One popup window plus ALL the per-window state that drives it: the captured
/// selection text and the streaming/cancellation generations for the action
/// running inside THIS window. (Issue #13.) The window's on-screen placement is
/// owned by its `PopBarPanel` (the single source of truth for position).
///
/// Before #13 this state lived on `PopBarController` as controller-global fields,
/// so there could only ever be one popup and a new selection cancelled whatever
/// was streaming. By moving it onto a per-window session, multiple windows each
/// own their own panel + in-flight stream: pinning a window "graduates" its
/// session into the pinned set, and a new selection recycles a *fresh* transient
/// session without touching any pinned session's stream.
///
/// Main-thread only by convention (NSEvent monitor callbacks, SwiftUI callbacks,
/// and `activate()` all arrive on main; the resolver `Task` hops back to main
/// before touching a session). The only off-main work is the action `Task`, which
/// hops to `MainActor` before mutating the panel.
final class PopBarSession {

    private static let log = FileLog("PopBar.Session")

    let panel = PopBarPanel()

    private let llm: LLMService

    /// The text the visible capsule is acting on (this window's selection).
    private(set) var text = ""
    /// The link associated with this window's selection, resolved at trigger time by
    /// `LinkResolver` (nil if none / no web-preview action on the wheel). Consumed by
    /// the web-preview action when tapped.
    private(set) var url: URL?
    /// Where this window's selection came from — what a result is put back into
    /// by Replace. nil for the settings preview's sample text.
    private(set) var source: SelectionSource?
    /// The focused element when the selection was made, for the Inspect action.
    /// Unlike `source.element`, captured whatever strategy read the text.
    private(set) var element: AXUIElement?
    private var elementPID: pid_t?

    /// Bumped on every show/recycle of THIS window so a slow AI action can't apply
    /// its result onto a capsule that has since been replaced or dismissed.
    private var panelGeneration = 0
    /// Bumped on every action run within THIS window. A second action tapped on the
    /// SAME visible capsule (so `panelGeneration` is unchanged) must not have the
    /// prior stream's already-enqueued MainActor delta tasks overwrite the new
    /// result — they check this token too and bail.
    private var actionGeneration = 0
    /// The in-flight AI action (streaming) for THIS window. Cancelled when a new
    /// action is tapped in this window or this window is dismissed — never by a new
    /// selection elsewhere, so a pinned window keeps streaming undisturbed.
    private var actionTask: Task<Void, Never>?

    /// How this popup was opened and over which app, for the history. Nil for
    /// the onboarding sample and the preview, which are not recorded.
    private var origin: HistoryOrigin?
    /// The history record of the action whose result is showing, so what
    /// becomes of that result (replaced, copied) can be added to it.
    private var historyTicket: HistoryTicket?

    init(llm: LLMService) {
        self.llm = llm
    }

    var isVisible: Bool { panel.isVisible }
    var isPinned: Bool { panel.isPinned }
    var isShowingActions: Bool { panel.isShowingActions }
    /// The window's actual current on-screen bottom-center (tracks user drags),
    /// used for stacking/overlap decisions.
    var currentBottomCenter: CGPoint { panel.frameBottomCenter }

    // MARK: - Show / recycle (transient window)

    /// Update the captured selection text in place WITHOUT a hide/reposition —
    /// used for an in-place refresh (double→triple-click growing the same
    /// selection). The window doesn't move, so its placement is untouched.
    func refreshSelection(text: String, url: URL?, source: SelectionSource?, element: AXUIElement? = nil,
                          origin: HistoryOrigin? = nil) {
        self.text = text
        self.origin = origin
        self.url = url
        self.source = source
        self.element = element
        self.elementPID = element.flatMap { var pid: pid_t = 0; return AXUIElementGetPid($0, &pid) == .success ? pid : nil }
        panel.model.canReplace = source?.canReplace ?? false
        panel.model.readVia = source?.via
    }

    /// Show (or recycle) this window's capsule in its `.actions` phase, anchored at
    /// `anchor`, acting on `text`. Bumps the panel generation and cancels any prior
    /// in-flight action in THIS window so its stale tokens can't bleed into the new
    /// popup.
    func show(text: String, url: URL?, source: SelectionSource?, element: AXUIElement? = nil, anchor: CGPoint,
              actions: [PopBarActionConfig], origin: HistoryOrigin? = nil) {
        self.text = text
        self.origin = origin
        historyTicket = nil
        self.url = url
        self.source = source
        self.element = element
        self.elementPID = element.flatMap { var pid: pid_t = 0; return AXUIElementGetPid($0, &pid) == .success ? pid : nil }
        panel.model.canReplace = source?.canReplace ?? false
        panel.model.readVia = source?.via
        stopReading()
        panelGeneration &+= 1
        actionTask?.cancel()
        actionTask = nil
        panel.model.actions = actions
        panel.model.comparison = nil
        panel.model.compareView = PopBarPreferences.compareView
        panel.show(at: anchor)
    }

    /// Hide & tear down this window's content. Bumps the panel generation so any
    /// in-flight action result is discarded rather than re-showing a dismissed
    /// popup, and cancels this window's stream.
    func hide() {
        stopReading()
        panelGeneration &+= 1
        actionTask?.cancel()
        actionTask = nil
        panel.hide()
    }

    /// Cancel any in-flight stream and bump generations so nothing can apply onto
    /// this window after it's released. Used when a pinned window closes.
    func teardown() {
        stopReading()
        panelGeneration &+= 1
        actionGeneration &+= 1
        actionTask?.cancel()
        actionTask = nil
    }

    /// Stop this window's read-aloud, if it has one, and drop it from the panel.
    private func stopReading() {
        guard let reading = panel.model.reading else { return }
        SpeechCenter.shared.stop(reading)
        panel.model.reading = nil
    }

    func setAutoExpandHeight(_ on: Bool) {
        panel.setAutoExpandHeight(on)
    }

    func setResultFontSize(_ size: Double) {
        panel.setResultFontSize(size)
    }

    func setWheelLayout(_ layout: WheelLayout) {
        panel.setWheelLayout(layout)
    }

    func setCapsuleSizes(icon: Double, label: Double) {
        panel.setCapsuleSizes(icon: icon, label: label)
    }

    // MARK: - Actions (self-contained per window)

    /// Run a tapped action inside THIS window, streaming into THIS window's panel.
    /// All generation/cancellation is local to the session, so a stream here is
    /// never cancelled by a selection or action in another window.
    func runAction(_ action: PopBarActionConfig) {
        let text = self.text
        let url = self.url
        let generation = panelGeneration
        actionTask?.cancel()   // a tap replaces any prior in-flight action in THIS window
        actionGeneration &+= 1
        let action0 = actionGeneration
        // A run is current only if BOTH the panel hasn't been replaced/dismissed
        // AND no newer action was tapped on this same capsule.
        func isCurrent(_ session: PopBarSession) -> Bool {
            generation == session.panelGeneration && action0 == session.actionGeneration
        }
        panel.model.resultIsFinalOutput = false
        panel.model.notice = nil
        panel.model.comparison = nil
        stopReading()
        historyTicket = nil
        let origin = self.origin
        let startedAt = Date()

        guard action.isAI else {
            // Local actions (copy / web preview) have no loading/result chrome — run
            // and present. Web preview opens the mini-browser window (via `present`).
            // One that produces text for the panel and may take a moment (a
            // Shortcut, a script) shows the panel straight away, with its spinner.
            if action.hasOutput, [.panel, .compare].contains(action.outputMode), action.kind != .transform {
                panel.applyPhase(.result(""))
            }
            actionTask = Task { [weak self] in
                let outcome = await ActionRegistry.run(action, on: text, url: url, service: nil, config: nil)
                let cancelled = Task.isCancelled
                await MainActor.run {
                    // Recorded before the staleness check: a run that finished
                    // after its popup closed still happened.
                    let ticket = HistoryRecorder.record(action, input: text, origin: origin, presentation: outcome,
                                                        partial: nil, cancelled: cancelled, startedAt: startedAt, config: nil)
                    guard let self, isCurrent(self) else { return }
                    self.historyTicket = ticket
                    self.present(outcome, for: action, input: text)
                }
            }
            return
        }

        // AI: show the result chrome IMMEDIATELY (empty → placeholder), then stream
        // tokens into it. No `.loading` blocking state; the window is up at once.
        // Resolve the config (default or per-action override) from the shared service.
        let config = resolveConfig(for: action.modelOverride)
        let service = self.llm
        panel.applyPhase(.result(""))
        let streamed = StreamedText()
        actionTask = Task { [weak self] in
            let outcome = await ActionRegistry.runStreaming(action, on: text, url: url, service: service, config: config) { displayed in
                streamed.text = displayed
                // Every delta hops to main and bails if a newer popup OR a newer
                // action on this same capsule took over, so stale tokens never leak.
                Task { @MainActor [weak self] in
                    guard let self, isCurrent(self) else { return }
                    self.panel.updateResultText(displayed)
                }
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                // Recorded before the staleness check: a stopped stream keeps
                // what had arrived, and a finished one whose popup closed is kept.
                let ticket = HistoryRecorder.record(action, input: text, origin: origin, presentation: outcome,
                                                    partial: streamed.text, cancelled: cancelled,
                                                    startedAt: startedAt, config: config)
                guard let self, isCurrent(self) else { return }
                self.historyTicket = ticket
                // The per-delta `Task { @MainActor }` updates above aren't ordered
                // relative to this final apply, so a straggler could otherwise land
                // AFTER it and revert the text to an earlier partial. Bump the token
                // FIRST: any delta still queued now fails `isCurrent` and is dropped,
                // then apply the canonical final outcome.
                self.actionGeneration &+= 1
                self.present(outcome, for: action, input: text)
            }
        }
    }

    /// Resolve the LLM config for an action's optional override via the shared
    /// service: an override names provider/model/effort (key resolved per-provider);
    /// no override → the app-wide default. nil when the resolved provider has no key
    /// (and isn't Ollama), so the action shows a "set a key" message.
    private func resolveConfig(for override: ModelOverride?) -> LLMConfig? {
        if let o = override {
            return llm.config(forProvider: o.provider, model: o.model, effort: o.reasoningEffort)
        }
        return llm.defaultConfig()
    }

    /// What the session does when an action finishes with `.none` (e.g. Copy) or opens
    /// a web preview. Reported to the owner (the manager) so a transient window
    /// auto-closes while a pinned window's close is driven only by its own close button.
    var onDismissOutcome: (() -> Void)?
    /// Open the resolved link in the shared mini-browser. Wired by the manager.
    var onWebPreview: ((URL) -> Void)?
    /// Open the resolved local file in the shared Quick Look window. Wired by the
    /// manager (which owns that window); Finder needs no such hand-off, since it
    /// isn't a window we own.
    var onQuickLook: ((URL) -> Void)?
    /// Pause the popup (the Pause action). Wired by the manager up to the store,
    /// which owns the paused state the menu bar and the sidebar show.
    var onPause: (() -> Void)?
    /// Open the settings window (the Settings action). Wired by the manager up
    /// to the menu bar controller, which owns that window.
    var onOpenSettings: (() -> Void)?

    /// Route a presentation to its surface — the single place output types map to UI.
    /// Adding a new `PopBarPresentation` case means adding one branch here.
    /// `input` is the text the action ran on — the selection when it was tapped,
    /// which a comparison is made against even if the selection has grown since.
    private func present(_ presentation: PopBarPresentation, for action: PopBarActionConfig, input: String) {
        switch presentation {
        case .none:
            onDismissOutcome?()
        case .result(let output), .error(let output):
            panel.model.resultIsFinalOutput = false
            panel.applyPhase(.result(output))
        case .output(let output):
            deliver(output, as: action.outputMode, input: input)
        case .openExternal(let url):
            // Dismiss first, as for Finder: the other app comes forward.
            if !isPinned { onDismissOutcome?() }
            NSWorkspace.shared.open(url)
        case .speak(let text):
            // The reading window takes the result panel's place; closing it
            // (or anything else replacing it) stops the read.
            let reader = SpeechSettingsStore.shared.resolve(action.reader)
            panel.model.reading = SpeechCenter.shared.read(text, with: reader)
            panel.applyPhase(.result(""))
        case .inspect:
            // Dozens of calls into the other app: off the main thread, so a slow
            // or hung app cannot freeze ours.
            panel.model.resultIsFinalOutput = false
            panel.applyPhase(.result(""))
            let element = self.element ?? source?.element
            let pid = elementPID ?? source?.pid
            let rules = PopBarPreferences.activeIgnoreRules
            let panelGen = panelGeneration, actionGen = actionGeneration
            Task.detached { [weak self] in
                let report = AXInspector.report(element: element, pid: pid, rules: rules)
                await MainActor.run {
                    guard let self, panelGen == self.panelGeneration, actionGen == self.actionGeneration else { return }
                    self.panel.applyPhase(.result(report))
                }
            }
        case .pause:
            // Pausing closes every popup window, this one included, so there is
            // nothing to dismiss here first.
            onPause?()
        case .openSettings:
            // Attention moves to the settings window: close a transient popup,
            // leave a pinned one where it is.
            onOpenSettings?()
            if !isPinned { onDismissOutcome?() }
        case .webPreview(let url):
            // Open the mini-browser, then dismiss this popup (the user's attention
            // moves to the preview window, same one-shot feel as Copy) — but NEVER a
            // pinned window: only transients auto-dismiss, so a pinned popup keeps its
            // content when its web-preview action is used.
            onWebPreview?(url)
            if !isPinned { onDismissOutcome?() }
        case .quickLook(let url):
            // Same one-shot feel as the web preview: attention moves to the preview
            // window, so a transient popup steps aside and a pinned one stays put.
            onQuickLook?(url)
            if !isPinned { onDismissOutcome?() }
        case .revealInFinder(let url, let isDirectory):
            // Dismiss FIRST, then hand off to Finder: ordering our panel out after
            // Finder came forward can pull the focus straight back to us.
            if !isPinned { onDismissOutcome?() }
            revealInFinder(url, isDirectory: isDirectory)
        }
    }

    /// Show a path in Finder — a folder opens in place, a file is revealed and
    /// selected in its parent — and make sure Finder actually comes to the FRONT.
    ///
    /// Neither `open(_:)` nor `activateFileViewerSelecting(_:)` promises to raise
    /// the app: they only ask Finder to open/scroll to a window. We are an
    /// `LSUIElement` app that has typically just called `NSApp.activate` for the
    /// popup, so without the explicit activation below Finder opens the window
    /// *behind* everything and the action looks like it silently did nothing.
    private func revealInFinder(_ url: URL, isDirectory: Bool) {
        // Raising Finder is done by NSWorkspace, NOT by `NSRunningApplication
        // .activate()`. That call is REFUSED here — it returns false and Finder
        // opens behind whatever is in front. Measured, not guessed: the identical
        // call in a stripped-down test app returns true and raises Finder when the
        // process is `.accessory`, and returns false when it is `.regular`. This app
        // is `.accessory`, so the direct call would likely be allowed here — but the
        // route below does not depend on the activation policy at all, and it is the
        // one that has been proven in the field, so it stays.
        //
        // `open(_:configuration:)` with `activates` goes through the system
        // instead of asking for the front slot ourselves, so the policy does not
        // gate it. The folder to show is the item itself, or the file's parent.
        let folder = isDirectory ? url : url.deletingLastPathComponent()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(folder, configuration: config) { [weak self] app, error in
            guard let self else { return }
            if let error {
                Self.log.error("reveal: opening the folder failed — \(error.localizedDescription)")
                return
            }
            Self.log.info("reveal: Finder up (\(app?.bundleIdentifier ?? "nil")), isDirectory=\(isDirectory)")
            // Select the file only once Finder is frontmost, so the selection
            // lands in the window that was just brought forward.
            guard !isDirectory else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Send produced text where the action's `output` says.
    private func deliver(_ output: String, as mode: ActionOutput, input: String) {
        switch mode {
        case .panel:
            panel.model.resultIsFinalOutput = true
            panel.applyPhase(.result(output))
        case .compare:
            // The result shows at once, as `.panel` would; the comparison takes
            // its place when ready. Off the main thread: two long, unrelated texts
            // take a noticeable moment to compare. Replace is offered only once
            // the comparison is in, so it is never offered for a result that
            // turns out to change nothing.
            panel.applyPhase(.result(output))
            let panelGen = panelGeneration, actionGen = actionGeneration
            Task.detached { [weak self] in
                let comparison = TextDiff.compare(input, output)
                await MainActor.run {
                    guard let self, panelGen == self.panelGeneration, actionGen == self.actionGeneration else { return }
                    self.panel.model.comparison = comparison
                    self.panel.model.resultIsFinalOutput = true
                    if comparison.isUnchanged {
                        self.panel.model.notice = L("popbar.compare.unchanged")
                        // The notice sits above the text and adds to the window's
                        // height: re-fit, as showing a result does.
                        self.panel.applyPhase(.result(output))
                    }
                }
            }
        case .copy:
            copyResult(output)
            if isPinned { panel.applyPhase(.result(output)) } else { onDismissOutcome?() }
        case .replace, .append:
            guard let source, source.canReplace else {
                // Nowhere to put it: show it, copied, and say why.
                copyResult(output)
                markDelivered(.failed)
                panel.applyPhase(.result(output))
                panel.model.notice = L("popbar.replace.unavailable")
                return
            }
            write(output, mode: mode == .append ? .append : .replace, source: source)
        }
    }

    /// The Replace button on a result.
    func replaceResult(_ output: String) {
        guard let source, source.canReplace else { return }
        write(output, mode: .replace, source: source)
    }

    private func write(_ output: String, mode: ReplaceWriter.Mode, source: SelectionSource) {
        let result = ReplaceWriter.write(output, mode: mode, original: text, source: source)
        switch result {
        case .replaced: markDelivered(.replaced)
        case .pasted: markDelivered(.pasted)
        case .contextLost: markDelivered(.failed)
        }
        switch result {
        case .replaced, .pasted:
            // Done: a transient popup steps aside. A pinned one keeps showing the
            // result — and must be told it is final, or a streamed answer would
            // stay in its streaming state.
            if isPinned { panel.applyPhase(.result(output)) } else { onDismissOutcome?() }
        case .contextLost:
            // The place is gone for good (the source is fixed at trigger time),
            // so the button would only fail again.
            panel.model.resultIsFinalOutput = false
            panel.applyPhase(.result(output))
            panel.model.notice = L("popbar.replace.lost")
        }
    }

    /// Add what became of the showing result to its history record.
    private func markDelivered(_ delivered: HistoryRecord.Delivered) {
        guard let historyTicket else { return }
        HistoryStore.shared.setDelivered(delivered, ticket: historyTicket)
    }

    /// Copy this window's current result to the pasteboard (the chrome copy button).
    func copyResult(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        markDelivered(.copied)
    }
}

/// The text a stream has shown so far, kept for the history in case the stream
/// is stopped. Written and read on the task that runs the stream.
private final class StreamedText: @unchecked Sendable {
    var text: String?
}
