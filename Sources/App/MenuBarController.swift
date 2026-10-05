import Cocoa
import Combine

/// The status-bar item and its menu.
///
/// This app has no Dock icon, so the status item is its ONLY entry point: the menu
/// has to carry everything you cannot otherwise reach, Quit included. A left-click
/// therefore opens the menu directly — there is nowhere else to put it.
final class MenuBarController: NSObject {

    private static let log = FileLog("MenuBar")

    /// The app icon's ring and arc without the tile, drawn by
    /// scripts/make-menubar-icon.py. The catalogue marks it as a template, so the
    /// system tints it for light, dark and highlighted menu bars.
    private static let iconName = "MenuBarIcon"

    private var statusItem: NSStatusItem!
    private let appState: AppState
    private let updateController: UpdateController
    private lazy var mainWindowController = MainWindowController(appState: appState)
    private lazy var onboardingWindowController = OnboardingWindowController(appState: appState)

    private var storeObserver: AnyCancellable?

    private enum Tag: Int { case title = 50, finishSetup = 100, pause = 150, ocr = 200, update = 600 }

    /// The icon as drawn, and the same icon with a pause mark in the ring.
    private var runningImage: NSImage?
    private var pausedImage: NSImage?

    init(appState: AppState, updateController: UpdateController) {
        self.appState = appState
        self.updateController = updateController
        super.init()
        setupStatusItem()
        appState.showOnboarding = { [weak self] in self?.showOnboarding(reason: .manual) }
        // The popup's Settings action. Deferred a turn: it arrives from inside the
        // popup while it is still handling the tap.
        appState.controller.onSettingsRequested = { [weak self] in
            DispatchQueue.main.async { self?.showMainWindow() }
        }
        appState.controller.onActionsSettingsRequested = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.appState.controller.router.closeAll()
                self.appState.selection = .actions
                self.showMainWindow()
            }
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // A missing image would leave an invisible slot — and the status item is
            // the app's only entry point — so fall back to a system symbol.
            let image = NSImage(named: Self.iconName) ?? {
                Self.log.error("\(Self.iconName) missing from the asset catalogue")
                return NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
            }()
            image?.isTemplate = true
            image?.accessibilityDescription = Brand.name
            runningImage = image
            pausedImage = image.map(Self.pausedVariant(of:))
            button.image = image
        }
        // Attached permanently: with no Dock icon there is no second gesture to
        // reserve, so every click should show the menu.
        statusItem.menu = buildMenu()

        // The icon dims when the app cannot work — Accessibility has not been
        // granted — and shows a pause mark while the user has paused the popup.
        // Two different looks, because they need two different fixes.
        storeObserver = appState.store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let paused = !appState.store.popupEnabled
        button.appearsDisabled = !appState.store.isTrusted
        button.image = paused ? pausedImage : runningImage
        button.toolTip = paused ? String(format: L("menu.pausedTooltip.format"), Brand.name) : nil
    }

    /// The ring icon with two short bars in its hole — the pause mark. Drawn at
    /// render time so it stays sharp at every scale and reuses the one icon asset.
    /// Still a template: the system tints it like the plain one.
    private static func pausedVariant(of base: NSImage) -> NSImage {
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            // Centre of the ring in menubar.svg: (512, 512) in a viewBox that
            // starts at (189.3, 199.7) and is 688.5 wide — so 46.9% across and
            // 45.4% down. The hole is about 56% of the width.
            let cx = rect.width * 0.469
            let cy = rect.height * (1 - 0.454)
            let barW = rect.width * 0.09
            let barH = rect.height * 0.30
            let gap = rect.width * 0.08
            NSColor.black.setFill()
            for dx in [-(gap / 2 + barW), gap / 2] {
                let bar = NSRect(x: cx + dx, y: cy - barH / 2, width: barW, height: barH)
                NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        // VoiceOver reads this, not the tooltip — so it has to carry the state.
        image.accessibilityDescription = String(format: L("menu.pausedTooltip.format"), Brand.name)
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "\(Brand.name) v\(Brand.version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        titleItem.tag = Tag.title.rawValue
        menu.addItem(titleItem)

        menu.addItem(.separator())

        // Only while the app cannot work (Accessibility missing): back into the
        // onboarding guide. Hidden otherwise — see `menuWillOpen`.
        let finishItem = NSMenuItem(title: L("menu.finishSetup"),
                                    action: #selector(openOnboarding(_:)), keyEquivalent: "")
        finishItem.target = self
        finishItem.tag = Tag.finishSetup.rawValue
        if #available(macOS 14.4, *) { finishItem.subtitle = L("menu.finishSetup.subtitle") }
        finishItem.isHidden = appState.store.isTrusted
        menu.addItem(finishItem)

        // Title and subtitle are set in `menuWillOpen`, from the current state.
        let pauseItem = NSMenuItem(title: "", action: #selector(togglePaused(_:)), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.tag = Tag.pause.rawValue
        menu.addItem(pauseItem)

        let ocrItem = NSMenuItem(title: L("menu.captureText"),
                                 action: #selector(captureText(_:)), keyEquivalent: "")
        ocrItem.target = self
        ocrItem.tag = Tag.ocr.rawValue
        menu.addItem(ocrItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L("menu.settings"),
                                      action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let searchItem = NSMenuItem(title: L("menu.quickSearch"),
                                    action: #selector(openQuickSearch(_:)), keyEquivalent: "")
        searchItem.target = self
        menu.addItem(searchItem)

        let clipboardItem = NSMenuItem(title: L("menu.clipboardHistory"),
                                       action: #selector(openClipboardHistory(_:)), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)

        menu.addItem(.separator())

        let repoItem = NSMenuItem(title: L("GitHub Repository"),
                                  action: #selector(openRepository(_:)), keyEquivalent: "")
        repoItem.target = self
        menu.addItem(repoItem)

        let feedbackItem = NSMenuItem(title: L("Feedback…"),
                                      action: #selector(openFeedback(_:)), keyEquivalent: "")
        feedbackItem.target = self
        menu.addItem(feedbackItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(format: L("menu.quit.format"), Brand.name),
                                  action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        return menu
    }

    /// Open the settings window (used by the menu and by the first-run path).
    func showMainWindow() {
        mainWindowController.show()
    }

    /// Open the onboarding guide (first launch, relaunch, Settings, the menu).
    func showOnboarding(reason: OnboardingOpenReason) {
        onboardingWindowController.show(reason: reason)
    }

    // MARK: - Actions

    @objc private func openOnboarding(_ sender: NSMenuItem) {
        showOnboarding(reason: .manual)
    }

    @objc private func togglePaused(_ sender: NSMenuItem) {
        appState.store.setPopupEnabled(!appState.store.popupEnabled)
    }

    @objc private func captureText(_ sender: NSMenuItem) {
        appState.controller.triggerScreenOCR()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        showMainWindow()
    }

    @objc private func openQuickSearch(_ sender: NSMenuItem) {
        appState.controller.showQuickSearchNow()
    }

    @objc private func openClipboardHistory(_ sender: NSMenuItem) {
        appState.controller.showClipboardNow()
    }

    @objc private func openRepository(_ sender: NSMenuItem) {
        if let url = Brand.repoURL { NSWorkspace.shared.open(url) }
    }

    @objc private func openFeedback(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(Brand.feedbackURL)
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    /// State is read when the menu opens, not when it was built — otherwise the
    /// checkmark shows whatever was true the last time something rebuilt the menu.
    func menuWillOpen(_ menu: NSMenu) {
        if let item = menu.item(withTag: Tag.ocr.rawValue) {
            // Greyed out rather than hidden: an absent row reads as a missing
            // feature, a greyed one as a switch you have not turned on yet.
            item.isEnabled = appState.store.screenOCREnabled
        }
        appState.store.refreshTrust()
        menu.item(withTag: Tag.finishSetup.rawValue)?.isHidden = appState.store.isTrusted

        let paused = !appState.store.popupEnabled
        let version = "\(Brand.name) v\(Brand.version)"
        menu.item(withTag: Tag.title.rawValue)?.title =
            paused ? String(format: L("menu.titlePaused.format"), version) : version
        if let item = menu.item(withTag: Tag.pause.rawValue) {
            item.title = String(format: L(paused ? "menu.resume.format" : "menu.pause.format"), Brand.name)
            if #available(macOS 14.4, *) { item.subtitle = paused ? L("menu.resume.subtitle") : nil }
        }
    }
}
