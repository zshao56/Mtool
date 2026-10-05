import Foundation

// The first-run guide's state, and every rule about it that is plain arithmetic:
// which step is done, where the window lands when it opens, and whether it opens
// at launch at all. No UI, no AppKit, no localized strings — so the test bundle
// compiles this file on its own (see `MtoolTests` in project.yml).

/// The guide's pages, in order. The raw values are what is stored, so they are
/// never renamed.
enum OnboardingStep: String, Codable, CaseIterable {
    case welcome
    case accessibility
    case screenRecording
    case ai
    case tryIt

    var next: OnboardingStep {
        let all = Self.allCases
        let i = all.firstIndex(of: self)!
        return all[min(i + 1, all.count - 1)]
    }
}

/// What the guide remembers between launches. It lives in `UserDefaults`, not in
/// the config file: it is where the app is in its own setup, not a setting anyone
/// would want to edit, diff or copy to another Mac.
///
/// Permissions are deliberately NOT stored here. Whether Accessibility or Screen
/// Recording is granted is asked of the system every time — a remembered "yes"
/// would go stale the moment someone flips the switch back off.
struct OnboardingProgress: Codable, Equatable {
    /// The page the guide was last on.
    var step: OnboardingStep = .welcome {
        // Once the user has moved on from the welcome page it is done, like any
        // other step — and stays done if they click back to it.
        didSet { if oldValue == .welcome, step != .welcome { welcomeSeen = true } }
    }
    /// The user has moved past the welcome page at least once.
    var welcomeSeen = false
    /// The user pressed Done on the last page. From then on the guide never opens
    /// by itself again; Settings → General still opens it.
    var completed = false
    /// "Skip" on the Screen Recording page.
    var screenRecordingSkipped = false
    /// "Open System Settings" on the Screen Recording page. With the permission
    /// still missing, this is what makes the page offer to relaunch the app.
    var screenRecordingRequested = false
    /// Screenshot Text was switched on by the guide once the permission arrived —
    /// remembered so it is done once, and a later "off" in Settings is respected.
    var screenOCRTurnedOn = false
    /// "Skip" on the AI page (or Continue without connecting anything).
    var aiSkipped = false
    /// The Test button on the AI page got an answer from the model.
    var aiConnected = false
    /// The popup appeared over the sample text on the last page.
    var tried = false
    /// The window was on screen when the app last quit. Only used to bring the
    /// guide back after macOS's own "Quit & Reopen" for Screen Recording.
    var windowOpen = false

    init() {}

    // Tolerant decoding: a field added in a later version must not throw away
    // everything that was stored before it existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = OnboardingProgress()
        step = (try? c.decodeIfPresent(OnboardingStep.self, forKey: .step)) ?? fresh.step
        // Stored before this flag existed: being on any later page means the
        // welcome page was passed.
        welcomeSeen = (try? c.decodeIfPresent(Bool.self, forKey: .welcomeSeen)) ?? (step != .welcome)
        completed = (try? c.decodeIfPresent(Bool.self, forKey: .completed)) ?? fresh.completed
        screenRecordingSkipped = (try? c.decodeIfPresent(Bool.self, forKey: .screenRecordingSkipped)) ?? false
        screenRecordingRequested = (try? c.decodeIfPresent(Bool.self, forKey: .screenRecordingRequested)) ?? false
        screenOCRTurnedOn = (try? c.decodeIfPresent(Bool.self, forKey: .screenOCRTurnedOn)) ?? false
        aiSkipped = (try? c.decodeIfPresent(Bool.self, forKey: .aiSkipped)) ?? false
        aiConnected = (try? c.decodeIfPresent(Bool.self, forKey: .aiConnected)) ?? false
        tried = (try? c.decodeIfPresent(Bool.self, forKey: .tried)) ?? false
        windowOpen = (try? c.decodeIfPresent(Bool.self, forKey: .windowOpen)) ?? false
    }
}

/// Reads and writes `OnboardingProgress` as one JSON blob in `UserDefaults`.
struct OnboardingProgressStore {

