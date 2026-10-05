import AppKit

/// Update facade — intentionally INERT in Mtool.
///
/// The upstream QDuo build used Sparkle with the author's own EdDSA key and a
/// feed hosted on their repository. Mtool does not ship an auto-updater at all:
/// releases are ordinary DMGs published on the GitHub Releases page, and the
/// user downloads them by hand (see docs/RELEASING.md).
///
/// This type exists only so the launch path (and the About page) compile without
/// the Sparkle dependency. `canCheckForUpdates` is always false and
/// `checkForUpdates` opens the project's Releases page instead, which is the
/// honest behaviour for a build with no updater.
final class UpdateController: NSObject {

    private static let log = FileLog("Update")

    @objc func checkForUpdates(_ sender: Any?) {
        guard let url = Brand.repoURL?.appendingPathComponent("releases") else { return }
        Self.log.info("no auto-updater — opening \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    /// Always false: there is nothing to check against.
    var canCheckForUpdates: Bool { false }
}
