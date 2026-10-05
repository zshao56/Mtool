import SwiftUI
import AppKit

/// One selectable mode under the search box. Built from the user's AI actions so
/// the modes and the action bar share one source of truth, plus a built-in "Ask"
/// mode for a free question.
struct SearchMode: Identifiable, Equatable {
    let id: String
    let title: String
    let prompt: String
    let isAsk: Bool

    static func askMode() -> SearchMode {
        SearchMode(id: "ask", title: L("search.mode.ask"),
                   prompt: "You are a helpful, concise assistant. Answer the user's request directly.",
                   isAsk: true)
    }
}

/// The quick-search panel's view model.
final class SearchPanelModel: ObservableObject {
    @Published var query: String = ""
    @Published var modes: [SearchMode] = []
    @Published var selectedModeID: String = "ask"
    @Published var result: String = ""
    @Published var busy: Bool = false
    @Published var error: String?

    var onClose: (() -> Void)?
    var onScreenshot: (() -> Void)?
    var onSubmit: ((String, SearchMode) -> Void)?

    var selectedMode: SearchMode {
        modes.first { $0.id == selectedModeID } ?? modes.first ?? SearchMode.askMode()
    }

    func loadModes(from actions: [PopBarActionConfig]) {
        var modes: [SearchMode] = [SearchMode.askMode()]
        for action in actions where action.kind == .ai && !action.isUnsupported {
            let prompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { continue }
            modes.append(SearchMode(id: action.id, title: action.title, prompt: prompt, isAsk: false))
        }
        self.modes = modes
        if !modes.contains(where: { $0.id == selectedModeID }) {
            selectedModeID = modes.first?.id ?? "ask"
        }
    }

    func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        error = nil
        result = ""
        busy = true
        onSubmit?(text, selectedMode)
    }

    func appendStream(_ text: String) { result = text }

    func finish(result: String?, error: String?) {
        busy = false
        if let result, !result.isEmpty { self.result = result }
        self.error = error
    }
}

/// The quick-search box (scenario 3). A question field with a mode menu, a
/// screenshot-and-copy shortcut, and a streaming result.
struct SearchPanelView: View {
    @ObservedObject var model: SearchPanelModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                TextField(L("search.placeholder"), text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit { model.submit() }
                if !model.modes.isEmpty {
                    Picker("", selection: $model.selectedModeID) {
                        ForEach(model.modes) { mode in Text(mode.title).tag(mode.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
                Button { model.submit() } label: {
                    Image(systemName: "arrow.right.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                Button { model.onClose?() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            Divider()

            HStack(spacing: 8) {
                Button {
                    model.onScreenshot?()
                } label: {
                    Label(L("search.screenshot"), systemImage: "camera.viewfinder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                if !model.result.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.result, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help(L("search.copyResult"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = model.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if model.result.isEmpty {
                        Text(L("search.hint"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(model.result).font(.system(size: 12)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .frame(width: 520, height: 340)
        .onAppear { queryFocused = true }
    }
}
