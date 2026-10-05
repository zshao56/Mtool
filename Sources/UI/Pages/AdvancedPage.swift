import SwiftUI
import AppKit

/// The Advanced page: the settings most people never touch — the popup hotkey
/// (off by default), how the selection is read and where it is not (excluded
/// apps, terminals), and the config / log files.
///
/// Everything here is either opt-in or a workaround for one app. Keeping it off
/// the General page keeps that page to what a new user actually decides: the
/// app's own settings and what the popup looks like.
struct AdvancedPage: View {

    @ObservedObject private var store: PopBarStore

    #if DEBUG
    @AppStorage(DebugReadViaBadge.enabledKey) private var showReadViaBadge = true
    #endif
    /// Set when the recorded popup hotkey could not be registered (another app,
    /// or the screenshot-OCR hotkey, has it), so the field can say so.
    @State private var popupHotKeyError = false

    init(store: PopBarStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            popupHotKeySection
            readingSection
            excludedAppsSection
            terminalAppsSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .navigationTitle(L("page.advanced"))
    }

    // MARK: - Popup hotkey (issue #4)

    /// Independent of the pause, on purpose: the pause is about the popup opening
    /// by itself, the hotkey about opening it when asked. Paused + hotkey is the
    /// "only when I press it" mode. See `docs/popup-hotkey.html`.
    private var popupHotKeySection: some View {
        Section {
            Toggle(isOn: Binding(get: { store.popupHotKeyEnabled },
                                 set: { popupHotKeyError = !store.setPopupHotKeyEnabled($0) })) {
                featureLabel("keyboard", .purple,
                             L("popbar.hotkey.enable.title"), L("popbar.hotkey.enable.subtitle"))
            }
            if store.popupHotKeyEnabled {
                LabeledContent {
                    HotKeyRecorderField(combo: store.popupHotKey) { combo in
                        popupHotKeyError = !store.setPopupHotKey(combo)
                    }
                } label: {
                    iconLabel("command", .purple, L("popbar.ocr.hotkey.label"))
                }
                // A rejected combo is reported first: with none recorded yet, the
                // "record one" hint would otherwise hide that the try failed.
                if store.popupHotKey == nil && !popupHotKeyError {
                    Text(L("popbar.hotkey.notSet"))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if popupHotKeyError || !store.popupHotKeyRegistered {
                    Text(L("popbar.ocr.hotkey.occupied"))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(L("popbar.hotkey.header"))
        } footer: {
            Text(String(format: L("popbar.hotkey.footer"), Brand.name))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - How the selection is read

    private var readingSection: some View {
        Section {
            Toggle(isOn: Binding(get: { store.simulateCopy }, set: { store.setSimulateCopy($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    iconLabel("command", .blue, L("popbar.simulateCopy.title"))
                    Text(L("popbar.simulateCopy.body"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: Binding(get: { store.ignoreAddressBars }, set: { store.setIgnoreAddressBars($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    iconLabel("link", .blue, L("popbar.ignoreAddressBars.title"))
                    Text(L("popbar.ignoreAddressBars.body"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(L("popbar.reading.header"))
        }
    }

    // MARK: - Excluded apps

    private var excludedAppsSection: some View {
        Section {
            if store.excludedApps.isEmpty {
                Text(L("popbar.excluded.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.excludedApps, id: \.self) { id in
                AppListRow(bundleID: id) { store.includeApp(id) }
            }
            AddAppMenu(skipping: store.excludedApps) { store.excludeApp($0) }
        } header: {
            Text(L("popbar.excluded.header"))
        } footer: {
            Text(L("popbar.excluded.footer"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Terminals

    private var terminalAppsSection: some View {
        Section {
            // Only the installed ones: the built-in list names terminals most
            // people don't have. The others stay in the config file untouched.
            let installed = store.terminalApps.filter { appURL(for: $0) != nil }
            if installed.isEmpty {
                Text(L("popbar.terminals.empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(installed, id: \.self) { id in
                AppListRow(bundleID: id) { store.removeTerminalApp(id) }
            }
            AddAppMenu(skipping: store.terminalApps) { store.addTerminalApp($0) }
        } header: {
            Text(L("popbar.terminals.header"))
        } footer: {
            Text(L("popbar.terminals.footer"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            // Nothing else in the app mentions that this file exists, and it is
            // the one place every setting actually lives — so it needs a door.
            LabeledContent {
                Button(L("diagnostics.revealConfig")) {
                    NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.shared.fileURL])
                }
            } label: {
                iconLabel("doc.badge.gearshape", .indigo, L("diagnostics.config.title"))
            }
            Text(String(format: L("diagnostics.config.subtitle"), ConfigStore.shared.fileURL.path))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent {
                Button(L("diagnostics.revealLog")) {
                    NSWorkspace.shared.activateFileViewerSelecting([FileLog.url])
                }
            } label: {
                iconLabel("doc.text", Color(nsColor: .systemGray), L("diagnostics.log.title"))
            }
            Text(String(format: L("diagnostics.log.subtitle"), Brand.name, FileLog.url.path))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            #if DEBUG
            // Debug builds only: the AX / Clipboard / ⌘C label under the popup.
            Toggle(isOn: $showReadViaBadge) {
                iconLabel("tag", .orange, L("diagnostics.readViaBadge"))
            }
            #endif
        } header: {
            Text(L("Diagnostics"))
        }
    }
}
