import SwiftUI

/// The Keyboard page: the main three-scene shortcut, the selection toggle, and
/// the optional modifier-only double-tap trigger.
///
/// The two recording controls are deliberately separate and self-describing. The
/// main shortcut is a Carbon combo (a key plus ⌘/⌥/⌃); the double-tap is a
/// modifier-only gesture whose left/right side matters. Letting one recorder do
/// both was the source of the unreliability this page fixes.
struct KeyboardPage: View {

    @ObservedObject private var store: MtoolSettingsStore
    @State private var hotKeyError = false
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
                            onEndRecording: { store.endHotKeyRecording($0) }
                        ) { combo in
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
                    LabeledContent {
                        HStack(spacing: 10) {
                            // Records whichever side the user actually taps twice.
                            ModifierDoubleTapRecorderField(
                                key: store.doubleCommandKey,
                                threshold: store.doubleCommandThreshold / 1000,
                                onBeginRecording: { store.beginHotKeyRecording() },
                                onEndRecording: { store.endHotKeyRecording($0) }
                            ) { key in
                                store.setDoubleCommandKey(key)
                            }
                            // Explicit choice, including the legacy "either Command"
                            // that a config written before sides existed still uses.
                            Picker("", selection: Binding(get: { store.doubleCommandKey },
                                                          set: { store.setDoubleCommandKey($0) })) {
                                ForEach(ModifierTapKey.allCases) { key in
                                    Text(L(key.localizationKey)).tag(key)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }
                    } label: {
                        iconLabel("command", .indigo, L("mtool.keyboard.doubleCommand.key"))
                    }
                    Text(L("mtool.keyboard.doubleCommand.key.hint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
