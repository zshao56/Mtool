import Foundation

/// Pure state machine behind the optional **double-tap Command** trigger.
///
/// It is fed normalized events (not raw `NSEvent`s) so the gesture can be unit
/// tested without a run loop, a window server or Accessibility permission: the
/// monitor that watches `flagsChanged` translates real events into these and asks
/// the detector whether a double-tap completed.
///
/// A double-tap is Command `down → up → down → up`. Anything that means "the user
/// is doing something else" — another key, another modifier, a change of focus,
/// the system's secure-input mode — resets the machine. The two releases must be
/// within `threshold` seconds.
struct ModifierDoubleTapDetector {

    enum Event: Equatable {
        case commandDown
        case commandUp
        /// Any non-modifier key press (command is no longer "alone").
        case otherKeyDown
        /// Shift / Option / Control changed state while Command was involved.
        case otherModifierChanged
        /// The frontmost application changed mid-gesture.
        case focusChanged
        /// macOS secure keyboard entry is active (e.g. a password prompt).
        case secureInputActive
        /// The configured threshold elapsed with no completion.
        case timeout
    }

    /// Maximum interval, in seconds, between the first and second Command
    /// releases. The plan's default is 350 ms; the settings page makes it
    /// adjustable within `thresholdRange`.
    var threshold: TimeInterval

    static let thresholdRange: ClosedRange<Double> = 0.15...0.60
    static let defaultThreshold: TimeInterval = 0.35

    private enum Phase {
        case idle
        /// Command is held down on the first tap.
        case firstDown
        /// First press released; waiting for the second press.
        case waitingForSecondDown
        /// Second Command press is held; its release completes the gesture.
        case secondDown
    }

    private var phase: Phase = .idle
    private var firstReleaseAt: TimeInterval?

    init(threshold: TimeInterval = ModifierDoubleTapDetector.defaultThreshold) {
        self.threshold = threshold
    }

    mutating func reset() {
        phase = .idle
        firstReleaseAt = nil
    }

    /// Feed one event. Returns `true` exactly on the event that completes a
    /// double-tap; the machine resets itself before returning so a third tap
    /// starts a fresh gesture.
    @discardableResult
    mutating func handle(_ event: Event, at time: TimeInterval) -> Bool {
        switch event {
        case .otherKeyDown, .otherModifierChanged, .focusChanged, .secureInputActive:
            reset()
            return false

        case .timeout:
            reset()
            return false

        case .commandDown:
            switch phase {
            case .idle, .firstDown:
                phase = .firstDown
            case .waitingForSecondDown:
                if let first = firstReleaseAt, time - first <= threshold {
                    phase = .secondDown
                } else {
                    // Too slow — treat this as the first press of a new gesture.
                    phase = .firstDown
                    firstReleaseAt = nil
                }
            case .secondDown:
                // Auto-repeat or a duplicate down with no intervening up.
                break
            }
            return false

        case .commandUp:
            switch phase {
            case .idle:
                return false
            case .firstDown:
                phase = .waitingForSecondDown
                firstReleaseAt = time
                return false
            case .waitingForSecondDown:
                // An up with no second down: nothing to complete.
                return false
            case .secondDown:
                defer { reset() }
                guard let first = firstReleaseAt else { return false }
                return time - first <= threshold
            }
        }
    }
}
