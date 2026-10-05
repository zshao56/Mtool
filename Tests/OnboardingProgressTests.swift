import XCTest

/// The onboarding guide's promises that are easy to break without noticing: it
/// opens by itself only on a new install (or when it relaunched the app), it
/// remembers where it was, and it never forgets a finished step because a newer
/// version stored one more field.
final class OnboardingProgressTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "mtool.tests.onboarding"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func env(ax: Bool = false, sr: Bool = false, ai: Bool = false) -> OnboardingEnvironment {
        OnboardingEnvironment(accessibilityGranted: ax, screenRecordingGranted: sr, aiConfigured: ai)
    }

    // MARK: - Persistence

    func testProgressRoundTripsThroughUserDefaults() {
        let store = OnboardingProgressStore(defaults: defaults)
        XCTAssertEqual(store.load(), OnboardingProgress(), "nothing stored → a fresh start")

        var p = OnboardingProgress()
        p.step = .screenRecording
        p.screenRecordingRequested = true
        p.aiSkipped = true
        p.windowOpen = true
        store.save(p)

        XCTAssertEqual(OnboardingProgressStore(defaults: defaults).load(), p)
    }

    func testMissingAndUnknownFieldsDoNotLoseWhatWasStored() throws {
        // As an older build would have written it (no `tried`, no `windowOpen`),
        // plus a field from some newer build.
        let json = #"{"step":"ai","completed":false,"aiConnected":true,"fromTheFuture":1}"#
        defaults.set(Data(json.utf8), forKey: OnboardingProgressStore.key)
        let p = OnboardingProgressStore(defaults: defaults).load()
        XCTAssertEqual(p.step, .ai)
        XCTAssertTrue(p.aiConnected)
        XCTAssertFalse(p.tried)
    }

    func testAnUnknownStepFallsBackToTheStartRatherThanDroppingEverything() {
        let json = #"{"step":"somethingNew","completed":true}"#
        defaults.set(Data(json.utf8), forKey: OnboardingProgressStore.key)
        let p = OnboardingProgressStore(defaults: defaults).load()
        XCTAssertEqual(p.step, .welcome)
        XCTAssertTrue(p.completed)
    }

    func testGarbageIsAFreshStart() {
        defaults.set(Data("not json".utf8), forKey: OnboardingProgressStore.key)
        XCTAssertEqual(OnboardingProgressStore(defaults: defaults).load(), OnboardingProgress())
    }

    // MARK: - Step status

    func testAccessibilityIsRequiredUntilGranted() {
        let p = OnboardingProgress()
        XCTAssertEqual(OnboardingRules.status(of: .accessibility, progress: p, env: env()), .required)
        XCTAssertEqual(OnboardingRules.status(of: .accessibility, progress: p, env: env(ax: true)), .done)
    }

    func testScreenRecordingStates() {
        var p = OnboardingProgress()
        XCTAssertEqual(OnboardingRules.status(of: .screenRecording, progress: p, env: env()), .optional)

        p.screenRecordingRequested = true
        XCTAssertEqual(OnboardingRules.status(of: .screenRecording, progress: p, env: env()), .waitingRelaunch,
                       "asked, but this process cannot see the grant yet")

        p.screenRecordingSkipped = true
        XCTAssertEqual(OnboardingRules.status(of: .screenRecording, progress: p, env: env()), .skipped)

        XCTAssertEqual(OnboardingRules.status(of: .screenRecording, progress: p, env: env(sr: true)), .done,
                       "an actual grant beats an earlier skip")
    }

    func testAIStates() {
        var p = OnboardingProgress()
        XCTAssertEqual(OnboardingRules.status(of: .ai, progress: p, env: env()), .optional)
        p.aiSkipped = true
        XCTAssertEqual(OnboardingRules.status(of: .ai, progress: p, env: env()), .skipped)
        XCTAssertEqual(OnboardingRules.status(of: .ai, progress: p, env: env(ai: true)), .done)
        p.aiSkipped = false
        p.aiConnected = true
        XCTAssertEqual(OnboardingRules.status(of: .ai, progress: p, env: env()), .done)
    }

    func testTryItAndWelcome() {
        var p = OnboardingProgress()
        XCTAssertEqual(OnboardingRules.status(of: .welcome, progress: p, env: env()), .none)
        p.step = .accessibility
        p.step = .welcome
        XCTAssertEqual(OnboardingRules.status(of: .welcome, progress: p, env: env()), .done,
                       "passed once, it stays ticked when the user clicks back to it")
        XCTAssertEqual(OnboardingRules.status(of: .tryIt, progress: p, env: env()), .none)
        p.tried = true
        XCTAssertEqual(OnboardingRules.status(of: .tryIt, progress: p, env: env()), .done)
    }

    func testNextWalksInOrderAndStopsAtTheEnd() {
        XCTAssertEqual(OnboardingStep.welcome.next, .accessibility)
        XCTAssertEqual(OnboardingStep.accessibility.next, .screenRecording)
        XCTAssertEqual(OnboardingStep.screenRecording.next, .ai)
        XCTAssertEqual(OnboardingStep.ai.next, .tryIt)
        XCTAssertEqual(OnboardingStep.tryIt.next, .tryIt)
    }

    // MARK: - Landing step

    func testLandingStep() {
        var p = OnboardingProgress()
        p.step = .ai
        XCTAssertEqual(OnboardingRules.landingStep(for: .firstLaunch, progress: p, accessibilityGranted: false), .welcome)
        XCTAssertEqual(OnboardingRules.landingStep(for: .resume, progress: p, accessibilityGranted: false), .ai,
                       "a relaunch comes back exactly where it left")
        XCTAssertEqual(OnboardingRules.landingStep(for: .manual, progress: p, accessibilityGranted: false),
                       .accessibility, "opened by hand: the missing required step first")
        XCTAssertEqual(OnboardingRules.landingStep(for: .manual, progress: p, accessibilityGranted: true), .ai,
                       "nothing required left: where it was")
        p.completed = true
        XCTAssertEqual(OnboardingRules.landingStep(for: .manual, progress: p, accessibilityGranted: true), .welcome,
                       "a finished guide opened again starts from the top")
    }

    // MARK: - Opening at launch

    func testOpensOnlyOnANewInstall() {
        let p = OnboardingProgress()
        XCTAssertEqual(OnboardingRules.openAtLaunch(isFirstRun: true, relaunchRequested: false, progress: p),
                       .firstLaunch)
        XCTAssertNil(OnboardingRules.openAtLaunch(isFirstRun: false, relaunchRequested: false, progress: p),
                     "an existing user never sees it by itself")
    }

    func testClosedMidwayDoesNotComeBackByItself() {
        var p = OnboardingProgress()
        p.step = .accessibility
        p.windowOpen = false
        XCTAssertNil(OnboardingRules.openAtLaunch(isFirstRun: false, relaunchRequested: false, progress: p))
        // Even quitting with the window open does not bring it back — except below.
        p.windowOpen = true
        XCTAssertNil(OnboardingRules.openAtLaunch(isFirstRun: false, relaunchRequested: false, progress: p))
    }

    func testItsOwnRelaunchResumes() {
        var p = OnboardingProgress()
        p.step = .screenRecording
        XCTAssertEqual(OnboardingRules.openAtLaunch(isFirstRun: false, relaunchRequested: true, progress: p), .resume)
    }

    func testMacOSQuitAndReopenForScreenRecordingResumes() {
        var p = OnboardingProgress()
        p.step = .screenRecording
        p.screenRecordingRequested = true
        p.windowOpen = true
        XCTAssertEqual(OnboardingRules.openAtLaunch(isFirstRun: false, relaunchRequested: false, progress: p), .resume)

        p.windowOpen = false   // closed the guide before quitting
        XCTAssertNil(OnboardingRules.openAtLaunch(isFirstRun: false, relaunchRequested: false, progress: p))

        p.windowOpen = true
        p.completed = true     // already finished once
        XCTAssertNil(OnboardingRules.openAtLaunch(isFirstRun: false, relaunchRequested: false, progress: p))
    }
}
