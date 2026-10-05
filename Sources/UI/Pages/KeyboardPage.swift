import SwiftUI

/// The Keyboard page: the main three-scene shortcut and the optional double-tap
/// Command trigger.
struct KeyboardPage: View {

    @ObservedObject private var store: MtoolSettingsStore
    @State private var hotKeyError = false
    @State private var doubleCommandRecorded = false
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(store: MtoolSettingsStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.mainHotKeyEnabled },
                                     set: { hotKeyError = !store.setMainHotKeyEnabled($0) })) {
                    featureLabel("command", .indigo,
                                 L("mtool.keyboard.main.title"), L("mtool.keyboard.main.subtitle"))
                }
                if store.mainHotKeyEnabled {
                    LabeledContent {
                        HotKeyRecorderField(
                            combo: store.mainHotKey,
                            onBeginRecording: { store.beginHotKeyRecording() },
                            onEndRecording: { store.endHotKeyRecording($0) },
                            onDoubleCommandRecorded: {
                                doubleCommandRecorded = true
                                _ = store.setDoubleCommandEnabled(true)
                            },
                            doubleCommandThreshold: store.doubleCommandThreshold / 1000
                        ) { combo in
                            doubleCommandRecorded = false
                            hotKeyError = !store.setMainHotKey(combo)
                        }
                    } label: {
                        iconLabel("keyboard", .indigo, L("mtool.keyboard.main.label"))
                    }
                    if hotKeyError || !store.mainHotKeyRegistered {
                        Text(L("mtool.keyboard.main.occupied"))
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L("mtool.keyboard.main.hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(L("mtool.keyboard.main.header"))
            }

            Section {
                Toggle(isOn: Binding(get: { store.autoPopupOnSelect },
                                     set: { store.setAutoPopupOnSelect($0) })) {
                    iconLabel("text.cursor", .gray, L("mtool.keyboard.autoPopup.title"))
                }
                Text(L("mtool.keyboard.autoPopup.subtitle"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("mtool.keyboard.autoPopup.header"))
            }

            Section {
                Toggle(isOn: Binding(get: { store.doubleCommandEnabled },
                                     set: { _ = store.setDoubleCommandEnabled($0) })) {
                    featureLabel("command.circle", .indigo,
                                 L("mtool.keyboard.doubleCommand.title"),
                                 L("mtool.keyboard.doubleCommand.subtitle"))
                }
                if store.doubleCommandEnabled {
                    if doubleCommandRecorded {
                        Text(L("mtool.keyboard.doubleCommand.recorded"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent {
                        HStack {
                            Slider(value: Binding(get: { store.doubleCommandThreshold },
                                                  set: { store.setDoubleCommandThreshold($0) }),
                                   in: 150...600, step: 10)
                            Text("\(Int(store.doubleCommandThreshold)) ms")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 56, alignment: .trailing)
                        }
                    } label: {
                        iconLabel("timer", .indigo, L("mtool.keyboard.doubleCommand.threshold"))
                    }
                    if !store.doubleCommandAvailable {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("mtool.keyboard.doubleCommand.unavailable"))
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(L("popbar.ocr.perm.open")) {
                                store.openAccessibilitySettings()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
            } header: {
                Text(L("mtool.keyboard.doubleCommand.header"))
            } footer: {
                Text(L("mtool.keyboard.footer"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("page.keyboard"))
        .onAppear { store.refresh() }
        .onReceive(poll) { _ in store.refresh() }
    }
}
