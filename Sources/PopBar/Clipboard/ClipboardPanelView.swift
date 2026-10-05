import SwiftUI
import AppKit

/// The clipboard panel's view model. Main-thread; reloads from the store.
final class ClipboardPanelModel: ObservableObject {

    @Published var query: String = ""
    @Published var items: [ClipboardItem] = []
    @Published var snippets: [Snippet] = []
    @Published var paused: Bool = ClipboardPreferences.paused
    /// The row highlighted for keyboard navigation.
    @Published var selectedID: Int64?

    let store: ClipboardStore

    var onPaste: ((ClipboardItem) -> Void)?
    var onCopy: ((ClipboardItem) -> Void)?
    var onTogglePin: ((ClipboardItem) -> Void)?
    var onDelete: ((ClipboardItem) -> Void)?
    var onClose: (() -> Void)?

    // Snippet editor state. `editingID == 0` means "new"; nil means not editing.
    @Published var editingID: Int64?
    @Published var editingTitle: String = ""
    @Published var editingText: String = ""
    private var editingSortOrder = 0

    var isEditing: Bool { editingID != nil }

    init(store: ClipboardStore) {
        self.store = store
    }

    func reload() {
        items = store.items(matching: query, limit: 200)
        snippets = store.snippets()
        paused = ClipboardPreferences.paused
        if let selectedID, items.contains(where: { $0.id == selectedID }) {
            // keep the selection
        } else {
            selectedID = items.first?.id
        }
    }

    /// Move the keyboard selection by `delta` rows (wrapping).
    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        let next = min(max(current + delta, 0), items.count - 1)
        selectedID = items[next].id
    }

    /// Paste the highlighted row (Return).
    func activateSelection() {
        guard let item = items.first(where: { $0.id == selectedID }) ?? items.first else { return }
        onPaste?(item)
    }

    func setQuery(_ text: String) {
        query = text
        reload()
    }

    func togglePause() {
        ClipboardPreferences.paused.toggle()
        paused = ClipboardPreferences.paused
    }

    // MARK: - Snippets (常用词): add / edit / reorder

    func beginAddSnippet(title: String = "", text: String = "") {
        editingID = 0
        editingSortOrder = 0
        editingTitle = title
        editingText = text
    }

    /// Prefill the editor from a history entry.
    func addSnippet(from item: ClipboardItem) {
        beginAddSnippet(title: String(item.singleLine(limit: 40)),
                        text: item.text ?? item.singleLine())
    }

    func beginEditSnippet(_ snippet: Snippet) {
        editingID = snippet.id
        editingSortOrder = snippet.sortOrder
        editingTitle = snippet.title
        editingText = snippet.text
    }

    func cancelEdit() {
        editingID = nil
        editingTitle = ""
        editingText = ""
        editingSortOrder = 0
    }

    func saveEdit() {
        guard let id = editingID else { return }
        let text = editingText
        var title = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
            title = firstLine.isEmpty ? L("clipboard.snippet.untitled") : String(firstLine.prefix(60))
        }
        // An entirely empty snippet is not worth saving.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelEdit()
            return
        }
        store.upsertSnippet(Snippet(id: id, title: title, text: text, sortOrder: editingSortOrder))
        cancelEdit()
        reload()
    }

    func deleteSnippet(_ snippet: Snippet) {
        store.deleteSnippet(id: snippet.id)
        reload()
    }

    /// Move a snippet one place up or down and persist the new order.
    func moveSnippet(_ snippet: Snippet, up: Bool) {
        var list = snippets
        guard let index = list.firstIndex(where: { $0.id == snippet.id }) else { return }
        let target = up ? index - 1 : index + 1
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        store.reorderSnippets(list)
        reload()
    }
}

