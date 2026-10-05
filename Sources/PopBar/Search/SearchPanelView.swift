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
    var onResize: (() -> Void)?

    var showsOutput: Bool { busy || error != nil || !result.isEmpty }

    var selectedMode: SearchMode {
        modes.first { $0.id == selectedModeID } ?? modes.first ?? SearchMode.askMode()
    }

    func resetForOpen() {
        query = ""
        result = ""
        error = nil
        busy = false
        onResize?()
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
        onResize?()
    }

    func appendStream(_ text: String) {
        result = text
        onResize?()
    }

    func finish(result: String?, error: String?) {
        busy = false
        if let result, !result.isEmpty { self.result = result }
        self.error = error
        onResize?()
    }
}

/// The quick-search box (scenario 3). Modes stay visible under the question,
/// with screenshot and submit actions fixed at the edges of the bottom row.
struct SearchPanelView: View {
    @ObservedObject var model: SearchPanelModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(L("search.placeholder"), text: $model.query, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .lineLimit(1...3)
                .focused($queryFocused)
                .onSubmit { model.submit() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.top, 23)

            HStack(spacing: 10) {
                Button { model.onScreenshot?() } label: {
                    Label(L("search.screenshot"), systemImage: "camera.viewfinder")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(L("search.screenshot"))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.modes) { mode in
                            Button {
                                model.selectedModeID = mode.id
                                queryFocused = true
                            } label: {
                                Text(mode.title)
                                    .font(.system(size: 12, weight: model.selectedModeID == mode.id ? .semibold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(model.selectedModeID == mode.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(mode.title)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                if model.busy { ProgressView().controlSize(.small) }
                Button { model.submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                .opacity(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy ? 0.45 : 1)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 17)

            if model.showsOutput {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let error = model.error {
                            Text(error).foregroundStyle(.red)
                        } else {
                            Text(model.result).textSelection(.enabled)
                        }
                        if !model.result.isEmpty {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.result, forType: .string)
                            } label: {
                                Label(L("search.copyResult"), systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .frame(height: 200)
            }
        }
        .frame(width: 560, height: model.showsOutput ? 370 : 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear { queryFocused = true }
    }
}
