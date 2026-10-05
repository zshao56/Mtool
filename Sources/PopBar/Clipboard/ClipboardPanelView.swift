import SwiftUI
import AppKit

/// The clipboard panel's view model. Main-thread; reloads from the store.
final class ClipboardPanelModel: ObservableObject {

    @Published var query: String = ""
    @Published var items: [ClipboardItem] = []
    @Published var snippets: [Snippet] = []
    @Published var paused: Bool = ClipboardPreferences.paused

    let store: ClipboardStore

    var onPaste: ((ClipboardItem) -> Void)?
    var onCopy: ((ClipboardItem) -> Void)?
    var onTogglePin: ((ClipboardItem) -> Void)?
    var onDelete: ((ClipboardItem) -> Void)?
    var onSaveSnippet: ((ClipboardItem) -> Void)?
    var onClose: (() -> Void)?

    init(store: ClipboardStore) {
        self.store = store
    }

    func reload() {
        items = store.items(matching: query, limit: 200)
        snippets = store.snippets()
        paused = ClipboardPreferences.paused
    }

    func setQuery(_ text: String) {
        query = text
        reload()
    }

    func togglePause() {
        ClipboardPreferences.paused.toggle()
        paused = ClipboardPreferences.paused
    }
}

/// The clipboard panel UI: a search field, the user's snippets pinned at the top,
/// then the local history. Keyboard: ↑/↓ move, Return pastes, Esc closes.
struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @State private var selectedID: Int64?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !model.snippets.isEmpty {
                        sectionHeader(L("clipboard.snippets"))
                        ForEach(model.snippets) { snippet in
                            row(id: -snippet.id, icon: "pin.fill",
                                text: snippet.title.isEmpty ? snippet.text : snippet.title,
                                subtitle: snippet.title.isEmpty ? nil : snippet.text,
                                trailing: nil,
                                onTap: {
                                    model.onCopy?(ClipboardItem(kind: .text, text: snippet.text,
                                                                contentHash: snippet.text))
                                })
                        }
                        Divider().padding(.vertical, 4)
                    }
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
            .background(selectedID == id ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actions(for item: ClipboardItem) -> some View {
        HStack(spacing: 6) {
            Button { model.onTogglePin?(item) } label: {
                Image(systemName: item.pinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.plain).help(item.pinned ? L("clipboard.unpin") : L("clipboard.pin"))
            Button { model.onSaveSnippet?(item) } label: {
                Image(systemName: "text.badge.plus")
            }
            .buttonStyle(.plain).help(L("clipboard.saveSnippet"))
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
