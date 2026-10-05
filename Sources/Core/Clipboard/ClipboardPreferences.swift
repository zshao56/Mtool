import Foundation

/// The clipboard feature's settings. The watcher reads them at each poll, so a
/// change takes effect within half a second without a restart.
enum ClipboardPreferences {

    private enum P {
        static let enabled         = "clipboard.enabled"
        static let paused          = "clipboard.paused"
        static let maxItems        = "clipboard.maxItems"
        static let retentionDays   = "clipboard.retentionDays"
        static let maxImageMB      = "clipboard.maxImageMB"
        static let excludedApps    = "clipboard.excludedApps"
        static let plainTextPaste  = "clipboard.plainTextPaste"
    }

    private static var config: ConfigStore { .shared }

    /// Whether the clipboard watcher runs at all. Default ON.
    static var enabled: Bool {
        get { config.bool(P.enabled, default: true) }
        set { config.set(P.enabled, newValue) }
    }

    /// A temporary pause from the panel, separate from the on/off switch.
    static var paused: Bool {
        get { config.bool(P.paused, default: false) }
        set { config.set(P.paused, newValue) }
    }

    /// Whether the watcher should be polling right now.
    static var watching: Bool { enabled && !paused }

    /// The store's capacity/retention/image rules.
    static var policy: ClipboardPolicy {
        get {
            ClipboardPolicy(
                maxItems: Int(config.double(P.maxItems, default: 500)),
                retentionDays: Int(config.double(P.retentionDays, default: 30)),
                maxImageBytes: Int(config.double(P.maxImageMB, default: 20) * 1024 * 1024))
        }
        set {
            config.set(P.maxItems, Double(newValue.clamped.maxItems))
            config.set(P.retentionDays, Double(newValue.clamped.retentionDays))
            config.set(P.maxImageMB, Double(newValue.clamped.maxImageBytes) / 1024 / 1024)
        }
    }

    /// Paste as plain text (strip formatting) when the target takes a paste.
    static var plainTextPaste: Bool {
        get { config.bool(P.plainTextPaste, default: true) }
        set { config.set(P.plainTextPaste, newValue) }
    }

    /// Bundle ids the watcher refuses to record from. The system clipboard
    /// cannot reliably label every password copy, so this is a best-effort
    /// filter plus the explicit warning in Settings — not a guarantee.
    static var excludedApps: [String] {
        get {
            guard config.value(P.excludedApps) != nil else {
                config.set(P.excludedApps, defaultExcludedApps)
                return defaultExcludedApps
            }
            return config.stringArray(P.excludedApps)
        }
        set { config.set(P.excludedApps, newValue) }
    }

    static let defaultExcludedApps = [
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlane",
        "com.enpass.Enpass",
        "org.keepassxc.keepassxc",
        "com.nordpass.NordPass",
    ]

    static func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedApps.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}
