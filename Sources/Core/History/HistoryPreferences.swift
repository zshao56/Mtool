import Foundation

/// The history's settings, in the config file under `history`.
enum HistoryPreferences {

    private enum P {
        static let enabled       = "history.enabled"
        static let retentionDays = "history.retentionDays"
        static let recordCopy    = "history.recordCopy"
        static let excludedApps  = "history.excludedApps"
    }

    private static var config: ConfigStore { .shared }

    /// Whether runs are recorded at all. Default on.
    static var enabled: Bool {
        get { config.bool(P.enabled, default: true) }
        set { config.set(P.enabled, newValue) }
    }

    /// How many days a record is kept; 0 = forever (the default).
    static var retentionDays: Int {
        get { max(0, Int(config.double(P.retentionDays, default: 0))) }
        set { config.set(P.retentionDays, Double(max(0, newValue))) }
    }

    /// The choices the settings offer; 0 = forever.
    static let retentionChoices = [0, 7, 30, 90, 365]

    /// Whether the Copy action is recorded. Default on.
    static var recordCopy: Bool {
        get { config.bool(P.recordCopy, default: true) }
        set { config.set(P.recordCopy, newValue) }
    }

    /// Apps whose selections are never recorded, by bundle id.
    ///
    /// Not in the file yet → the built-in list is written into it, and from then
    /// on the file is what counts: an app the user removed stays removed.
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

    static func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedApps.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Password managers: what is selected in them is a secret. The Apple ids
    /// are the system's own; the others are the vendors' published bundle ids,
    /// not checked on this machine.
    static let defaultExcludedApps = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]
}

extension HistoryStore {
    /// Delete what is past the retention period in settings (nothing when it is
    /// "forever"). Reads the setting here, on the caller's (main) thread.
    func applyRetention(completion: (() -> Void)? = nil) {
        let days = HistoryPreferences.retentionDays
        guard days > 0 else { completion?(); return }
        deleteOlder(than: Date().addingTimeInterval(-Double(days) * 86_400), completion: completion)
    }
}
