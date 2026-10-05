import SwiftUI
import Combine

/// The root model. Owns the popup's controller and stores, the shared LLM service
/// and the updater, and the sidebar selection.
///
/// Created once at launch in `AppDelegate` — NOT when the settings window opens —
/// because the popup has to work with the window closed. That is the app's whole
/// job; the window is only where you configure it.
///
/// Main-thread only (SwiftUI bindings + `.main` notification observers).
final class AppState: ObservableObject {

    let updateController: UpdateController

    /// The shared LLM service. One instance, backing both the AI Models page and
    /// every action that calls a model.
    let llm: LLMService

    /// The user's configurable actions.
    let actions: ActionStore

    /// App-lifetime popup controller: input monitoring, selection resolution, the
    /// panel itself. Started in `activate()`.
    let controller: PopBarController

    /// The settings-facing view model over `controller` + preferences.
    let store: PopBarStore

    /// Mtool's own keyboard/clipboard settings view model.
    let mtool: MtoolSettingsStore

    @Published var selection: SettingsPage {
        didSet {
            guard oldValue != selection else { return }
            Analytics.trackPageOpened(selection.rawValue)
        }
    }

    /// Bumped on an in-app language change so the SwiftUI tree re-reads every
    /// `NSLocalizedString`. The selection survives the rebuild.
    @Published private(set) var languageRevision = 0

    private var languageObserver: NSObjectProtocol?

    /// Opens the onboarding guide. Set by `MenuBarController`, which owns the
    /// windows; Settings → General calls it.
    var showOnboarding: () -> Void = {}

    init(updateController: UpdateController) {
        self.updateController = updateController
        let llm = LLMService()
        self.llm = llm
        let actions = ActionStore()
        self.actions = actions
        let controller = PopBarController(llm: llm, actionStore: actions)
        self.controller = controller
        self.store = PopBarStore(controller: controller)
        self.mtool = MtoolSettingsStore(controller: controller, store: ClipboardStore.shared)

        // A launch override can pre-select a page (dev/screenshot affordance, inert
        // in normal use), via `open <app> --args --page <id>`.
        let launchPage = Self.launchArgument("--page")
        self.selection = launchPage.flatMap(SettingsPage.init(rawValue:)) ?? .general

        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.languageRevision &+= 1
        }
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    // MARK: - Lifecycle

    /// Start the app-lifetime background work. Called from `applicationDidFinishLaunching`.
    /// `promptForAccessibility: false` on a first launch, where the onboarding
    /// guide asks for the permission itself (see `startIfPermitted`).
    func activate(promptForAccessibility: Bool = true) {
        controller.startIfPermitted(prompt: promptForAccessibility)
        // The screenshot-OCR hotkey has its own lifecycle: it is registered even
        // when the selection popup is switched off, because they are separate
        // features that happen to live in one app.
        controller.startOCRIfEnabled()
        // So does the popup hotkey: it works while paused, which is the point.
        controller.startPopupHotKeyIfEnabled()
        // Clipboard history, quick search and the main three-scene shortcut.
        controller.startMtoolFeatures()
        startHistoryRetention()

        // Dev/screenshot affordance: pop a sample popup shortly after launch, so the
        // capsule or wheel can be looked at without selecting text by hand. Passed
        // as `open <app> --args --popbar-preview`, because `open` does not forward
        // the shell environment.
        if CommandLine.arguments.contains("--popbar-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controller] in
                controller.showPreview()
            }
        }

        // The store was built before any of the above ran, so its snapshot of
        // "is the hotkey registered / is the popup monitoring" is from before the
        // answer existed. Without this the OCR page opens claiming the shortcut is
        // taken by another app, having just registered it successfully.
        store.refreshTrust()
    }

    /// Stop background work cleanly (from `applicationWillTerminate`).
    func shutdown() {
        controller.shutdown()
        controller.stopScreenOCR()   // not torn down by stop() — independent lifecycle
        retentionTimer?.invalidate()
        // A record made in the last moment is still queued: let it land.
        HistoryStore.shared.flush()
    }

    /// Applies the history's retention period now and twice a day, so a Mac
    /// that is never restarted still sheds old records.
    private var retentionTimer: Timer?

    private func startHistoryRetention() {
        HistoryStore.shared.applyRetention()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { _ in
            HistoryStore.shared.applyRetention()
        }
    }

    // MARK: - Launch arguments

    /// The value following a `--flag` in the launch arguments (as passed by
    /// `open … --args --flag <value>`), or nil if absent.
    private static func launchArgument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        return value.hasPrefix("-") ? nil : value
    }
}
