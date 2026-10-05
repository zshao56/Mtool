import SwiftUI

/// The Actions page: the list of things the popup offers, and the one setting
/// that belongs to an action kind rather than to the popup as a whole (what a
/// web-preview action does when the selection is not a link).
struct ActionsPage: View {

    @ObservedObject private var actions: ActionStore
    @ObservedObject private var llm: LLMService

    @State private var editingAction: PopBarActionConfig?
    /// Where the action in the editor came from, for analytics: set when a new
    /// one is opened, nil when an existing one is.
    @State private var editingSource: Analytics.ActionSource?
    @State private var previewFallback = PopBarPreferences.previewFallbackToSearch
    @State private var previewEngine = PopBarPreferences.previewSearchEngine
    @State private var askPrompt = MtoolPreferences.askPrompt

    init(actions: ActionStore, llm: LLMService) {
        _actions = ObservedObject(wrappedValue: actions)
        _llm = ObservedObject(wrappedValue: llm)
    }

    var body: some View {
        Form {
            Section(L("search.askPrompt.title")) {
                TextEditor(text: Binding(get: { askPrompt }, set: {
                    askPrompt = $0
                    MtoolPreferences.askPrompt = $0
                }))
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 74)
            }
            actionsSection
            // Only shown once such an action exists — a setting for a feature you
            // are not using is noise.
            if hasWebPreviewAction { webPreviewSection }
        }
        .formStyle(.grouped)
        .navigationTitle(L("page.actions"))
        .sheet(item: $editingAction) { action in
            ActionEditorView(action: action, llm: llm) { saved in
                // Look in BOTH levels. `actions.actions` is only the top level, so
                // saving an action that lives inside a group used to fall through to
                // `add` and append a SECOND copy of it at the root, with the same id
                // — after which deletes and drags resolved whichever came first.
                if let old = actions.action(id: saved.id) {
                    actions.update(saved)
                    if old.kind != saved.kind { Analytics.trackActionAdded(kind: saved.kind.rawValue, from: .changed) }
                } else {
                    actions.add(saved)
                    Analytics.trackActionAdded(kind: saved.kind.rawValue, from: editingSource ?? .custom)
                }
                editingAction = nil
            } onCancel: {
                editingAction = nil
            }
        }
    }

    private var hasWebPreviewAction: Bool {
        actions.actions.contains {
            $0.kind == .webPreview || $0.children.contains { $0.kind == .webPreview }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        PopBarActionListSection(
            actions: actions,
            onEdit: { editingSource = nil; editingAction = $0 },
            rowContent: { AnyView(actionRow($0)) },
            footerRow: { AnyView(actionsFooterRow) }
        )
    }

    /// The last row of the actions section: add an action, add a group, reset.
    private var actionsFooterRow: some View {
        HStack(spacing: 14) {
            Button {
                editingSource = .custom
                editingAction = PopBarActionConfig(title: "", iconSymbol: "sparkles", kind: .ai)
            } label: {
                Label(L("popbar.actions.add"), systemImage: "plus")
            }
            // A group is made here rather than by dropping one action on another:
            // it gets a name and an icon of its own up front, and the gesture that
            // would otherwise create one is already spoken for (dropping onto a
            // group row means "put it in THAT group").
            Button {
                editingSource = .custom
                editingAction = PopBarActionConfig(title: "", iconSymbol: "square.grid.2x2", kind: .group)
            } label: {
                Label(L("popbar.actions.addGroup"), systemImage: "rectangle.stack.badge.plus")
            }
            // Ready-made actions. Picking one opens it in the editor, so it can be
            // renamed or adjusted before it is added — and nothing is added by a
            // stray click in a menu.
            Menu {
                ForEach(ActionTemplates.sections()) { section in
                    Section(section.title) {
                        ForEach(section.actions) { template in
                            Button {
                                editingSource = .template
                                editingAction = template
                            } label: {
                                Label(template.title, systemImage: template.iconSymbol)
                            }
                        }
                    }
                }
            } label: {
                Label(L("popbar.actions.addTemplate"), systemImage: "square.grid.2x2")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button(L("popbar.actions.reset")) { actions.resetToDefaults() }
                .foregroundStyle(.secondary)
        }
    }

    private func actionRow(_ action: PopBarActionConfig) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: action.iconSymbol, color: .indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title.isEmpty ? L("popbar.action.untitled") : action.title)
                if action.kind == .group {
                    Text(String(format: L("popbar.group.count"), action.children.count))
                        .font(.caption).foregroundStyle(.secondary)
                } else if action.isAI {
                    Text(modelLabel(action)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            actionTags(action)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func modelLabel(_ action: PopBarActionConfig) -> String {
        if let o = action.modelOverride {
            return "\(LLMConfig.displayName(o.provider)) · \(o.model)"
        }
        return L("popbar.action.defaultModel")
    }

    /// The tags at the end of a row. Only what is worth noticing is tagged — an
    /// ordinary local action (copy, speak, open a URL, a transform shown in the
    /// popup) carries none. First what the action IS when that matters (it calls
    /// a model, it has no key for that model, it runs a shell command), then
    /// where its result goes when that is not the popup (it writes into your
    /// document, or onto the clipboard).
    private func actionTags(_ action: PopBarActionConfig) -> some View {
        HStack(spacing: 4) {
            ForEach(tags(for: action), id: \.text) { tag in
                Text(tag.text)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tag.solid ? Color.white : tag.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(tag.solid ? tag.color : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tag.color, lineWidth: 1))
            }
        }
    }

    private struct Tag { let text: String; let color: Color; var solid = false }

    private func tags(for action: PopBarActionConfig) -> [Tag] {
        guard action.kind != .group, !action.isUnsupported else { return [] }
        var tags: [Tag] = []
        if action.isAI {
            tags.append(Tag(text: L("popbar.tag.ai"), color: .indigo))
            if !llm.isConfigured(forProvider: action.modelOverride?.provider ?? llm.settings.provider) {
                tags.append(Tag(text: L("popbar.tag.needsKey"), color: .orange, solid: true))
            }
        }
        if action.kind == .script { tags.append(Tag(text: L("popbar.tag.script"), color: .red)) }
        if action.hasOutput {
            switch action.outputMode {
            case .panel:   break
            case .compare: tags.append(Tag(text: L("popbar.tag.compare"), color: .teal))
            case .replace: tags.append(Tag(text: L("popbar.tag.replace"), color: .teal))
            case .append:  tags.append(Tag(text: L("popbar.tag.append"), color: .teal))
            case .copy:    tags.append(Tag(text: L("popbar.tag.copy"), color: .teal))
            }
        }
        return tags
    }

    // MARK: - Web preview (link fallback)

    private var webPreviewSection: some View {
        Section {
            Toggle(isOn: $previewFallback) {
                iconLabel("magnifyingglass", .indigo, L("popbar.webpreview.fallback"))
            }
            .onChange(of: previewFallback) { PopBarPreferences.previewFallbackToSearch = $0 }
            if previewFallback {
                Picker(selection: $previewEngine) {
                    ForEach(PreviewSearchEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                } label: {
                    iconLabel("globe", .indigo, L("popbar.webpreview.engine"))
                }
                .onChange(of: previewEngine) { PopBarPreferences.previewSearchEngine = $0 }
            }
        } header: {
            Text(L("popbar.webpreview.section"))
        } footer: {
            Text(L("popbar.webpreview.fallback.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
