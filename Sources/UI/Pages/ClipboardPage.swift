import SwiftUI

/// The Clipboard page: the local history, the user's snippets, the exclusion
/// list and the retention/capacity settings. All of it stays on this Mac.
struct ClipboardPage: View {

    @ObservedObject private var store: MtoolSettingsStore
    @State private var newExcludedApp = ""

    init(store: MtoolSettingsStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.clipboardEnabled },
                                     set: { store.setClipboardEnabled($0) })) {
                    featureLabel("doc.on.clipboard", .green,
                                 L("mtool.clipboard.enable.title"), L("mtool.clipboard.enable.subtitle"))
                }
                if store.clipboardEnabled {
                    Toggle(isOn: Binding(get: { store.clipboardPaused },
                                         set: { store.setClipboardPaused($0) })) {
                        iconLabel("pause.circle", .green, L("mtool.clipboard.pause.title"))
                    }
                    Toggle(isOn: Binding(get: { store.plainTextPaste },
                                         set: { store.setPlainTextPaste($0) })) {
                        iconLabel("textformat", .green, L("mtool.clipboard.plainText.title"))
                    }
                }
            } header: {
                Text(L("mtool.clipboard.header"))
            } footer: {
                Text(L("mtool.clipboard.privacy"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.clipboardEnabled {
                Section {
                    LabeledContent {
                        HStack {
                            Slider(value: Binding(get: { store.maxItems },
                                                  set: { store.setMaxItems($0) }),
                                   in: 10...5000, step: 10)
                            Text("\(Int(store.maxItems))")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 50, alignment: .trailing)
                        }
                    } label: {
                        iconLabel("tray.full", .green, L("mtool.clipboard.maxItems"))
                    }
                    LabeledContent {
                        HStack {
                            Slider(value: Binding(get: { store.retentionDays },
                                                  set: { store.setRetentionDays($0) }),
                                   in: 0...365, step: 1)
                            Text("\(Int(store.retentionDays))d")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 50, alignment: .trailing)
                        }
                    } label: {
                        iconLabel("calendar", .green, L("mtool.clipboard.retention"))
                    }
                    LabeledContent {
                        HStack {
                            Slider(value: Binding(get: { store.maxImageMB },
                                                  set: { store.setMaxImageMB($0) }),
                                   in: 1...100, step: 1)
                            Text("\(Int(store.maxImageMB)) MB")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 56, alignment: .trailing)
                        }
                    } label: {
                        iconLabel("photo", .green, L("mtool.clipboard.maxImage"))
                    }
                    Text(L("mtool.clipboard.retention.hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text(L("mtool.clipboard.limits.header"))
                }

                Section {
                    ForEach(store.excludedApps, id: \.self) { app in
                        HStack {
                            Text(app).font(.system(size: 11, design: .monospaced))
                            Spacer()
                            Button {
                                store.includeApp(app)
                            } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField(L("mtool.clipboard.exclude.placeholder"), text: $newExcludedApp)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addExcluded() }
                        Button(L("mtool.clipboard.exclude.add")) { addExcluded() }
                            .disabled(newExcludedApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text(L("mtool.clipboard.exclude.header"))
                } footer: {
                    Text(L("mtool.clipboard.exclude.footer"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    HStack {
                        Text(String(format: L("mtool.clipboard.count.format"), store.clipboardCount))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("mtool.clipboard.reveal")) { store.revealStorage() }
                            .buttonStyle(.borderless)
                        Button(L("mtool.clipboard.clear"), role: .destructive) { store.clearHistory() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("page.clipboard"))
        .onAppear { store.refresh() }
    }

    private func addExcluded() {
        store.excludeApp(newExcludedApp.trimmingCharacters(in: .whitespacesAndNewlines))
        newExcludedApp = ""
    }
}
