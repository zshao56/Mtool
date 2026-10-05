import SwiftUI

/// The **Speech** settings page (its own sidebar page). Four blocks, one level each: the
/// default reader, the list of readers (a row each; clicking one opens its
/// editor in a sheet, like the Actions page), the provider keys (a row each,
/// edited in a sheet) and the local audio cache.
struct SpeechSettingsView: View {
    @ObservedObject private var store = SpeechSettingsStore.shared
    @State private var preview: SpeechPlayback?
    @State private var cacheBytes: Int64 = 0
    @State private var editing: ReaderTarget?
    @State private var editingKey: KeyTarget?

    /// A provider whose key sheet is open (`SpeechProvider` is not Identifiable).
    struct KeyTarget: Identifiable { let id: String }
    /// A reader whose editor sheet is open, by id: the store holds the live copy.
    struct ReaderTarget: Identifiable { let id: String }

    var body: some View {
        Form {
            defaultSection
            readersSection
            keysSection
            cacheSection
        }
        .formStyle(.grouped)
        .onAppear { cacheBytes = SpeechCache.shared.size() }
        .onDisappear { SpeechCenter.shared.stop(preview) }
        .navigationTitle(L("page.speech"))
        .sheet(item: $editing) { target in
            ReaderEditor(readerID: target.id, store: store, preview: $preview) { editing = nil }
        }
        .sheet(item: $editingKey) { target in
            if let provider = SpeechProviders.find(target.id) {
                KeyEditor(provider: provider, store: store) { editingKey = nil }
            }
        }
    }

    // MARK: - Default reader

