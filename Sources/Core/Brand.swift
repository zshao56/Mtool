import Foundation

/// Everything that depends on what the app is CALLED, in one place — and none of
/// it spelled out here. Each value is read back from the built bundle, which gets
/// it from the five brand settings at the top of `project.yml`.
///
/// That is the whole point: renaming the app must not be a search-and-replace
/// across the source. Nothing outside this file may contain the product name, the
/// bundle id, or the repo URL — use these properties instead. The only literals
/// below belong to the AUTHOR rather than to this app, and so survive a rename.
enum Brand {

    // MARK: - Identity

    /// What the app calls itself on screen: window titles, menu items, the About
    /// page. Debug builds come through as "<Name>-Debug", which is deliberate —
    /// while developing, you want to see which one you are looking at.
    static let name: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "App"

    /// This build's bundle id — differs between Debug and Release.
    static let bundleID: String = Bundle.main.bundleIdentifier ?? Self.baseID

    /// The id WITHOUT a configuration suffix, shared by Debug and Release. Anything
    /// that should survive switching between the two — Keychain items, the config
    /// file — hangs off this rather than off `bundleID`, so a debug build reads the
    /// same API keys and the same config as the release build.
    static let baseID: String =
        (Bundle.main.object(forInfoDictionaryKey: "BrandBaseID") as? String) ?? "app"

    /// Lowercase one-word form, taken from the last component of `baseID`. Used
    /// where a filesystem-friendly name is needed (`~/.config/<slug>/`).
    static let slug: String = baseID.split(separator: ".").last.map(String.init) ?? "app"

    // MARK: - Version

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }

    // MARK: - Links

    /// This app's own repository, from the build setting.
    static let repoURL: URL? =
        (Bundle.main.object(forInfoDictionaryKey: "BrandRepoURL") as? String).flatMap(URL.init(string:))

    /// Project links. The fallback literals point at the fork's repository; when
    /// the build setting is present it wins.
    static let projectURL = URL(string: "https://github.com/zshao56/Mtool")!
    static let feedbackURL = URL(string: "https://github.com/zshao56/Mtool/issues/new")!
    static let authorWebsiteURL: URL = repoURL ?? projectURL

    // MARK: - Locations on disk

    /// `~/Library/Logs/<Name>/`. Follows `name`, so a Debug build logs somewhere a
    /// Release build does not — two builds writing one log file is how you end up
    /// reading the wrong app's output and trusting it.
    static var logDirectory: URL {
        home.appendingPathComponent("Library/Logs/\(name)", isDirectory: true)
    }

    /// `~/Library/Application Support/<Name>/` — for things the app owns and the
    /// user is not expected to edit (caches, saved action state).
    static var supportDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(name, isDirectory: true)
    }

    /// `~/Library/Application Support/<baseID>/` — the user's own data that
    /// Debug and Release must both see (the action history). Keyed off `baseID`,
    /// unlike `supportDirectory`, so switching builds does not hide it.
    static var sharedSupportDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(baseID, isDirectory: true)
    }

    /// `~/.config/<slug>/` — the user's config file lives here, on purpose: it is
    /// meant to be opened in an editor, diffed, and symlinked into a dotfiles repo.
    /// Keyed off `baseID`, so Debug and Release read the same one.
    static var configDirectory: URL {
        home.appendingPathComponent(".config/\(slug)", isDirectory: true)
    }

    /// Keychain service for the LLM API keys. Off `baseID`, so the keys survive
    /// switching between Debug and Release.
    static var keychainService: String { "\(baseID).llm" }

    /// Not `FileManager.default.homeDirectoryForCurrentUser`: in a sandboxed
    /// process that answers with the container. This app is not sandboxed, but the
    /// distinction is worth pinning down rather than depending on.
    private static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}
