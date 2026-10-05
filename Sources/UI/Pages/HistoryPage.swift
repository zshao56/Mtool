import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The History page: every action run from the popup, newest first — a list of
/// runs grouped by day beside the chosen run's detail (layout A of
/// `design/history-options.html`). Records come from `HistoryStore`; what is
/// recorded is decided by `HistoryRecorder`.
struct HistoryPage: View {

    enum Filter: Hashable {
        case all
        case category(HistoryRecord.Category)
    }

    @State private var filter: Filter = .all
    /// The bundle id of the one app to show; nil = every app.
    @State private var app: String?
    @State private var query = ""
    /// `query` once typing has paused, which is what is searched.
    @State private var searched = ""
    @State private var selectedID: Int64?

    @State private var records: [HistoryRecord] = []
    @State private var counts: [HistoryRecord.Category?: Int] = [:]
    /// The same, ignoring the search and the app: which chips exist at all.
    @State private var totals: [HistoryRecord.Category?: Int] = [:]
    @State private var apps: [(bundleID: String, name: String)] = []
    /// Whether anything has been recorded at all, ignoring every filter.
    @State private var hasAny = true
    @State private var loaded = false
    /// How many rows are loaded; grows as the list is scrolled to its end.
    @State private var limit = Self.pageSize
    @State private var showSettings = false
    @State private var recordingEnabled = HistoryPreferences.enabled

    private static let pageSize = 200
    private let store = HistoryStore.shared

    private var storeQuery: HistoryStore.Query {
        var q = HistoryStore.Query(text: searched, category: nil, appBundleID: app)
        if case .category(let c) = filter { q.category = c }
        return q
    }

    /// Everything that changes what is loaded.
    private struct LoadKey: Equatable {
        var query: HistoryStore.Query
        var limit: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                list
                    .frame(width: 290)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(L("page.history"))
        .task(id: LoadKey(query: storeQuery, limit: limit)) { await load() }
        .task(id: query) {
            // Search once typing pauses, not on every key.
            if query.isEmpty { searched = ""; return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            searched = query
        }
        .onChange(of: storeQuery) { _ in limit = Self.pageSize }
        .onReceive(NotificationCenter.default.publisher(for: .historyDidChange)) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showSettings, onDismiss: { recordingEnabled = HistoryPreferences.enabled }) {
            HistorySettingsView()
        }
    }

