import Foundation
import Carbon.HIToolbox

/// Mtool's own app-level settings — the main shortcut, the optional
/// double-Command trigger, and the auto-popup switch. Kept separate from the
/// upstream `PopBarPreferences` so the three-scenario behaviour has one home.
enum MtoolPreferences {

    private enum P {
        static let mainHotKey          = "main.hotKey"
        static let mainHotKeyEnabled   = "main.hotKeyEnabled"
        static let doubleCommand       = "main.doubleCommandEnabled"
        static let doubleCommandMs     = "main.doubleCommandThresholdMs"
        static let autoPopupOnSelect   = "main.autoPopupOnSelect"
        static let autoPopupDelayMs    = "main.autoPopupDelayMs"
        static let askPrompt           = "search.askPrompt"
    }

    private static var config: ConfigStore { .shared }

    // MARK: - Main shortcut

    /// Whether the main three-scenario shortcut is registered. Default ON.
    static var mainHotKeyEnabled: Bool {
        get { config.bool(P.mainHotKeyEnabled, default: true) }
        set { config.set(P.mainHotKeyEnabled, newValue) }
    }

    /// The recommended first-run shortcut, ⌥Space. There is a default here
    /// (unlike the upstream popup hotkey) because this is the app's one main
    /// gesture; the settings page still lets it be changed or cleared.
    static var defaultMainHotKey: KeyCombo {
        KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
    }

    /// The main shortcut, written as spoken (`"opt+space"`). Unparseable or
    /// missing falls back to the default rather than leaving the app unreachable.
    static var mainHotKey: KeyCombo {
        get { KeyCombo(configString: config.string(P.mainHotKey, default: "")) ?? defaultMainHotKey }
        set { config.set(P.mainHotKey, newValue.configString) }
    }

    // MARK: - Double Command

    /// Whether the optional double-tap-Command trigger is on. Default OFF.
    static var doubleCommandEnabled: Bool {
        get { config.bool(P.doubleCommand, default: false) }
        set { config.set(P.doubleCommand, newValue) }
    }

    /// Threshold between the two Command releases, in milliseconds. Clamped to
    /// the detector's allowed range.
    static var doubleCommandThreshold: TimeInterval {
        get {
            let ms = config.double(P.doubleCommandMs, default: 350)
            let seconds = ms / 1000
            return min(max(seconds, ModifierDoubleTapDetector.thresholdRange.lowerBound),
                       ModifierDoubleTapDetector.thresholdRange.upperBound)
        }
        set {
            let ms = min(max(newValue * 1000, ModifierDoubleTapDetector.thresholdRange.lowerBound * 1000),
                         ModifierDoubleTapDetector.thresholdRange.upperBound * 1000)
            config.set(P.doubleCommandMs, ms)
        }
    }

    // MARK: - Auto popup on selection

    /// Whether selecting text opens the action bar by itself. Default OFF, so
    /// reading is not interrupted; the main shortcut is the primary gesture.
    static var autoPopupOnSelect: Bool {
        get { config.bool(P.autoPopupOnSelect, default: false) }
        set { config.set(P.autoPopupOnSelect, newValue) }
    }

    /// How long after a selection gesture to wait before the automatic popup,
    /// so a double/triple click resolves to the final selection first.
    static var autoPopupDelay: TimeInterval {
        get { config.double(P.autoPopupDelayMs, default: 300) / 1000 }
        set { config.set(P.autoPopupDelayMs, newValue * 1000) }
    }

    static let defaultAskPrompt = "You are a helpful, concise assistant. Answer the user's request directly."

    static var askPrompt: String {
        get { config.string(P.askPrompt, default: defaultAskPrompt) }
        set { config.set(P.askPrompt, newValue) }
    }
}
