import Foundation

/// Analytics facade — intentionally INERT in Mtool.
///
/// The upstream QDuo build sent anonymous usage events through Aptabase. Mtool
/// ships with no telemetry and no third-party analytics SDK: every call site
/// keeps calling `Analytics` (so the seam is one file), but every method is a
/// no-op and nothing ever leaves the machine. The `general.analytics` setting is
/// retained so a config file brought from QDuo still parses, and is ignored.
enum Analytics {

    private static let log = FileLog("Analytics")

    static func start(launchProps: [String: String] = [:]) {
        log.info("analytics disabled in Mtool — no telemetry is sent")
    }

    static func flush() {}

    static func trackPageOpened(_ pageID: String) {}

    static func trackPreferenceChanged(key: String, value: String) {}

    /// Where an added action came from. Kept so call sites compile unchanged.
    enum ActionSource: String {
        case template
        case custom
        case changed
    }

    static func trackActionAdded(kind: String, from source: ActionSource) {}
}
