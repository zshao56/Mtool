import SwiftUI

/// The Screenshot Text page: press a hotkey, drag a rectangle over anything on
/// screen, and the text inside it comes back in the same popup as a selection
/// would. It needs Screen Recording rather than Accessibility, and it has its own
/// on/off switch — the two features share a window and nothing else.
struct OCRPage: View {

    @ObservedObject private var store: PopBarStore

    /// Set when registering the hotkey failed because the combo is already taken
    /// by another app, so the field can say so instead of silently not working.
    @State private var hotKeyError = false

    /// Screen Recording is granted in System Settings, in another process, and the
    /// app is never told. Polling is the only way to notice the permission block
    /// should disappear — and it re-reads the hotkey registration at the same time.
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(store: PopBarStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.screenOCREnabled },
                                     set: { hotKeyError = !store.setScreenOCREnabled($0) })) {
                    featureLabel("viewfinder", .teal,
                                 L("popbar.ocr.enable.title"), L("popbar.ocr.enable.subtitle"))
                }

                if store.screenOCREnabled {
                    LabeledContent {
                        HotKeyRecorderField(combo: store.screenOCRHotKey) { combo in
                            hotKeyError = !store.setScreenOCRHotKey(combo)
                        }
                    } label: {
                        iconLabel("command", .teal, L("popbar.ocr.hotkey.label"))
                    }
                    if hotKeyError || !store.screenOCRRegistered {
                        Text(L("popbar.ocr.hotkey.occupied"))
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle(isOn: Binding(get: { store.screenOCRAutoCopy },
                                         set: { store.setScreenOCRAutoCopy($0) })) {
                        iconLabel("doc.on.clipboard", .teal, L("popbar.ocr.autocopy.label"))
                    }

                    if !store.isScreenRecordingAuthorized { permissionBlock }
                }
            } header: {
                Text(L("popbar.ocr.header"))
            } footer: {
                Text(L("popbar.ocr.footer"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("page.ocr"))
        .onAppear { store.refreshTrust() }
        .onReceive(poll) { _ in store.refreshTrust() }
    }

    private var permissionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("popbar.ocr.perm.title")).fontWeight(.medium)
                    Text(L("popbar.ocr.perm.body"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(L("popbar.ocr.perm.grant")) { store.requestScreenRecording() }
                Button(L("popbar.ocr.perm.open")) { store.openScreenRecordingSettings() }
                    .buttonStyle(.borderless)
            }
        }
    }
}