    private func load() async {
        let q = storeQuery
        async let rows = store.records(matching: q, limit: limit)
        async let counted = store.counts(matching: q)
        async let appList = store.apps()
        async let total = store.counts(matching: HistoryStore.Query())
        let (r, c, a, t) = await (rows, counted, appList, total)
        records = r
        counts = c
        apps = a
        totals = t
        hasAny = (t[nil] ?? 0) > 0
        loaded = true
        // The list always shows a selection while it has rows: the first row at
        // first, and again whenever a filter or search hides the selected one.
        if !r.contains(where: { $0.id == selectedID }) { selectedID = r.first?.id }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("history.search"), text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L("history.search.clear"))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))

                appPicker

                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L("history.settings"))
            }
            HStack(spacing: 6) {
                chip(.all, L("history.filter.all"), count: counts[nil] ?? 0)
                // A category gets its chip once it has any record at all; one
                // the search or app has emptied stays, with 0, so the row does
                // not jump while typing.
                ForEach(HistoryRecord.Category.allCases, id: \.self) { c in
                    if (totals[c] ?? 0) > 0 || filter == .category(c) {
                        chip(.category(c), Self.title(of: c), count: counts[c] ?? 0)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var appPicker: some View {
        Menu {
            Button { app = nil } label: {
                Label(L("history.app.all"), systemImage: "square.grid.2x2").labelStyle(.titleAndIcon)
            }
            if !apps.isEmpty { Divider() }
            ForEach(apps, id: \.bundleID) { a in
                Button { app = a.bundleID } label: {
                    // Menus drop a Label's icon unless the style asks for it.
                    Label { Text(a.name) } icon: { Image(nsImage: AppIcons.icon(for: a.bundleID, size: 16)) }
                        .labelStyle(.titleAndIcon)
                }
            }
        } label: {
            if let id = app {
                Label { Text(apps.first { $0.bundleID == id }?.name ?? id) }
                    icon: { Image(nsImage: AppIcons.icon(for: id, size: 16)) }
            } else {
                Label(L("history.app.all"), systemImage: "square.grid.2x2")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func chip(_ value: Filter, _ title: String, count: Int) -> some View {
        let on = filter == value
        return Button { filter = value } label: {
            HStack(spacing: 4) {
                Text(title)
                Text(verbatim: "\(count)").opacity(0.6)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(Capsule().fill(on ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(on ? Color.clear : Color(nsColor: .separatorColor)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    static func title(of c: HistoryRecord.Category) -> String {
        switch c {
        case .ai:         return L("history.filter.ai")
        case .text:       return L("history.filter.text")
        case .speech:     return L("history.filter.speech")
        case .web:        return L("history.filter.web")
        case .automation: return L("history.filter.automation")
        case .error:      return L("history.filter.error")
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            if records.isEmpty {
                VStack(spacing: 8) {
                    if loaded && !hasAny {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text(L("history.none")).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else if loaded {
                        Text(L("history.empty")).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(DayGroup.group(records)) { group in
                        Section {
                            ForEach(group.records) { r in
                                ListRow(record: r)
                                    .tag(r.id)
                                    .onAppear {
                                        // The last loaded row came into view: load more.
                                        if r.id == records.last?.id, records.count >= limit { limit += Self.pageSize }
                                    }
                            }
                        } header: {
                            Text(group.title)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            if !recordingEnabled {
                Divider()
                Button { showSettings = true } label: {
                    Label(L("history.paused"), systemImage: "pause.circle")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let r = records.first(where: { $0.id == selectedID }) {
            ScrollView {
                RecordDetail(record: r)
                    .padding(.horizontal, 20).padding(.vertical, 16)
            }
            .id(r.id)
        } else if !records.isEmpty {
            // The list says when nothing matches; here there is only ever
            // something to say while rows exist but none is chosen.
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(L("history.select")).foregroundStyle(.secondary)
            }
        } else {
            // Still takes the space, so the list keeps its width.
            Color.clear
        }
    }
}

// MARK: - Settings

/// The history's settings, behind the page's gear button.
private struct HistorySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = HistoryPreferences.enabled
    @State private var retention = HistoryPreferences.retentionDays
    @State private var recordCopy = HistoryPreferences.recordCopy
    @State private var excluded = HistoryPreferences.excludedApps
    @State private var size: Int64?
    @State private var confirmClear = false
    @State private var clearing = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: $enabled) {
                        featureLabel("clock.arrow.circlepath", .green,
                                     L("history.settings.enable"), L("history.settings.enable.subtitle"))
                    }
                    .onChange(of: enabled) { HistoryPreferences.enabled = $0 }

                    Picker(selection: $retention) {
                        ForEach(HistoryPreferences.retentionChoices, id: \.self) { days in
                            Text(Self.retentionTitle(days)).tag(days)
                        }
                    } label: {
                        iconLabel("calendar", .green, L("history.settings.retention"))
                    }
                    .onChange(of: retention) {
                        HistoryPreferences.retentionDays = $0
                        HistoryStore.shared.applyRetention { refreshSize() }
                    }

                    Toggle(isOn: $recordCopy) {
                        iconLabel("doc.on.doc", .green, L("history.settings.recordCopy"))
                    }
                    .onChange(of: recordCopy) { HistoryPreferences.recordCopy = $0 }
                }

                Section {
                    ForEach(excluded, id: \.self) { id in
                        AppListRow(bundleID: id) { excluded.removeAll { $0 == id } }
                    }
                    AddAppMenu(skipping: excluded) { id in
                        if !excluded.contains(id) { excluded.append(id) }
                    }
                } header: {
                    Text(L("history.settings.excluded"))
                } footer: {
                    Text(L("history.settings.excluded.footer"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onChange(of: excluded) { HistoryPreferences.excludedApps = $0 }

                Section {
                    LabeledContent {
                        Text(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                            .foregroundStyle(.secondary)
                    } label: {
                        iconLabel("internaldrive", .gray, L("history.settings.size"))
                    }
                    HStack {
                        Spacer()
                        Button(role: .destructive) { confirmClear = true } label: {
                            Text(L("history.settings.clear"))
                        }
                        .disabled(clearing)
                    }
                } footer: {
                    Text(L("history.settings.privacy"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L("history.settings.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 500, height: 560)
        .onAppear { refreshSize() }
        .confirmationDialog(L("history.settings.clear.confirm"), isPresented: $confirmClear) {
            Button(L("history.settings.clear.action"), role: .destructive) {
                clearing = true
                HistoryStore.shared.deleteAll {
                    clearing = false
                    refreshSize()
                }
            }
        } message: {
            Text(L("history.settings.clear.message"))
        }
    }

    private func refreshSize() {
        Task { size = await HistoryStore.shared.diskSize() }
    }

    static func retentionTitle(_ days: Int) -> String {
        switch days {
        case 0:   return L("history.retention.forever")
        case 365: return L("history.retention.year")
        default:  return String(format: L("history.retention.days"), days)
        }
    }
}

// MARK: - App icons

/// The icon of the app a record came from, looked up by bundle id. An app that
/// is no longer installed gets a placeholder rather than nothing.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String, size: CGFloat) -> NSImage {
        let key = "\(bundleID)@\(size)"
        if let hit = cache[key] { return hit.copy() as! NSImage }
        let base: NSImage
        if let url = appURL(for: bundleID) {
            base = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            // The system's generic app icon draws as a blank tile at this
            // size; a dashed app outline reads as "an app, not found".
            base = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
                ?? NSWorkspace.shared.icon(for: .applicationBundle)
        }
        // A copy, so setting the size here does not resize the shared image
        // other callers were handed.
        let image = base.copy() as! NSImage
        image.size = NSSize(width: size, height: size)
        cache[key] = image
        return image.copy() as! NSImage
    }
}

// MARK: - Display helpers

private extension HistoryRecord {

    /// The action's tile colour, by kind: the action itself has none.
    var actionColor: Color {
        switch PopBarActionConfig.Kind(rawValue: actionKind) {
        case .ai:              return .indigo
        case .systemTranslate: return .cyan
        case .transform:       return .purple
        case .speak:           return .orange
        case .openURL:         return .blue
        case .webPreview:      return .blue
        case .quickLook, .revealInFinder: return .teal
        case .shortcut:        return .pink
        case .script:          return Color(nsColor: .darkGray)
        case .copy:            return .green
        default:               return .gray
        }
    }

    var symbol: String { actionSymbol.isEmpty ? "sparkles" : actionSymbol }

    var title: String { actionTitle.isEmpty ? actionKind : actionTitle }

    /// Provider · model, for a run on a model.
    var engine: String? {
        guard let model, !model.isEmpty else { return nil }
        guard let provider, !provider.isEmpty else { return model }
        return "\(LLMConfig.displayName(provider)) · \(model)"
    }

    var siteName: String {
        guard let output, let host = URL(string: output)?.host else { return output ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayURL: String {
        guard let output else { return "" }
        return output.removingPercentEncoding ?? output
    }

    var silentNote: String {
        actionKind == PopBarActionConfig.Kind.copy.rawValue ? L("history.silent.copied") : L("history.silent.done")
    }

    /// The result in one line, for a list row.
    var summary: String {
        switch typedOutcome {
        case .text, .message: return output ?? ""
        case .link:           return "\(siteName) · \(displayURL)"
        case .file:           return output ?? ""
        case .speech:         return extras["reader"] ?? L("history.speech")
        case .silent:         return silentNote
        case nil:             return output ?? outcomeType
        }
    }

    /// What the Copy buttons offer, in order; the first is the primary one.
    var copyables: [(label: String, text: String)] {
        let original = (L("history.copyInput"), input)
        switch typedOutcome {
        case .text:    return [(L("history.copyResult"), output ?? ""), original]
        case .message: return [(L(isError ? "history.copyMessage" : "history.copyResult"), output ?? ""), original]
        case .link:    return [(L("history.copyLink"), output ?? ""), original]
        case .file:    return [(L("history.copyPath"), output ?? "")]
        case .speech, .silent, nil: return [original]
        }
    }
}

// MARK: - Grouping by day

private struct DayGroup: Identifiable {
    let id: Date
    let title: String
    let records: [HistoryRecord]

    static func group(_ records: [HistoryRecord]) -> [DayGroup] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: records) { cal.startOfDay(for: $0.createdAt) }
        return byDay.keys.sorted(by: >).map { day in
            DayGroup(id: day, title: title(for: day),
                     records: byDay[day]!.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) })
        }
    }

    private static func title(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return L("history.today") }
        if cal.isDateInYesterday(day) { return L("history.yesterday") }
        return day.formatted(.dateTime.month().day().weekday().locale(LocalizationOverride.locale))
    }
}

private func timeString(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(LocalizationOverride.locale))
}

// MARK: - List row

private struct ListRow: View {
    let record: HistoryRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ActionIcon(record: record, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(record.title).fontWeight(.semibold).lineLimit(1)
                    StatusPillForStatus(record: record)
                    Spacer(minLength: 4)
                    Text(timeString(record.createdAt)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(oneLine(record.input))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("→ " + oneLine(record.summary))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

private struct RecordDetail: View {
    let record: HistoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ActionIcon(record: record, size: 28)
                    Text(record.title).font(.system(size: 16, weight: .semibold))
                    StatusPillForStatus(record: record)
                    DeliveryPill(record: record)
                    Spacer()
                }
                MetaLine(record: record)
            }
            OutcomeView(record: record)
            Divider().padding(.top, 2)
            CopyButtons(record: record)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How each kind of result is drawn. Keyed by what the run produced — a
/// translation from a model and one from macOS are both text — so a new kind
/// of action that produces text needs nothing here.
private struct OutcomeView: View {
    let record: HistoryRecord

    var body: some View {
        switch record.typedOutcome {
        case .text:
            let text = record.output ?? ""
            original
            if record.extras["style"] == "compare", record.typedStatus == .ok {
                TextBox(caption: L("history.diff")) {
                    Text(InlineDiff.attributed(record.input, text))
                        .font(.system(size: 13)).lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                TextBox(caption: L(record.typedStatus == .cancelled ? "history.result.partial" : "history.result"),
                        note: record.extras["outputTruncated"] == "true" ? L("history.truncated") : nil) {
                    RecordText(text, mono: record.extras["style"] == "mono")
                }
            }

        case .message:
            original
            TextBox(caption: L(record.isError ? "history.error" : "history.result"),
                    tint: record.isError ? .red : nil) {
                RecordText(record.output ?? "")
            }

        case .link:
            original
            TextBox(caption: L(record.extras["target"] == "preview" ? "history.link.preview" : "history.link.browser")) {
                InfoRow(symbol: "globe", title: record.siteName, subtitle: record.displayURL)
            }

        case .file:
            let path = record.output ?? ""
            let exists = FileManager.default.fileExists(atPath: path)
            TextBox(caption: L("history.file")) {
                InfoRow(symbol: record.extras["isDirectory"] == "true" ? "folder" : "doc",
                        title: (path as NSString).lastPathComponent,
                        subtitle: (path as NSString).abbreviatingWithTildeInPath) {
                    StatusPill(text: L(exists ? "history.file.exists" : "history.file.missing"),
                               color: exists ? .green : .red)
                }
            }

        case .speech:
            SpeechOutcome(record: record)

        case .silent:
            original
            TextBox(caption: L("history.result")) {
                Text(record.silentNote).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case nil:
            // Written by a newer build, in a shape this one cannot draw: show
            // what is there, as stored.
            original
            TextBox(caption: String(format: L("history.unknown"), record.outcomeType)) {
                RecordText(([record.output].compactMap { $0 }
                            + record.extras.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
                    .joined(separator: "\n"), mono: true)
            }
        }
    }

    private var original: some View {
        TextBox(caption: L("history.input"), note: record.inputTruncated ? L("history.truncated") : nil) {
            RecordText(record.input)
        }
    }
}

// MARK: - Read aloud again

/// A read-aloud record: the text, and its reader with a button that reads it
/// again. While it reads, the text box IS the reading window — the same pieces
/// the popup's reading window is built from (`ReadingText`, `ReadingStatus`,
/// …), so the spoken word is highlighted, slides and stays in view, in the
/// highlight style and text size chosen in settings, exactly as there.
///
/// The same reader and text find the earlier read in the speech cache, so a
/// replay is played locally and costs nothing; once the cache has dropped it,
/// the reader is asked again.
private struct SpeechOutcome: View {
    let record: HistoryRecord
    /// Made when the record is shown and started only by Play, so the text sits
    /// in the reading window from the start.
    @StateObject private var playback: SpeechPlayback

    init(record: HistoryRecord) {
        self.record = record
        _playback = StateObject(wrappedValue: SpeechPlayback(text: record.input, reader: Self.reader(for: record)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextBox(caption: L("history.input"), note: record.inputTruncated ? L("history.truncated") : nil) {
                VStack(alignment: .leading, spacing: 8) {
                    HistoryReadingWindow(playback: playback)
                    // History keeps more text than a single read can speak.
                    if playback.wasTruncated {
                        Divider()
                        DisclosureGroup(L("history.input.full")) {
                            RecordText(record.input).padding(.top, 4)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            TextBox(caption: L("history.speech")) {
                InfoRow(symbol: "speaker.wave.2.fill", title: record.extras["reader"] ?? playback.reader.name,
                        subtitle: subtitle)
            }
        }
        // Moving to another record stops the read, as closing the popup does.
        .onDisappear { SpeechCenter.shared.stop(playback) }
    }

    private var subtitle: String {
        // That reader is gone: say who reads it instead.
        if readerIsGone { return String(format: L("history.speech.instead"), playback.reader.name) }
        return L("history.speech.done")
    }

    /// Whether the run's reader no longer exists. Decided by id when the record
    /// has one — a reader renamed since, or the system voice named in another
    /// language, is still the same reader.
    private var readerIsGone: Bool {
        let readers = SpeechSettingsStore.shared.allReaders
        if let id = record.extras["readerID"] { return !readers.contains { $0.id == id } }
        if let name = record.extras["reader"] { return !readers.contains { $0.name == name } }
        return false
    }

    /// The reader the run used — by id, or by name for a record made before ids
    /// were stored — else today's default reader.
    private static func reader(for record: HistoryRecord) -> SpeechReader {
        let store = SpeechSettingsStore.shared
        if let id = record.extras["readerID"], let r = store.allReaders.first(where: { $0.id == id }) { return r }
        if let name = record.extras["reader"], let r = store.allReaders.first(where: { $0.name == name }) { return r }
        return store.resolve(nil)
    }
}

/// The popup's reading window, inside the History page's text box: the same
/// toolbar controls, status and highlighted text. No pin and no close — it is
/// part of the record, not a window of its own.
private struct HistoryReadingWindow: View {
    @ObservedObject var playback: SpeechPlayback
    @State private var width: CGFloat = 0
    @State private var contentHeight: CGFloat?

    /// Tall enough for the whole text up to this, then it scrolls (and keeps
    /// the line being read in view).
    private static let maxHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ReadingReaderLabel(playback: playback)
                Spacer()
                ReadingPlaybackButtons(playback: playback)
                CopyButton {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(playback.text, forType: .string)
                }
            }
            if ReadingStatus.hasContent(playback) {
                ReadingStatus(playback: playback)
            }
            if width > 0 {
                ReadingText(playback: playback, width: width,
                            height: min(contentHeight ?? 20, Self.maxHeight),
                            fontSize: PopBarPreferences.resultFontSize,
                            style: PopBarPreferences.readingHighlight,
                            onMeasuredHeight: { contentHeight = $0 })
            }
        }
        // The text needs a definite width to place the highlight and find the
        // line being read: the box's own width, measured behind it.
        .background(GeometryReader { geo in
            Color.clear.onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { width = $0 }
        })
    }
}

/// The original and the result as ONE text: what was removed struck through in
/// red, what was added in green, everything else as it reads. Computed when
/// shown, never stored.
enum InlineDiff {
    static func attributed(_ original: String, _ revised: String) -> AttributedString {
        let a = TextDiff.tokens(original), b = TextDiff.tokens(revised)
        // Same ceiling as the popup's comparison: past it, the diff would
        // stall the window, so the result is shown unmarked.
        guard a.count + b.count <= TextDiff.maxTokens else { return AttributedString(revised) }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out = AttributedString()
        func add(_ s: String, _ mark: Bool?) {
            var run = AttributedString(s)
            if mark == false {
                run.foregroundColor = Color(nsColor: .systemRed)
                run.backgroundColor = Color(nsColor: .systemRed).opacity(0.14)
                run.strikethroughStyle = .single
            } else if mark == true {
                run.backgroundColor = Color(nsColor: .systemGreen).opacity(0.26)
            }
            out += run
        }
        // Removals come before insertions at the same spot, so a replaced
        // word reads old-then-new.
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { add(a[i], false); i += 1 }
            else if j < b.count, inserted.contains(j) { add(b[j], true); j += 1 }
            else if i < a.count { add(a[i], nil); i += 1; j += 1 }
            else { j += 1 }
        }
        return out
    }
}

// MARK: - Pieces

private struct RecordText: View {
    let text: String
    var mono = false
    init(_ text: String, mono: Bool = false) { self.text = text; self.mono = mono }

    var body: some View {
        Text(text)
            .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TextBox<Content: View>: View {
    var caption: String?
    var note: String?
    var tint: Color?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if caption != nil || note != nil {
                HStack(spacing: 6) {
                    if let caption {
                        Text(caption).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    if let note {
                        Text(note).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
            }
            content
                .padding(.horizontal, 11).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.map { $0.opacity(0.10) } ?? Color(nsColor: .textBackgroundColor).opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.45) } ?? Color(nsColor: .separatorColor)))
        }
    }
}

private struct InfoRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(subtitle)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 6)
            trailing
        }
    }
}

extension InfoRow where Trailing == EmptyView {
    init(symbol: String, title: String, subtitle: String) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}

private struct ActionIcon: View {
    let record: HistoryRecord
    let size: CGFloat

    var body: some View {
        let color = record.actionColor
        Image(systemName: record.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(
                LinearGradient(colors: [color, color.opacity(0.72)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)))
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
            .fixedSize()
    }
}

/// Failed, or stopped before it finished.
private struct StatusPillForStatus: View {
    let record: HistoryRecord
    var body: some View {
        switch record.typedStatus {
        case .error:     StatusPill(text: L("history.status.error"), color: .red)
        case .cancelled: StatusPill(text: L("history.status.cancelled"), color: .orange)
        case .ok:        EmptyView()
        }
    }
}

/// What became of a result meant for the document or the clipboard.
private struct DeliveryPill: View {
    let record: HistoryRecord
    var body: some View {
        switch record.typedDelivered {
        case .replaced, .pasted:
            StatusPill(text: L(record.deliverMode == ActionOutput.append.rawValue
                               ? "history.delivered.appended" : "history.delivered.replaced"), color: .green)
        case .copied:
            StatusPill(text: L("history.delivered.copied"), color: .green)
        case .failed:
            StatusPill(text: L("history.delivered.failed"), color: .orange)
        case nil:
            EmptyView()
        }
    }
}

/// When, from which app (with its icon), how it was triggered, which model,
/// how long.
private struct MetaLine: View {
    let record: HistoryRecord

    var body: some View {
        let trigger: String? = {
            switch record.typedTrigger {
            case .selection: return L("history.trigger.selection")
            case .hotkey:    return L("history.trigger.hotkey")
            case .ocr:       return L("history.trigger.ocr")
            case nil:        return nil
            }
        }()
        var after = [String]()
        if let trigger { after.append(trigger) }
        if let engine = record.engine { after.append(engine) }
        if let ms = record.durationMs { after.append(String(format: L("history.seconds.format"), Double(ms) / 1000)) }

        // Wraps onto a second line rather than cutting a long model name short.
        return FlowLayout(spacing: 6, lineSpacing: 3) {
            Text(record.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(LocalizationOverride.locale)))
            if let id = record.appBundleID {
                HStack(spacing: 4) {
                    dot
                    Text(L("history.from"))
                    Image(nsImage: AppIcons.icon(for: id, size: 16))
                    Text(record.appName ?? id)
                }
            }
            ForEach(after, id: \.self) { part in
                HStack(spacing: 6) { dot; Text(part) }
            }
        }
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
    }

    private var dot: some View { Text(verbatim: "·").foregroundStyle(.tertiary) }
}

private struct CopyButtons: View {
    let record: HistoryRecord
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(record.copyables.enumerated()), id: \.offset) { i, item in
                HistoryCopyButton(label: item.label, text: item.text, primary: i == 0)
            }
            Spacer()
        }
    }
}

/// Copies, and says so for a moment in its own label.
private struct HistoryCopyButton: View {
    let label: String
    let text: String
    let primary: Bool
    @State private var copied = false

    var body: some View {
        let button = Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            Label(copied ? L("history.copied") : label,
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
        }
        .controlSize(.small)
        if primary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// Lays its children out left to right, starting a new line when the next one
/// does not fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        // The rows' own width, never the proposal: a proposal can be infinite.
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [(Int, CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
            rows[rows.count - 1] = row
        }
        return rows
    }
}

private func oneLine(_ s: String) -> String {
    s.split(whereSeparator: \.isNewline).joined(separator: " ")
}