/// The clipboard panel UI: a search field, the user's snippets pinned at the top,
/// then the local history. Keyboard: ↑/↓ move, Return pastes, Esc closes.
struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.isEditing {
                        snippetEditor
                        Divider().padding(.vertical, 4)
                    }
                    HStack {
                        sectionHeader(L("clipboard.snippets"))
                        Spacer()
                        Button {
                            model.beginAddSnippet()
                        } label: {
                            Image(systemName: "plus").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help(L("clipboard.snippet.add"))
                        .padding(.trailing, 12)
                    }
                    if model.snippets.isEmpty {
                        Text(L("clipboard.snippets.empty"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.bottom, 6)
                    }
                    ForEach(model.snippets) { snippet in
                        snippetRow(snippet)
                    }
                    Divider().padding(.vertical, 4)
                    sectionHeader(L("clipboard.history"))
                    if model.items.isEmpty {
                        Text(L("clipboard.empty"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 16)
                    }
                    ForEach(model.items) { item in
                        row(id: item.id, icon: icon(for: item), text: item.singleLine(),
                            subtitle: subtitle(for: item),
                            trailing: AnyView(actions(for: item)),
                            onTap: { model.onPaste?(item) })
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 440, height: 500)
        .onAppear { model.reload(); searchFocused = true }
        .onChange(of: model.query) { _ in model.reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("clipboard.search"), text: Binding(
                get: { model.query },
                set: { model.setQuery($0) }))
                .textFieldStyle(.plain)
                .focused($searchFocused)
            Button {
                model.togglePause()
            } label: {
                Image(systemName: model.paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .help(model.paused ? L("clipboard.resume") : L("clipboard.pause"))
            Button {
                model.onClose?()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var footer: some View {
        HStack {
            Text(model.paused ? L("clipboard.paused") : L("clipboard.localOnly"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: L("clipboard.count.format"), model.items.count))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }

    private func row(id: Int64, icon: String, text: String, subtitle: String?,
                     trailing: AnyView?, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(text).font(.system(size: 12)).lineLimit(2)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 10))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let trailing { trailing }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(model.selectedID == id ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var snippetEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.editingID == 0 ? L("clipboard.snippet.new") : L("clipboard.snippet.edit"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(L("clipboard.snippet.save")) { model.saveEdit() }
                    .buttonStyle(.borderless)
                Button(L("clipboard.cancel")) { model.cancelEdit() }
                    .buttonStyle(.borderless)
            }
            TextField(L("clipboard.snippet.title"), text: $model.editingTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.saveEdit() }
            TextEditor(text: $model.editingText)
                .font(.system(size: 12))
                .frame(minHeight: 76)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3)))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func snippetItem(_ snippet: Snippet) -> ClipboardItem {
        ClipboardItem(kind: .text, text: snippet.text,
                      contentHash: ClipboardPolicyEngine.dedupeKey(
                        kind: .text, text: snippet.text, imageDigest: nil))
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.title.isEmpty ? snippet.text : snippet.title)
                    .font(.system(size: 12)).lineLimit(1)
                if !snippet.title.isEmpty {
                    Text(snippet.text).font(.system(size: 10))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Button { model.onCopy?(snippetItem(snippet)) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain).help(L("clipboard.copy"))
                Button { model.beginEditSnippet(snippet) } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain).help(L("clipboard.snippet.edit"))
                Button { model.moveSnippet(snippet, up: true) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain).help(L("clipboard.snippet.moveUp"))
                .disabled(model.snippets.first?.id == snippet.id)
                Button { model.moveSnippet(snippet, up: false) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain).help(L("clipboard.snippet.moveDown"))
                .disabled(model.snippets.last?.id == snippet.id)
                Button { model.deleteSnippet(snippet) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain).help(L("clipboard.delete"))
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
        // A click on the row pastes through the same validated path as a history
        // entry; the explicit copy button above is the copy-only alternative.
        .onTapGesture { model.onPaste?(snippetItem(snippet)) }
    }

    private func actions(for item: ClipboardItem) -> some View {
        HStack(spacing: 6) {
            Button { model.onTogglePin?(item) } label: {
                Image(systemName: item.pinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.plain).help(item.pinned ? L("clipboard.unpin") : L("clipboard.pin"))
            if item.kind != .image {
                Button { model.addSnippet(from: item) } label: {
                    Image(systemName: "text.badge.plus")
                }
                .buttonStyle(.plain).help(L("clipboard.saveSnippet"))
            }
            Button { model.onDelete?(item) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain).help(L("clipboard.delete"))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func icon(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text:  return "doc.text"
        case .url:   return "link"
        case .image: return "photo"
        }
    }

    private func subtitle(for item: ClipboardItem) -> String? {
        var parts: [String] = []
        if let source = item.sourceBundleID, !source.isEmpty {
            parts.append(source.split(separator: ".").last.map(String.init) ?? source)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        parts.append(formatter.localizedString(for: item.createdAt, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }
}