    private var defaultSection: some View {
        Section {
            Picker(selection: Binding(get: { store.defaultReaderID }, set: { store.setDefault($0) })) {
                ForEach(store.allReaders) { Text($0.name).tag($0.id) }
            } label: { iconLabel("speaker.wave.2", .teal, L("speech.default")) }
        } footer: {
            Text(L("speech.default.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Readers

    private var readersSection: some View {
        Section {
            ForEach(store.readers) { reader in
                readerRow(reader)
            }
            systemRow
        } header: {
            HStack {
                Text(L("speech.readers.header"))
                Spacer()
                Menu {
                    ForEach(SpeechProviders.all, id: \.id) { provider in
                        Button(String(format: L("speech.add.item"), provider.displayName)) {
                            editing = ReaderTarget(id: store.addReader(provider: provider).id)
                        }
                    }
                } label: { Label(L("speech.add.menu"), systemImage: "plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } footer: {
            Text(L("speech.readers.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readerRow(_ reader: SpeechReader) -> some View {
        let provider = SpeechProviders.find(reader.engine)
        let voice = provider?.voices[reader.model]?.first { $0.id == reader.voice }?.label ?? reader.voice
        return HStack(spacing: 10) {
            IconTile(symbol: provider?.symbol ?? "speaker.wave.2", color: provider?.tint ?? .gray)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(reader.name)
                    if reader.id == store.defaultReaderID { badge(L("speech.reader.default.badge"), .secondary) }
                    if !store.hasKey(for: reader.engine) { badge(L("speech.reader.missingKey"), .orange) }
                }
                Text("\(voice) · \(reader.model) · \(String(format: "%.2f×", reader.effectiveSpeed))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            // VoiceOver: the name is the row's "open the editor" button; the
            // preview button stays reachable on its own.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { editing = ReaderTarget(id: reader.id) }
            Spacer(minLength: 8)
            previewControl(for: reader)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { editing = ReaderTarget(id: reader.id) }
        .accessibilityElement(children: .contain)
    }

    private var systemRow: some View {
        let system = SpeechReader.system()
        return HStack(spacing: 10) {
            IconTile(symbol: "desktopcomputer", color: .gray)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(system.name)
                    if store.defaultReaderID == system.id { badge(L("speech.reader.default.badge"), .secondary) }
                }
                Text(L("speech.reader.system.subtitle")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            previewControl(for: system)
            // Same width as the readers' chevron, so the preview buttons line up.
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).hidden()
        }
    }

    @ViewBuilder
    private func previewControl(for reader: SpeechReader) -> some View {
        if let preview, preview.reader.id == reader.id, preview.isActive {
            PreviewStatus(playback: preview)
        } else {
            Button {
                preview = SpeechCenter.shared.read(L("speech.preview.sample"), with: reader)
            } label: { Label(L("speech.preview"), systemImage: "play.fill") }
            .controlSize(.small)
            .help(L("speech.preview"))
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    // MARK: - Keys

    private var keysSection: some View {
        Section {
            ForEach(SpeechProviders.all, id: \.id) { provider in
                LabeledContent {
                    HStack(spacing: 8) {
                        if store.hasKey(for: provider.id) {
                            Text(L("models.key.saved")).font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                        } else {
                            Text(L("models.key.missing")).font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        Button(store.hasKey(for: provider.id) ? L("speech.key.change") : L("speech.key.set")) {
                            editingKey = KeyTarget(id: provider.id)
                        }
                        .controlSize(.small)
                    }
                } label: { iconLabel(provider.symbol, provider.tint, provider.displayName) }
            }
        } header: {
            Text(L("speech.keys.header"))
        } footer: {
            Text(L("speech.keys.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(String(format: L("speech.cache.usage"),
                                ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file),
                                ByteCountFormatter.string(fromByteCount: SpeechCache.limitBytes, countStyle: .file)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(L("speech.cache.clear")) {
                        SpeechCache.shared.clear()
                        cacheBytes = SpeechCache.shared.size()
                    }
                    .controlSize(.small)
                    .disabled(cacheBytes == 0)
                }
            } label: { iconLabel("internaldrive", .teal, L("speech.cache")) }
        } footer: {
            Text(L("speech.cache.footer")).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One reader's settings, in a sheet. Changes apply as they are made; Done
/// just closes it.
private struct ReaderEditor: View {
    let readerID: String
    @ObservedObject var store: SpeechSettingsStore
    @Binding var preview: SpeechPlayback?
    let close: () -> Void
    @State private var customVoice = false

    private var reader: SpeechReader? { store.readers.first { $0.id == readerID } }

    var body: some View {
        VStack(spacing: 0) {
            Text(L("speech.editor.title")).font(.headline).padding(.top, 16)
            if let reader { form(reader) }
            HStack {
                Button(L("speech.editor.remove"), role: .destructive) {
                    SpeechCenter.shared.stop(preview)
                    store.remove(readerID)
                    close()
                }
                Spacer()
                if let reader {
                    if let preview, preview.reader.id == reader.id, preview.isActive {
                        PreviewStatus(playback: preview)
                    } else {
                        Button {
                            preview = SpeechCenter.shared.read(L("speech.preview.sample"), with: reader)
                        } label: { Label(L("speech.preview"), systemImage: "play.fill") }
                    }
                }
                Button(L("speech.editor.done")) { close() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 480)
        .onDisappear { SpeechCenter.shared.stop(preview) }
    }

    private func form(_ reader: SpeechReader) -> some View {
        let provider = SpeechProviders.find(reader.engine)
        let voices = provider?.voices[reader.model] ?? []
        let speedRange = provider?.speedRange ?? 0.5...2
        let speed = reader.effectiveSpeed
        func set(_ change: (inout SpeechReader) -> Void) {
            var copy = reader
            change(&copy)
            store.update(copy)
        }
        return Form {
            TextField(L("speech.reader.name"), text: Binding(get: { reader.name }, set: { v in set { $0.name = v } }))
            LabeledContent(L("speech.editor.provider"), value: provider?.displayName ?? reader.engine)

            Picker(L("speech.reader.model"), selection: Binding(get: { reader.model }, set: { model in
                set {
                    $0.model = model
                    let list = provider?.voices[model] ?? []
                    if !list.isEmpty, !list.contains(where: { $0.id == reader.voice }) { $0.voice = list[0].id }
                }
            })) {
                ForEach(provider?.models ?? [reader.model], id: \.self) { Text($0).tag($0) }
            }

            Picker(L("speech.reader.voice"), selection: Binding(
                get: { customVoice || !voices.contains { $0.id == reader.voice } ? "__custom" : reader.voice },
                set: { value in
                    if value == "__custom" { customVoice = true } else { customVoice = false; set { $0.voice = value } }
                })) {
                ForEach(voices) { Text($0.label).tag($0.id) }
                Divider()
                Text(L("speech.reader.voice.custom")).tag("__custom")
            }
            if customVoice || !voices.contains(where: { $0.id == reader.voice }) {
                TextField(L("speech.reader.voice.id"), text: Binding(get: { reader.voice }, set: { v in set { $0.voice = v } }))
                    .font(.system(size: 12, design: .monospaced))
            }

            LabeledContent(L("speech.reader.speed")) {
                HStack {
                    Slider(value: Binding(get: { speed }, set: { v in set { $0.speed = (v * 20).rounded() / 20 } }),
                           in: speedRange)
                        .frame(maxWidth: 200)
                    Text(String(format: "%.2f×", speed))
                        .font(.system(size: 11, design: .monospaced)).frame(width: 44, alignment: .trailing)
                }
            }

            if provider?.hasRegions ?? true {
                Picker(L("speech.reader.region"), selection: Binding(get: { reader.region }, set: { v in set { $0.region = v } })) {
                    Text(L("speech.reader.region.cn")).tag("cn")
                    Text(L("speech.reader.region.intl")).tag("intl")
                }
            }
        }
        .formStyle(.grouped)
        // One row is 38 pt: the custom voice id field adds one, a provider
        // without regions has one fewer.
        .frame(height: (customVoice || !voices.contains(where: { $0.id == reader.voice }) ? 300 : 262)
                       - (provider?.hasRegions ?? true ? 0 : 38))
    }
}

/// One provider's API key, in a sheet: status, paste-and-save, clear.
private struct KeyEditor: View {
    let provider: SpeechProvider
    @ObservedObject var store: SpeechSettingsStore
    let close: () -> Void
    @State private var draft = ""
    @State private var error: String?

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        error = store.saveKey(draft, for: provider.id)
        if error == nil { draft = ""; close() }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(String(format: L("speech.key.header"), provider.displayName)).font(.headline).padding(.top, 16)
            Form {
                Section {
                    LabeledContent {
                        if store.hasKey(for: provider.id) {
                            HStack(spacing: 8) {
                                Text(L("models.key.saved")).font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                                Button(L("models.key.clear")) { store.clearKey(for: provider.id) }.controlSize(.small)
                            }
                        } else {
                            Text(L("models.key.missing")).font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    } label: { iconLabel("key", provider.tint, String(format: L("models.keyFor"), provider.displayName)) }
                    HStack {
                        SecureField(L("models.key.placeholder"), text: $draft)
                            .onSubmit(save)
                        Button(L("models.key.save"), action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                } footer: {
                    Text(provider.keyHint).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .frame(height: 230)
            HStack {
                Spacer()
                Button(L("speech.key.done")) { close() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 480)
    }
}

/// What a preview read is doing, next to its button.
private struct PreviewStatus: View {
    @ObservedObject var playback: SpeechPlayback

    var body: some View {
        switch playback.state {
        case .preparing: ProgressView().controlSize(.small)
        case .playing, .paused:
            Button { SpeechCenter.shared.stop(playback) } label: { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .finished, .idle:
            EmptyView()
        }
    }
}
