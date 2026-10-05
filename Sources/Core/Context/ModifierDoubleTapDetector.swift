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
    private(set) var commandWasDown = false

    init(threshold: TimeInterval = ModifierDoubleTapDetector.defaultThreshold) {
        self.threshold = threshold
    }

    mutating func reset() {
        phase = .idle
        firstReleaseAt = nil
        commandWasDown = false
    }

    /// Translates modifier transitions (command flag and other modifier flags) into
    /// detector events. Returns true when the second Command release completes the gesture.
    @discardableResult
    mutating func handleFlags(commandDown: Bool, otherModifiers: Bool, at time: TimeInterval) -> Bool {
        defer { commandWasDown = commandDown }
        if otherModifiers {
            handle(.otherModifierChanged, at: time)
            return false
        }
        if commandDown && !commandWasDown {
            return handle(.commandDown, at: time)
        }
        if !commandDown && commandWasDown {
            return handle(.commandUp, at: time)
        }
        return false
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

/// Which physical modifier key the double-tap gesture listens for.
///
/// The old setting (an on/off switch with no key) maps to `anyCommand`, which is
/// also the fallback when a config file predates this key — so an existing user's
/// two-Command behaviour is preserved exactly.
enum ModifierTapKey: String, CaseIterable, Identifiable {
    case anyCommand, leftCommand, rightCommand, leftOption, rightOption

    var id: String { rawValue }

    /// Left/right virtual key codes (`kVK_Command`/`kVK_RightCommand` and the two
    /// Option keys). Named constants because a bare 54/55 everywhere is unreadable.
    static let leftCommandCode: UInt16 = 55
    static let rightCommandCode: UInt16 = 54
    static let leftOptionCode: UInt16 = 58
    static let rightOptionCode: UInt16 = 61

    /// Localization key for the settings page. Kept here instead of a rendered
    /// `title` so this file — which the test bundle compiles without any strings
    /// table — stays free of `NSLocalizedString`.
    var localizationKey: String { "mtool.keyboard.modifier." + rawValue }

    /// The one physical key this gesture listens for. `anyCommand` has none: the
    /// monitor accepts either Command key.
    var physicalCode: UInt16? {
        switch self {
        case .anyCommand:   return nil
        case .leftCommand:  return Self.leftCommandCode
        case .rightCommand: return Self.rightCommandCode
        case .leftOption:   return Self.leftOptionCode
        case .rightOption:  return Self.rightOptionCode
        }
    }

    /// Reverse of `physicalCode` for the four side-specific keys. Used by the
    /// settings recorder to name the gesture the user just performed.
    static func physical(code: UInt16) -> Self? {
        switch code {
        case Self.leftCommandCode:  return .leftCommand
        case Self.rightCommandCode: return .rightCommand
        case Self.leftOptionCode:   return .leftOption
        case Self.rightOptionCode:  return .rightOption
        default:                    return nil
        }
    }
}

/// Side-aware wrapper around the tested down/up machine.
///
/// A `flagsChanged` event names the physical key that moved (`keyCode`) and the
/// resulting state of every modifier family. Distinguishing left from right is
/// only possible through the key code — Carbon's `RegisterEventHotKey` masks
/// cannot express a side, which is why the main combo path stays side-agnostic
/// and only this `NSEvent` path is side-specific.
struct PhysicalModifierDoubleTapDetector {
    let key: ModifierTapKey
    private var detector: ModifierDoubleTapDetector

    init(key: ModifierTapKey, threshold: TimeInterval = ModifierDoubleTapDetector.defaultThreshold) {
        self.key = key
        detector = ModifierDoubleTapDetector(threshold: threshold)
    }

    var threshold: TimeInterval {
        get { detector.threshold }
        set { detector.threshold = newValue }
    }

    mutating func reset() { detector.reset() }

    /// Feed one `flagsChanged` transition. Returns true on the release that
    /// completes the double-tap.
    ///
    /// `otherModifiers` deliberately excludes the target's own family: while
    /// double-tapping Option, Option is the gesture and must not reset it. A
    /// transition of any OTHER physical key resets the candidate, matching the
    /// comment on the original monitor.
    @discardableResult
    mutating func handle(keyCode: UInt16,
                         commandDown: Bool, optionDown: Bool,
                         shiftDown: Bool, controlDown: Bool,
                         at time: TimeInterval) -> Bool {
        let down: Bool
        let otherModifiers: Bool
        switch key {
        case .anyCommand:
            guard keyCode == ModifierTapKey.leftCommandCode || keyCode == ModifierTapKey.rightCommandCode else {
                detector.reset()
                return false
            }
            down = commandDown
            otherModifiers = optionDown || shiftDown || controlDown
        case .leftCommand, .rightCommand, .leftOption, .rightOption:
            guard let expected = key.physicalCode, keyCode == expected else {
                detector.reset()
                return false
            }
            let targetsOption = key == .leftOption || key == .rightOption
            down = targetsOption ? optionDown : commandDown
            otherModifiers = targetsOption
                ? (commandDown || shiftDown || controlDown)
                : (optionDown || shiftDown || controlDown)
        }
        return detector.handleFlags(commandDown: down, otherModifiers: otherModifiers, at: time)
    }
}

/// Side detector for the settings recorder. Feed it the same `flagsChanged`
/// transitions as the runtime monitor and it reports which physical modifier
/// completed a double-tap.
///
/// `anyCommand` is a legacy/picker value, never something a recorded gesture
/// produces, so it is not tracked here. The recorder is pure for the same reason
/// the detector is: the whole side-classification can be unit tested.
struct ModifierDoubleTapRecorder {
    /// The four sides a person can perform. Order matches the settings picker.
    static let recordableKeys: [ModifierTapKey] = [.leftCommand, .rightCommand, .leftOption, .rightOption]

    private var threshold: TimeInterval
    private var detectors: [ModifierTapKey: PhysicalModifierDoubleTapDetector]

    init(threshold: TimeInterval = ModifierDoubleTapDetector.defaultThreshold) {
        self.threshold = threshold
        detectors = [:]
        rebuild()
    }

    /// Restart detection, optionally with a new threshold. Call between
    /// recordings so a half-finished gesture never carries over.
    mutating func reset(threshold: TimeInterval? = nil) {
        if let threshold { self.threshold = threshold }
        rebuild()
    }

    private mutating func rebuild() {
        detectors = Dictionary(uniqueKeysWithValues: Self.recordableKeys.map {
            ($0, PhysicalModifierDoubleTapDetector(key: $0, threshold: threshold))
        })
    }

    /// Returns the key whose double-tap just completed, or nil while the gesture
    /// is still in progress.
    @discardableResult
    mutating func handle(keyCode: UInt16,
                         commandDown: Bool, optionDown: Bool,
                         shiftDown: Bool, controlDown: Bool,
                         at time: TimeInterval) -> ModifierTapKey? {
        for key in Self.recordableKeys {
            let fired = detectors[key]?.handle(keyCode: keyCode,
                                               commandDown: commandDown, optionDown: optionDown,
                                               shiftDown: shiftDown, controlDown: controlDown,
                                               at: time) ?? false
            if fired {
                rebuild()
                return key
            }
        }
        return nil
    }
}
