import SwiftUI
import AppKit
import ImageIO

/// The clipboard panel's view model. Main-thread; reloads from the store.
final class ClipboardPanelModel: ObservableObject {

    @Published var query: String = ""
    @Published var items: [ClipboardItem] = []
    @Published var snippets: [Snippet] = []
    @Published var paused: Bool = ClipboardPreferences.paused
    @Published var pasteAvailable = false
    @Published var previewItem: ClipboardItem?
    @Published var modes: [SearchMode] = []
    @Published var focusRequestID = UUID()
    /// The highlighted row, as a stable key: `"s<id>"` for a snippet, `"h<id>"`
    /// for a history entry. Snippets come first, matching the visual order, so
    /// ↑/↓ can move through both groups.
    @Published var selectedKey: String?
    @Published var toolbarSelection: String = "clipboard"

    let store: ClipboardStore

    var onPaste: ((ClipboardItem) -> Void)?
    var onCopy: ((ClipboardItem) -> Void)?
    var onTogglePin: ((ClipboardItem) -> Void)?
    var onDelete: ((ClipboardItem) -> Void)?
    var onClose: (() -> Void)?
    var onModeRequested: ((String) -> Void)?
    var onScreenshotRequested: (() -> Void)?

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
        let keys = rowKeys
        if let selectedKey, keys.contains(selectedKey) {
            // keep the selection
        } else {
            selectedKey = keys.first
        }
    }

    // MARK: - Row selection (snippets first, then history)

    static func snippetKey(_ snippet: Snippet) -> String { "s\(snippet.id)" }
    static func itemKey(_ item: ClipboardItem) -> String { "h\(item.id)" }

    private var rowKeys: [String] {
        snippets.map(Self.snippetKey) + items.map(Self.itemKey)
    }

    /// Move the keyboard selection by `delta` rows across snippets and history.
    func moveSelection(_ delta: Int) {
        let keys = rowKeys
        guard !keys.isEmpty else { selectedKey = nil; return }
        let current = keys.firstIndex(of: selectedKey ?? "") ?? (delta > 0 ? -1 : 0)
        let next = min(max(current + delta, 0), keys.count - 1)
        selectedKey = keys[next]
    }

    /// Paste the highlighted row through the same validated path (Return).
    func activateSelection() {
        guard let key = selectedKey else { return }
        if key.hasPrefix("s"), let id = Int64(String(key.dropFirst())),
           let snippet = snippets.first(where: { $0.id == id }) {
            onPaste?(snippetItem(snippet))
        } else if key.hasPrefix("h"), let id = Int64(String(key.dropFirst())),
                  let item = items.first(where: { $0.id == id }) {
            onPaste?(item)
        }
    }

    private var toolbarIDs: [String] { ["screenshot", "clipboard"] + modes.map(\.id) }

    func moveToolbarSelection(_ delta: Int) {
        let ids = toolbarIDs
        let current = ids.firstIndex(of: toolbarSelection) ?? 1
        toolbarSelection = ids[(current + delta + ids.count) % ids.count]
        // AI modes are pages: reaching one should open its question box at once.
        // Built-in actions such as screenshot still require Return.
        if modes.contains(where: { $0.id == toolbarSelection }) {
            onModeRequested?(toolbarSelection)
        }
    }

    func activateToolbarSelection() {
        switch toolbarSelection {
        case "screenshot": onScreenshotRequested?()
        case "clipboard": activateSelection()
        default: onModeRequested?(toolbarSelection)
        }
    }

    /// A snippet as a pasteboard entry, so it travels the same validated paste
    /// path as a history row.
    func snippetItem(_ snippet: Snippet) -> ClipboardItem {
        ClipboardItem(kind: .text, text: snippet.text,
                      contentHash: ClipboardPolicyEngine.dedupeKey(
                        kind: .text, text: snippet.text, imageDigest: nil))
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
            FloatingPanelDragHandle()
                .frame(maxWidth: .infinity)
                .frame(height: 15)
                .overlay {
                    Capsule().fill(Color.secondary.opacity(0.35))
                        .frame(width: 30, height: 4)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 20)
                .padding(.top, 3)
            header
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.isEditing {
                        snippetEditor
                        Divider().padding(.vertical, 4)
                    }
                    if !model.snippets.isEmpty {
                        sectionHeader(L("clipboard.snippets"))
                        ForEach(model.snippets) { snippet in
                            snippetRow(snippet)
                                .id(ClipboardPanelModel.snippetKey(snippet))
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
                        row(icon: icon(for: item), text: item.singleLine(),
                            imageURL: item.kind == .image ? item.blobPath.map { model.store.blobURL(for: $0) } : nil,
                            subtitle: subtitle(for: item),
                            isSelected: model.selectedKey == ClipboardPanelModel.itemKey(item),
                            trailing: AnyView(actions(for: item)),
                            onTap: { model.onPaste?(item) })
                            .id(ClipboardPanelModel.itemKey(item))
                    }
                }
            }
            .onChange(of: model.selectedKey) { selected in
                guard let selected else { return }
                withAnimation { proxy.scrollTo(selected, anchor: .center) }
            }
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 418)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { imagePreviewOverlay }
        .onAppear {
            model.reload()
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: model.focusRequestID) { _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: model.query) { _ in model.previewItem = nil; model.reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("clipboard.search"), text: Binding(
                get: { model.query },
                set: { model.setQuery($0) }))
                .textFieldStyle(.plain)
                .focused($searchFocused)
            Button { model.beginAddSnippet() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help(L("clipboard.snippet.add"))
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
        VStack(spacing: 4) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button { model.onScreenshotRequested?() } label: {
                        Label(L("search.screenshot"), systemImage: "camera.viewfinder")
                            .font(.system(size: 11))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .background(model.toolbarSelection == "screenshot" ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: Capsule())
                    .id("screenshot")
                    Label(L("search.clipboard"), systemImage: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(model.toolbarSelection == "clipboard" ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: Capsule())
                        .id("clipboard")
                    ForEach(model.modes) { mode in
                        Button { model.onModeRequested?(mode.id) } label: {
                            Text(mode.title)
                                .font(.system(size: 11))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .background(model.toolbarSelection == mode.id ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: Capsule())
                        .help(mode.title)
                        .id(mode.id)
                    }
                }
            }
            .onChange(of: model.toolbarSelection) { selected in
                withAnimation { proxy.scrollTo(selected, anchor: .center) }
            }
            }
            HStack {
                Text(model.paused ? L("clipboard.paused") :
                     (model.pasteAvailable ? L("clipboard.localOnly") : L("clipboard.copyThenPaste")))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: L("clipboard.count.format"), model.items.count))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder
    private var imagePreviewOverlay: some View {
        if let item = model.previewItem, let path = item.blobPath {
            ZStack {
                Color.black.opacity(0.32)
                    .onTapGesture { model.previewItem = nil }
                VStack(spacing: 14) {
                    HStack {
                        Text(item.singleLine())
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Button { model.previewItem = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("clipboard.preview.close"))
                    }
                    ClipboardImageContent(url: model.store.blobURL(for: path), maxPixel: 1000)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(16)
                .frame(width: 510, height: 330)
                .background(Color(nsColor: .windowBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 14)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }

    /// A history row. The main area is its own Button; the trailing action
    /// buttons sit OUTSIDE it as siblings, so tapping pin/delete/save can never
    /// also trigger a paste.
    private func row(icon: String, text: String, imageURL: URL? = nil, subtitle: String?,
                     isSelected: Bool, trailing: AnyView?, onTap: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Button(action: onTap) {
                HStack(spacing: 9) {
                    if let imageURL {
                        ClipboardImageContent(url: imageURL, maxPixel: 96)
                            .frame(width: 54, height: 44)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(text).font(.system(size: 12)).lineLimit(2)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 10))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let trailing { trailing }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
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

    private func snippetRow(_ snippet: Snippet) -> some View {
        HStack(spacing: 9) {
            // The paste area is its own Button; the action buttons are siblings,
            // so an edit/delete/reorder tap can never also paste.
            Button {
                model.onPaste?(model.snippetItem(snippet))
            } label: {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                Button { model.onCopy?(model.snippetItem(snippet)) } label: {
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
        .background(model.selectedKey == ClipboardPanelModel.snippetKey(snippet)
                        ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func actions(for item: ClipboardItem) -> some View {
        HStack(spacing: 6) {
            if item.kind == .image, item.blobPath != nil {
                Button { model.previewItem = item } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.plain).help(L("clipboard.preview"))
            }
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
            Button {
                if model.previewItem?.id == item.id { model.previewItem = nil }
                model.onDelete?(item)
            } label: {
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

/// Decode only enough pixels for the current preview size. Clipboard screenshots
/// can be large, so the history list never loads full-resolution PNGs into memory.
private struct ClipboardImageContent: View {
    let url: URL
    let maxPixel: Int
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { image = ClipboardImageLoader.image(at: url, maxPixel: maxPixel) }
    }
}

private enum ClipboardImageLoader {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func image(at url: URL, maxPixel: Int) -> NSImage? {
        let key = "\(url.path):\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail,
                            size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }
}
