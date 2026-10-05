import SwiftUI

/// Add/edit sheet for a single configurable action: title, icon, type, prompt,
/// and an optional per-action model override.
struct ActionEditorView: View {

    @State private var draft: PopBarActionConfig
    @ObservedObject private var llm: LLMService
    @ObservedObject private var speech = SpeechSettingsStore.shared
    /// The system translator's languages, loaded when the editor shows a
    /// `systemTranslate` action (the list comes from an async system call).
    @State private var translateTargets: [SystemTranslator.Target] = []
    let onSave: (PopBarActionConfig) -> Void
    let onCancel: () -> Void

    init(action: PopBarActionConfig, llm: LLMService,
         onSave: @escaping (PopBarActionConfig) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: action)
        _llm = ObservedObject(wrappedValue: llm)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("popbar.editor.title"), text: $draft.title)
                    // A group holds actions instead of doing anything itself, so it
                    // has no kind to pick and no prompt to write. The kind is also
                    // not OFFERED as a choice: turning a group back into an action
                    // would orphan whatever is inside it.
                    if draft.kind == .group {
                        Text(L("popbar.editor.group.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                    Picker(L("popbar.editor.kind"), selection: $draft.kind) {
                        Text(L("popbar.editor.kind.ai")).tag(PopBarActionConfig.Kind.ai)
                        Text(L("popbar.editor.kind.copy")).tag(PopBarActionConfig.Kind.copy)
                        Text(L("popbar.editor.kind.webpreview")).tag(PopBarActionConfig.Kind.webPreview)
                        Text(L("popbar.editor.kind.quicklook")).tag(PopBarActionConfig.Kind.quickLook)
                        Text(L("popbar.editor.kind.reveal")).tag(PopBarActionConfig.Kind.revealInFinder)
                        Text(L("popbar.editor.kind.openURL")).tag(PopBarActionConfig.Kind.openURL)
                        Text(L("popbar.editor.kind.speak")).tag(PopBarActionConfig.Kind.speak)
                        Text(L("popbar.editor.kind.transform")).tag(PopBarActionConfig.Kind.transform)
                        Text(L("popbar.editor.kind.shortcut")).tag(PopBarActionConfig.Kind.shortcut)
                        Text(L("popbar.editor.kind.script")).tag(PopBarActionConfig.Kind.script)
                        // Offered on macOS 15+ only — but an action that already
                        // is one keeps its entry, so the picker never shows blank.
                        if SystemTranslator.isAvailable || draft.kind == .systemTranslate {
                            Text(L("popbar.editor.kind.systemTranslate")).tag(PopBarActionConfig.Kind.systemTranslate)
                        }
                        Text(L("popbar.editor.kind.pause")).tag(PopBarActionConfig.Kind.pause)
                        Text(L("popbar.editor.kind.inspect")).tag(PopBarActionConfig.Kind.inspect)
                        Text(L("popbar.editor.kind.settings")).tag(PopBarActionConfig.Kind.settings)
                    }
                    if draft.isPathAction {
                        Text(L("popbar.editor.kind.pathHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    }
                }

                kindSpecificSections

                Section(L("popbar.editor.icon")) { iconGrid }

                if draft.kind == .ai {
                    Section(L("popbar.editor.prompt")) {
                        TextEditor(text: $draft.prompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 90)
                    }
                    Section { modelOverrideControls }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(L("popbar.editor.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("popbar.editor.save")) { onSave(saved) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(12)
        }
        .frame(width: 470, height: 600)
    }

    /// The draft as it will be stored: a transform whose operation was never
    /// touched gets the one its picker was showing.
    private var saved: PopBarActionConfig {
        var action = draft
        if action.kind == .transform, action.op == nil { action.op = TextTransform.uppercase.rawValue }
        return action
    }

    private var isValid: Bool {
        let titleOK = !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
        func filled(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch draft.kind {
        case .ai:        return titleOK && filled(draft.prompt)
        case .openURL:   return titleOK && filled(draft.url)
        // A new transform shows UPPERCASE in its picker before anything is
        // chosen; saving takes that (see `save`), so nil is valid here.
        case .transform: return titleOK && (draft.op == nil || draft.op.flatMap(TextTransform.init(rawValue:)) != nil)
        case .shortcut:  return titleOK && filled(draft.shortcut)
        case .script:    return titleOK && filled(draft.script)
        case .systemTranslate: return titleOK && filled(draft.targetLanguage)
        default:         return titleOK
        }
    }

    // MARK: - Kind-specific fields

    @ViewBuilder
    private var kindSpecificSections: some View {
        switch draft.kind {
        case .openURL:
            Section {
                TextField(L("popbar.editor.url"), text: optionalText(\.url),
                          prompt: Text(verbatim: "https://www.google.com/search?q={text}"))
                    .font(.system(size: 12, design: .monospaced))
                Picker(L("popbar.editor.openIn"), selection: Binding(
                    get: { draft.openTarget },
                    set: { draft.openIn = $0 == .browser ? nil : $0.rawValue })) {
                    Text(L("popbar.editor.openIn.browser")).tag(OpenURLTarget.browser)
                    Text(L("popbar.editor.openIn.preview")).tag(OpenURLTarget.preview)
                }
            } footer: {
                Text(L("popbar.editor.url.hint")).fixedSize(horizontal: false, vertical: true)
            }
        case .speak:
            Section {
                Picker(L("popbar.editor.reader"), selection: Binding(
                    get: { draft.reader ?? "" },
                    set: { draft.reader = $0.isEmpty ? nil : $0 })) {
                    Text(String(format: L("popbar.editor.reader.default"),
                                speech.resolve(nil).name)).tag("")
                    Divider()
                    ForEach(speech.allReaders) { Text($0.name).tag($0.id) }
                    // A reader this action names that no longer exists: keep
                    // the choice visible rather than silently switching it.
                    if let id = draft.reader, !speech.allReaders.contains(where: { $0.id == id }) {
                        Text(L("popbar.editor.reader.missing")).tag(id)
                    }
                }
            } footer: {
                Text(L("popbar.editor.speak.hint"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .settings:
            Section {
                Text(String(format: L("popbar.editor.settings.hint.format"), Brand.name))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .pause:
            Section {
                Text(String(format: L("popbar.editor.pause.hint.format"), Brand.name))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .transform:
            Section {
                Picker(L("popbar.editor.op"), selection: Binding(
                    get: { draft.op.flatMap(TextTransform.init(rawValue:)) ?? .uppercase },
                    set: { draft.op = $0.rawValue })) {
                    ForEach(TextTransform.allCases, id: \.self) { op in
                        Text(L("transform.\(op.rawValue)")).tag(op)
                    }
                }
                .onAppear { if draft.op == nil { draft.op = TextTransform.uppercase.rawValue } }
                outputPicker
            }
        case .shortcut:
            Section {
                TextField(L("popbar.editor.shortcut"), text: optionalText(\.shortcut))
                outputPicker
            } footer: {
                Text(L("popbar.editor.shortcut.hint")).fixedSize(horizontal: false, vertical: true)
            }
        case .script:
            Section {
                TextEditor(text: optionalText(\.script))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 70)
                outputPicker
            } header: {
                Text(L("popbar.editor.script"))
            } footer: {
                Text(L("popbar.editor.script.hint")).fixedSize(horizontal: false, vertical: true)
            }
        case .systemTranslate:
            Section {
                Picker(L("popbar.editor.targetLanguage"), selection: Binding(
                    get: { draft.targetLanguage ?? "" },
                    set: { draft.targetLanguage = $0.isEmpty ? nil : $0 })) {
                    Text(L("popbar.editor.targetLanguage.choose")).tag("")
                    Divider()
                    ForEach(translateTargets) { Text($0.name).tag($0.id) }
                    // A language this action names that this system does not
                    // list: keep it visible rather than silently clearing it.
                    // Also while the list is still loading, so the picker
                    // never flashes "Choose" for an action that has one.
                    if let id = draft.targetLanguage,
                       !translateTargets.contains(where: { $0.id == id }) {
                        Text(SystemTranslator.displayName(of: id)).tag(id)
                    }
                }
                .task { if translateTargets.isEmpty { translateTargets = await SystemTranslator.supportedTargets() } }
                outputPicker
            } footer: {
                Text(L(SystemTranslator.isAvailable ? "popbar.editor.systemTranslate.hint"
                                                    : "systemTranslate.error.needsNewerSystem"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ai:
            Section { outputPicker }
        default:
            EmptyView()
        }
    }

    /// Where the produced text goes. Hidden for `count`, which is always a report.
    @ViewBuilder
    private var outputPicker: some View {
        if !(draft.kind == .transform && draft.op == TextTransform.count.rawValue) {
            Picker(L("popbar.editor.output"), selection: Binding(
                get: { draft.outputMode },
                set: { draft.output = $0 == .panel ? nil : $0.rawValue })) {
                ForEach(ActionOutput.allCases, id: \.self) { mode in
                    Text(L("popbar.editor.output.\(mode.rawValue)")).tag(mode)
                }
            }
        }
    }

    private func optionalText(_ keyPath: WritableKeyPath<PopBarActionConfig, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0 })
    }

    // MARK: - Icon grid

    private var iconGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.iconGroups, id: \.title) { group in
                    Text(L(group.title)).font(.caption).foregroundStyle(.secondary)
                    iconRow(group.symbols)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 220)
    }

    private func iconRow(_ symbols: [String]) -> some View {
        LazyVGrid(columns: iconColumns, spacing: 6) {
            ForEach(symbols, id: \.self) { symbol in
                Button { draft.iconSymbol = symbol } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .frame(width: 32, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(draft.iconSymbol == symbol ? Color.accentColor.opacity(0.22)
                                                                 : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(draft.iconSymbol == symbol ? Color.accentColor : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Model override

    @ViewBuilder
    private var modelOverrideControls: some View {
        Toggle(L("popbar.editor.customModel"), isOn: Binding(
            get: { draft.modelOverride != nil },
            set: { on in
                if on {
                    let p = llm.settings.provider
                    let d = LLMConfig.providerDefaults(p)
                    draft.modelOverride = ModelOverride(provider: p, model: d.model,
                                                        reasoningEffort: LLMConfig.clampThinking("none", for: p))
                } else {
                    draft.modelOverride = nil
                }
            }))

        if let override = draft.modelOverride {
            Picker(L("popbar.llm.provider"), selection: Binding(
                get: { override.provider },
                set: { p in
                    let d = LLMConfig.providerDefaults(p)
                    draft.modelOverride = ModelOverride(provider: p, model: d.model,
                                                        reasoningEffort: LLMConfig.clampThinking("none", for: p))
                })) {
                ForEach(LLMConfig.providers, id: \.self) { p in Text(LLMConfig.displayName(p)).tag(p) }
            }

            TextField(L("popbar.llm.model"), text: Binding(
                get: { draft.modelOverride?.model ?? "" },
                set: { draft.modelOverride?.model = $0 }))

            Picker(L("popbar.llm.thinking"), selection: Binding(
                get: { draft.modelOverride?.reasoningEffort ?? "none" },
                set: { draft.modelOverride?.reasoningEffort = $0 })) {
                ForEach(LLMConfig.thinkingOptions(for: override.provider), id: \.tag) { opt in
                    Text(opt.label).tag(opt.tag)
                }
            }

            if !llm.isConfigured(forProvider: override.provider) {
                Label(String(format: L("popbar.editor.nokeyWarn"), LLMConfig.displayName(override.provider)),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Curated SF Symbols, grouped by what the actions they suit do. Every name
    /// was checked against the system's own availability table: none needs more
    /// than macOS 13.0 (`translate`, the obvious one for translating, needs 14.4
    /// and is left out). The original 48 are all still here, so an icon an action
    /// already uses never disappears from the picker.
    private static let iconGroups: [(title: String, symbols: [String])] = [
        ("icons.ai", ["sparkles", "sparkle", "wand.and.stars", "wand.and.rays", "brain", "brain.head.profile",
                      "lightbulb", "lightbulb.fill", "bolt.fill", "text.badge.checkmark", "checkmark.seal",
                      "pencil", "square.and.pencil", "highlighter", "eraser"]),
        ("icons.chat", ["text.bubble", "quote.bubble", "bubble.left.and.bubble.right", "exclamationmark.bubble",
                        "questionmark.bubble", "questionmark.circle"]),
        ("icons.translate", ["character.bubble", "globe", "globe.asia.australia", "globe.americas",
                             "globe.europe.africa", "character", "character.zh", "character.ja", "a.magnify", "abc",
                             "character.book.closed", "book.closed", "book", "graduationcap"]),
        ("icons.text", ["textformat", "textformat.abc", "textformat.size", "textformat.size.larger",
                        "textformat.size.smaller", "textformat.alt", "bold", "italic", "underline",
                        "strikethrough", "text.quote", "text.alignleft", "text.append", "text.word.spacing",
                        "list.bullet", "list.number", "increase.indent", "arrow.up.arrow.down",
                        "arrow.left.arrow.right", "shuffle"]),
        ("icons.clipboard", ["doc.on.doc", "doc.on.clipboard", "clipboard", "list.clipboard",
                             "arrow.right.doc.on.clipboard", "scissors", "trash", "arrow.2.squarepath",
                             "arrow.uturn.backward", "delete.left"]),
        ("icons.web", ["magnifyingglass", "binoculars", "safari", "safari.fill", "link", "link.badge.plus",
                       "network", "arrow.up.right.square", "arrow.up.forward.app", "play.rectangle", "cart",
                       "map", "mappin.and.ellipse"]),
        ("icons.calc", ["function", "x.squareroot", "sum", "plus.forwardslash.minus", "percent", "equal.circle",
                        "number", "dollarsign.circle", "yensign.circle", "eurosign.circle", "banknote", "ruler",
                        "scalemass", "thermometer.medium", "clock"]),
        ("icons.calendar", ["calendar", "calendar.badge.plus", "calendar.badge.clock", "alarm", "checklist",
                            "checkmark.circle"]),
        ("icons.notes", ["note.text", "note.text.badge.plus", "doc.text", "doc.badge.plus", "doc.append",
                         "bookmark", "bookmark.fill", "star", "star.fill", "flag.fill", "tag", "tag.fill",
                         "paperclip", "archivebox", "tray.and.arrow.down"]),
        ("icons.share", ["square.and.arrow.up", "envelope", "paperplane.fill", "message", "phone", "at",
                         "person.crop.circle.badge.plus", "printer"]),
        ("icons.media", ["pause.circle", "speaker.wave.2.fill", "waveform", "mic.fill", "music.note", "photo", "camera",
                         "text.viewfinder", "viewfinder", "qrcode"]),
        ("icons.dev", ["terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "curlybraces.square",
                       "command", "keyboard", "hammer", "wrench.and.screwdriver", "gearshape",
                       "puzzlepiece.extension", "key", "lock"]),
        ("icons.files", ["eye", "folder", "folder.badge.plus", "doc.text.magnifyingglass", "macwindow",
                         "square.on.square"]),
        ("icons.markers", ["info.circle", "exclamationmark.triangle", "hand.thumbsup"]),
    ]
}
