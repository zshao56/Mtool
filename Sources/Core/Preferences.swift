import Foundation
import AppKit

/// App-global preferences (language, analytics opt-out, version tracking).
///
/// Each tool owns its OWN persistence inside its folder (e.g. the Launch
/// Manager persists Guardian rules via `GuardianRuleStore`). This keeps tools
/// isolated — `Preferences` only holds things that are genuinely app-wide.
enum Preferences {

    private static let log = FileLog("Preferences")

    enum Key {
        /// Still a UserDefaults key: it is bookkeeping about the INSTALL (did this
        /// build already report itself?), not a setting anyone would want to edit
        /// or carry to another machine, so it does not belong in the config file.
        static let lastSeenVersion  = "lastSeenVersion"

        /// Read once by the config seeder, to carry an existing choice over.
        static let languageOverride = "languageOverride"
        static let analyticsEnabled = "analyticsEnabled"
    }

    /// Paths into the config file.
    private enum P {
        static let language  = "general.language"
        static let analytics = "general.analytics"
    }

    private static var config: ConfigStore { .shared }

    // MARK: - Language

    /// Read the saved override and install it. Call before any localized string
    /// is read (first thing in `applicationDidFinishLaunching`).
    static func applyLanguageOverride() {
        LocalizationOverride.apply(code: languageOverride)
    }

    /// The chosen language, or nil for "follow the system".
    static var languageOverride: String? {
        let saved = config.optionalString(P.language) ?? ""
        return saved.isEmpty ? nil : saved
    }

    /// Persist + apply a new language override (nil = follow system), then post
    /// `.appLanguageChanged` so live surfaces rebuild without a relaunch.
    static func setLanguageOverride(_ code: String?) {
        if let code, !code.isEmpty {
            config.set(P.language, code)
        } else {
            // Explicitly null rather than absent: "follow the system" is a choice,
            // and the file should show that it was made.
            config.setNull(P.language)
        }
        LocalizationOverride.apply(code: code)
        Analytics.trackPreferenceChanged(key: "language", value: code ?? "system")
        NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
    }

    // MARK: - Analytics opt-out

    /// Default true when the key is absent (fresh installs opt in).
    static var analyticsEnabled: Bool {
        config.bool(P.analytics, default: true)
    }

    /// Persist the analytics opt-out. Fires the meta-event BEFORE persisting
    /// (it bypasses the opt-out gate) so both directions of the toggle reach the
    /// server, then flushes when turning OFF so the OFF event escapes before the
    /// gate closes.
    static func setAnalyticsEnabled(_ on: Bool) {
        let previous = analyticsEnabled
        if previous != on {
            Analytics.trackPreferenceChanged(key: "analytics_enabled", value: String(on))
        }
        config.set(P.analytics, on)
        if !on { Analytics.flush() }
    }
}
