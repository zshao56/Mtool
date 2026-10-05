import SwiftUI
import AppKit

// The controls for a list of apps kept by bundle id — the popup's excluded apps
// and terminals, the history's unrecorded apps. One copy, so the lists behave
// alike.

/// One app on a list: its icon and name when it is installed, the bare bundle
/// ID when it is not (a hand-edited config, an app since deleted, a default
/// never installed) — still removable either way.
struct AppListRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        let url = appURL(for: bundleID)
        HStack(spacing: 8) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                  ?? NSWorkspace.shared.icon(for: .application))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
                if url != nil {
                    Text(bundleID).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(L("popbar.excluded.remove"), action: remove)
                .buttonStyle(.borderless)
        }
    }
}

/// "Add App…": the running apps not on the list yet, then a file chooser.
struct AddAppMenu: View {
    let skipping: [String]
    let add: (String) -> Void

    init(skipping listed: [String], add: @escaping (String) -> Void) {
        self.skipping = listed
        self.add = add
    }

    var body: some View {
        Menu(L("popbar.excluded.add")) {
            let running = Self.runningApps(excluding: skipping)
            ForEach(running, id: \.bundleID) { app in
                Button {
                    add(app.bundleID)
                } label: {
                    // Menus drop a Label's icon unless the style asks for it.
                    Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                        .labelStyle(.titleAndIcon)
                }
            }
            if !running.isEmpty { Divider() }
            Button(L("popbar.excluded.choose")) { chooseApp() }
        }
        .fixedSize()
    }

    private struct RunningApp {
        let bundleID: String
        let name: String
        let icon: NSImage
    }

    /// Apps with a Dock presence, alphabetised — the ones a person selects text in.
    private static func runningApps(excluding excluded: [String]) -> [RunningApp] {
        var seen = Set(excluded)
        seen.insert(Bundle.main.bundleIdentifier ?? "")
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return RunningApp(bundleID: id, name: app.localizedName ?? id,
                                  icon: Self.menuIcon(app.icon))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func menuIcon(_ image: NSImage?) -> NSImage {
        let icon = (image ?? NSWorkspace.shared.icon(for: .application)).copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// For an app that is not running right now.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
        }
    }
}

/// Where the app with this bundle ID is: the copy Launch Services knows about,
/// or else a running copy. An app run straight from a build folder (a
/// development build, say) is often not registered, so only the running app
/// can say where it is.
func appURL(for bundleID: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
}