    static let key = "onboarding.progress"
    /// Set just before the guide relaunches the app for Screen Recording.
    static let relaunchArgument = "--onboarding"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Missing or unreadable → a fresh start. Unreadable only happens if someone
    /// edited the defaults by hand; the worst case is seeing the first page again.
    func load() -> OnboardingProgress {
        guard let data = defaults.data(forKey: Self.key),
              let progress = try? JSONDecoder().decode(OnboardingProgress.self, from: data)
        else { return OnboardingProgress() }
        return progress
    }

    func save(_ progress: OnboardingProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// What a step shows in the sidebar.
enum OnboardingStepStatus: Equatable {
    /// Nothing to show (the welcome page, or "try it" not yet tried).
    case none
    case required
    case optional
    case done
    case skipped
    /// Screen Recording switched on in System Settings, but this process cannot see
    /// it until it is relaunched.
    case waitingRelaunch
}

/// Why the guide is opening — decides which page it lands on.
enum OnboardingOpenReason: Equatable {
    /// The very first launch.
    case firstLaunch
    /// Coming back from a relaunch the guide asked for (or macOS's own Quit &
    /// Reopen): pick up exactly where it was.
    case resume
    /// Opened by hand, from Settings or the menu.
    case manual
}

/// The facts the guide reads from the system on every refresh.
struct OnboardingEnvironment: Equatable {
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool
    /// A model is usable: the Test button succeeded, or a key is already saved
    /// for the default provider.
    var aiConfigured: Bool
}

enum OnboardingRules {

    static func status(of step: OnboardingStep, progress: OnboardingProgress,
                       env: OnboardingEnvironment) -> OnboardingStepStatus {
        switch step {
        case .welcome:
            return progress.welcomeSeen || progress.completed ? .done : .none
        case .accessibility:
            return env.accessibilityGranted ? .done : .required
        case .screenRecording:
            // Granted wins over everything: a "skip" earlier does not matter once
            // the permission is actually there.
            if env.screenRecordingGranted { return .done }
            if progress.screenRecordingSkipped { return .skipped }
            if progress.screenRecordingRequested { return .waitingRelaunch }
            return .optional
        case .ai:
            if env.aiConfigured || progress.aiConnected { return .done }
            if progress.aiSkipped { return .skipped }
            return .optional
        case .tryIt:
            return progress.tried ? .done : .none
        }
    }

    /// The page the window shows when it opens.
    ///
    /// Opened by hand: a finished guide starts over from the top (it is being
    /// looked at again); an unfinished one lands on the first required step still
    /// missing — the only thing that matters — or, with nothing required left,
    /// where it was left.
    static func landingStep(for reason: OnboardingOpenReason, progress: OnboardingProgress,
                            accessibilityGranted: Bool) -> OnboardingStep {
        switch reason {
        case .firstLaunch:
            return .welcome
        case .resume:
            return progress.step
        case .manual:
            if progress.completed { return .welcome }
            if !accessibilityGranted { return .accessibility }
            return progress.step
        }
    }

    /// Whether the guide opens by itself at launch, and why.
    ///
    /// - `relaunchRequested`: launched by the guide's own "Relaunch" button.
    /// - `isFirstRun`: never launched before AND the config file had no actions —
    ///   someone upgrading, or bringing a config from another Mac, is not new.
    ///
    /// The one other case is macOS's own "Quit & Reopen" prompt for Screen
    /// Recording, which relaunches the app normally: the guide was open on that
    /// page, waiting for exactly this, so it comes back. Any other quit with the
    /// window open does not bring it back — that would be nagging.
    static func openAtLaunch(isFirstRun: Bool, relaunchRequested: Bool,
                             progress: OnboardingProgress) -> OnboardingOpenReason? {
        if relaunchRequested { return .resume }
        if isFirstRun { return .firstLaunch }
        if progress.windowOpen, !progress.completed,
           progress.step == .screenRecording, progress.screenRecordingRequested {
            return .resume
        }
        return nil
    }
}
