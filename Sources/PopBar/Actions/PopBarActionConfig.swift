import Foundation

/// What running an action *presents* — the open-ended output axis. An action's job
/// is to produce one of these; the session's `present(_:)` routes each case to its
/// surface (nothing / the result panel / the web-preview window). Adding a future
/// output type (e.g. `case markdownPreview(String)`, `case image(URL)`) is a new
/// case here + one routing branch — the action-execution and selection layers don't
/// change.
enum PopBarPresentation {
    /// No UI — just dismiss (e.g. Copy).
    case none
    /// A text/Markdown page in the popup panel that is a report about the
    /// selection rather than a result made from it (a character count).
    case result(String)
    /// The action failed; the message says why. Shown exactly like `result` —
    /// kept apart so the run is known to have failed (the History page marks it).
    case error(String)
    /// The selection's associated link, in the floating mini-browser.
    case webPreview(URL)
    /// A local file, in the floating Quick Look window.
    case quickLook(URL)
    /// A local path, shown in Finder. A folder opens in place; a file is revealed
    /// and selected inside its parent — two different `NSWorkspace` calls, so the
    /// flag is carried here rather than re-checked on disk at present time.
    case revealInFinder(URL, isDirectory: Bool)
    /// Text an action PRODUCED (an AI answer, a transform, a shortcut's output),
    /// as opposed to a message about it. Where it goes — the panel, in place of
    /// the selection, after it, or the clipboard — is the action's `output`, so
    /// the session routes it, not the action.
    case output(String)
    /// A URL for another app to open: the browser, the dictionary, Obsidian…
    case openExternal(URL)
    /// Read the text aloud (or stop reading, if something already is).
    case speak(String)
    /// Pause the popup, exactly as the menu bar's Pause does.
    case pause
    /// Show what the selection's element is to the accessibility API.
    case inspect
    /// Open the app's settings window.
    case openSettings
}

/// Where an action's produced text goes. Stored as a string on the action (see
/// `PopBarActionConfig.output`), so a value added by a newer build survives an
/// older one rewriting the file; an unknown value behaves as `.panel`.
enum ActionOutput: String, CaseIterable {
    /// Shown in the result panel, which offers a Replace button when the
    /// selection can take one. The default: nothing is written into a document
    /// unless the action says so.
    case panel
    /// Shown in the result panel as the selection above the result, with what was
    /// removed and what was added marked, so a rewrite is checked before Replace
    /// puts it in place (issue #12). The panel can also show the result alone.
    case compare
    /// Put in place of the selection.
    case replace
    /// Put after the selection, which is kept.
    case append
    /// Put on the clipboard; nothing is shown.
    case copy
}

/// Where the `openURL` kind opens its page. Stored as a string, like `output`.
enum OpenURLTarget: String, CaseIterable {
    /// The default browser — or, for a non-web scheme (`dict://`, `obsidian://`),
    /// whatever app owns that scheme.
    case browser
    /// The popup's own floating mini-browser. Web pages only.
    case preview
}

/// Optional per-action model override. The API key is resolved per-provider from
/// the Keychain, so an override only names provider / model / thinking — you set
/// each provider's key once in settings and any action can use it.
struct ModelOverride: Codable, Equatable {
    var provider: String
    var model: String
    var reasoningEffort: String
}

/// A user-configurable capsule action, persisted as JSON. The list is fully
/// editable (add / edit / delete / reorder); the defaults below are just the
/// initial seed.
struct PopBarActionConfig: Codable, Identifiable, Equatable {

    enum Kind: String, Codable {
        case copy           // local: write the selection to the clipboard
        case ai             // send `prompt` + the selection to a model
        case webPreview     // local: open the selection's associated link in the mini-browser
        case quickLook      // local: Quick Look the selected path (folders open in Finder)
        case revealInFinder // local: show the selected path in Finder
        case openURL        // local: fill `url`'s {text} with the selection and open it
        case speak          // read the selection aloud with a reader (system voice or a cloud TTS)
        case transform      // local: a `TextTransform` named by `op`
        case shortcut       // run the macOS Shortcut named `shortcut` on the selection
        case script         // run the shell command `script` on the selection
        case systemTranslate // local: macOS's on-device translator (macOS 15+), no model
        case pause          // pause the popup, like the menu bar's Pause (the selection is ignored)
        case inspect        // debug: show the selection's accessibility element and its path
        case settings       // open the app's settings window (the selection is ignored)
        /// A GROUP: runs nothing itself, it only holds `children`. On the wheel it
        /// unfolds a second ring; in the capsule it opens a dropdown.
        case group
    }

    var schemaVersion: Int
    var id: String
    var title: String
    var iconSymbol: String
    var kind: Kind
    /// System prompt (used when `kind == .ai`).
    var prompt: String
    /// nil = use the global default model.
    var modelOverride: ModelOverride?

    // Kind-specific parameters. Flat, like `prompt`, and each one optional so it
    // is only written for the kind that uses it. The ones with a fixed set of
    // values (`openIn`, `op`, `output`) are held as the RAW STRING rather than an
    // enum: once a key is known to this build, `extra` no longer protects its
    // value, and decoding an enum would drop or rewrite a value a newer build
    // wrote — the same trap `unsupportedKindRaw` exists for.

    /// `openURL`: the address, with `{text}` standing for the selection
    /// (encoded as one query value).
    var url: String?
    /// `openURL`: an `OpenURLTarget` raw value. nil = browser.
    var openIn: String?
    /// `transform`: a `TextTransform` raw value.
    var op: String?
    /// `shortcut`: the name of the Shortcut to run.
    var shortcut: String?
    /// `script`: a shell command, run by the user's login shell with the
    /// selection on standard input.
    var script: String?
    /// `speak`: the id of the reader to use (`SpeechSettingsStore`). nil = the
    /// default reader chosen in settings.
    var reader: String?
    /// `systemTranslate`: the language to translate into, as the system names
    /// it ("zh", "zh-TW", "en-GB"). Chosen by the user; nil until they do.
    var targetLanguage: String?
    /// `ai`, `transform`, `shortcut`, `script`, `systemTranslate`: an `ActionOutput` raw value.
    /// nil = the panel.
    var output: String?

    /// Where this action's produced text goes. `count` is a report about the
    /// selection, never a stand-in for it, so it always goes to the panel.
    var outputMode: ActionOutput {
        if kind == .transform, op == TextTransform.count.rawValue { return .panel }
        return output.flatMap(ActionOutput.init(rawValue:)) ?? .panel
    }

    /// Whether this kind produces text that `output` applies to.
    var hasOutput: Bool { [.ai, .transform, .shortcut, .script, .systemTranslate].contains(kind) }

    var openTarget: OpenURLTarget { openIn.flatMap(OpenURLTarget.init(rawValue:)) ?? .browser }

    /// Sub-actions, shown on the wheel's second ring when this one is hovered.
    /// Empty = an ordinary action.
    ///
    /// Exactly ONE level deep, by design and by enforcement: a child's own
    /// children are dropped on decode. The wheel can draw two rings and no more, so
    /// a deeper file (hand-edited, or written by some future build) degrades to
    /// something this UI can actually show instead of silently hiding actions.
    var children: [PopBarActionConfig] = []

    /// A group: it holds sub-actions instead of doing anything itself.
    var hasChildren: Bool { !children.isEmpty }

    /// The literal `kind` string from disk when THIS build does not recognise it —
    /// i.e. the action was written by a newer build. Nil for every kind this
    /// build understands.
    ///
    /// It exists so an older build cannot destroy a newer one's actions. The
    /// released app and a dev build read the SAME `popbar-actions.json` (it is not
    /// scoped by bundle id), so the older one routinely loads kinds it has never
    /// heard of. Decoding those as `.ai` is fine — there is nothing else it could
    /// do — but the *synthesised* encoder would then write `"kind":"ai"` back on
    /// the very next save, so reordering or editing an unrelated action would
    /// silently and permanently rewrite the newer ones. Round-tripping the
    /// original string means a save leaves them exactly as they were found.
    private var unsupportedKindRaw: String?

    /// Written by a newer build than this one, so it cannot be run here.
    var isUnsupported: Bool { unsupportedKindRaw != nil }

    /// Every key found on this action that this build does not know about.
    ///
    /// Same purpose as `unsupportedKindRaw`, generalized from one field to all of
    /// them. The actions live in a config file people edit by hand, and the rest
    /// of that file preserves unknown keys by being held as a JSON tree — but an
    /// action is decoded into THIS struct, so without somewhere to keep them, a
    /// key a newer build (or the user) put on an action would be dropped the next
    /// time anything in the list was edited, reordered or deleted.
    private var extra: [String: JSONValue] = [:]

    init(id: String = UUID().uuidString, title: String, iconSymbol: String,
         kind: Kind, prompt: String = "", modelOverride: ModelOverride? = nil) {
        self.schemaVersion = 1
        self.id = id
        self.title = title
        self.iconSymbol = iconSymbol
        self.kind = kind
        self.prompt = prompt
        self.modelOverride = modelOverride
        self.unsupportedKindRaw = nil
    }

    /// An unsupported action decodes as `.ai`, but it must not be RUN as one —
    /// it has no prompt and was never meant for the model.
    var isAI: Bool { kind == .ai && !isUnsupported }
    var isWebPreview: Bool { kind == .webPreview }
    /// Acts on a local file/folder named by the selection (`PathResolver`).
    var isPathAction: Bool { kind == .quickLook || kind == .revealInFinder }

    // Forward-compatible decode: tolerate older/newer payloads missing fields.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, title, iconSymbol, kind, prompt, modelOverride, children
        case url, openIn, op, shortcut, script, output, reader, targetLanguage
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        iconSymbol = (try? c.decode(String.self, forKey: .iconSymbol)) ?? "sparkles"
        let rawKind = try? c.decode(String.self, forKey: .kind)
        let knownKind = rawKind.flatMap(Kind.init(rawValue:))
        kind = knownKind ?? .ai
        // Only a kind that was PRESENT but unreadable came from a newer build. A
        // MISSING one is just an old or partial record, and stays a plain AI
        // action exactly as it always did.
        unsupportedKindRaw = (knownKind == nil) ? rawKind : nil
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        modelOverride = try? c.decodeIfPresent(ModelOverride.self, forKey: .modelOverride)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        openIn = try? c.decodeIfPresent(String.self, forKey: .openIn)
        op = try? c.decodeIfPresent(String.self, forKey: .op)
        shortcut = try? c.decodeIfPresent(String.self, forKey: .shortcut)
        script = try? c.decodeIfPresent(String.self, forKey: .script)
        output = try? c.decodeIfPresent(String.self, forKey: .output)
        reader = try? c.decodeIfPresent(String.self, forKey: .reader)
        targetLanguage = try? c.decodeIfPresent(String.self, forKey: .targetLanguage)
        // Flatten anything deeper than one level (see `children`). Decoding is
        // deliberately lenient here for the same reason every other field is: a
        // malformed children array must not throw away the whole action list.
        let decodedChildren = (try? c.decode([PopBarActionConfig].self, forKey: .children)) ?? []
        children = decodedChildren.map { child in
            var flat = child
            flat.children = []
            return flat
        }

        // Anything else the object carried. Read through a container keyed by a
        // key type that accepts any string, minus the fields above.
        if let any = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var found: [String: JSONValue] = [:]
            for key in any.allKeys where !Self.knownKeys.contains(key.stringValue) {
                if let value = try? any.decode(JSONValue.self, forKey: key) {
                    found[key.stringValue] = value
                }
            }
            extra = found
        }
    }

    /// Hand-written ONLY so `kind` can round-trip a value this build does not
    /// recognise (see `unsupportedKindRaw`). Every other field is encoded exactly
    /// as the synthesised version would.
    func encode(to encoder: Encoder) throws {
        // One container for both the known fields and `extra`, keyed by a type
        // that accepts any string — asking the same encoder for a second keyed
        // container of a different key type is a trick that works until it does
        // not, and there is nothing to gain from it here.
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        func key(_ k: CodingKeys) -> AnyCodingKey { AnyCodingKey(k.stringValue) }

        try c.encode(schemaVersion, forKey: key(.schemaVersion))
        try c.encode(id, forKey: key(.id))
        try c.encode(title, forKey: key(.title))
        try c.encode(iconSymbol, forKey: key(.iconSymbol))
        try c.encode(unsupportedKindRaw ?? kind.rawValue, forKey: key(.kind))
        // Only an action that has a prompt writes one: a Speak or Search action
        // carrying `"prompt": ""` is noise in a file people read. Decoding already
        // treats a missing prompt as empty, so nothing is lost.
        if !prompt.isEmpty { try c.encode(prompt, forKey: key(.prompt)) }
        try c.encodeIfPresent(modelOverride, forKey: key(.modelOverride))
        try c.encodeIfPresent(url, forKey: key(.url))
        try c.encodeIfPresent(openIn, forKey: key(.openIn))
        try c.encodeIfPresent(op, forKey: key(.op))
        try c.encodeIfPresent(shortcut, forKey: key(.shortcut))
        try c.encodeIfPresent(script, forKey: key(.script))
        try c.encodeIfPresent(output, forKey: key(.output))
        try c.encodeIfPresent(reader, forKey: key(.reader))
        try c.encodeIfPresent(targetLanguage, forKey: key(.targetLanguage))
        // Only written when there is something to write, so an action that never
        // had children does not grow an empty array.
        if !children.isEmpty { try c.encode(children, forKey: key(.children)) }

        // Written last, and never allowed to shadow a field this build owns.
        for (name, value) in extra.sorted(by: { $0.key < $1.key })
        where !Self.knownKeys.contains(name) {
            try c.encode(value, forKey: AnyCodingKey(name))
        }
    }
}

/// Default system prompts + the seed action set (localized titles at seed time;
/// thereafter they are user-editable free text).
enum DefaultActions {

    static let translatePrompt = """
    You are a translation engine. Detect the language of the user's text: if it is \
    Chinese, translate it into natural English; otherwise translate it into natural \
    Simplified Chinese. Preserve technical terminology, numbers, units and citation \
    markers exactly. Output ONLY the translation, with no quotes, labels, or explanation.
    """

    static let polishPrompt = """
    You are an academic writing editor. Rewrite the user's text to be clearer, more \
    fluent and more appropriate for a research paper, preserving its original language \
    and meaning. Keep every technical term, datum, number, citation and reference \
    unchanged; do not add or remove claims. Output ONLY the polished text, with no \
    quotes, labels, or explanation.
    """

    static let explainPrompt = """
    You are a concise explainer. Explain the meaning of the user's selected text (and \
    any notable technical terms or context) in plain language, in 2-4 sentences. \
    Respond in the same language as the text. Output ONLY the explanation.
    """

    static let literaturePrompt = """
    You are a research assistant reading an academic passage. Summarize what the \
    passage says, explain its method and argument, and highlight any limitations. \
    Clearly separate what is stated in the text from your own inferences, and mark \
    inferences as such. Do NOT invent citations, references, numbers or facts that \
    are not present in the text. Respond in the same language as the text.
    """

    static let abstractPrompt = """
    Extract a concise abstract from the user's text: one sentence of background, the \
    main objective, the method, the key findings and the conclusion. Keep only facts \
    present in the text and do not invent numbers. Respond in the same language as the \
    text. Output ONLY the summary.
    """

    static func seed() -> [PopBarActionConfig] {
        [
            PopBarActionConfig(title: L("popbar.action.translate"), iconSymbol: "character.bubble",
                               kind: .ai, prompt: translatePrompt),
            PopBarActionConfig(title: L("popbar.action.explain"), iconSymbol: "lightbulb",
                               kind: .ai, prompt: explainPrompt),
            PopBarActionConfig(title: L("popbar.action.literature"), iconSymbol: "graduationcap",
                               kind: .ai, prompt: literaturePrompt),
            polishAction(),
            PopBarActionConfig(title: L("popbar.action.abstract"), iconSymbol: "text.quote",
                               kind: .ai, prompt: abstractPrompt),
            PopBarActionConfig(title: L("popbar.action.copy"), iconSymbol: "doc.on.doc",
                               kind: .copy),
        ]
    }

    /// Polish rewrites the selection, so it shows what it changed before Replace
    /// puts it in place (issue #12).
    static func polishAction() -> PopBarActionConfig {
        var a = PopBarActionConfig(title: L("popbar.action.polish"), iconSymbol: "wand.and.stars",
                                   kind: .ai, prompt: polishPrompt)
        a.output = ActionOutput.compare.rawValue
        return a
    }

    /// The seed's "Tools" group: actions used less often than the ring's own,
    /// folded together so they take one slot, not three. Only changes what a
    /// fresh config starts with; saved actions are the user's and stay as they are.
    static func toolsGroup() -> PopBarActionConfig {
        var group = PopBarActionConfig(title: L("popbar.action.tools"), iconSymbol: "wrench.and.screwdriver", kind: .group)
        group.children = [webPreviewAction(), settingsAction(), chatGPTAction()]
        return group
    }

    /// Open ChatGPT with the selection as the question — the "Ask ChatGPT"
    /// template, titled by the brand alone so it fits a ring slot in any language.
    static func chatGPTAction() -> PopBarActionConfig {
        openURL("ChatGPT", "bubble.left.and.bubble.right", "https://chatgpt.com/?q={text}")
    }

    /// The seed / migration "Web Preview" action.
    static func webPreviewAction() -> PopBarActionConfig {
        PopBarActionConfig(title: L("popbar.action.webpreview"), iconSymbol: "safari", kind: .webPreview)
    }

    /// Search the web for the selection, in the default browser.
    static func searchAction() -> PopBarActionConfig {
        openURL(L("popbar.action.search"), "magnifyingglass", "https://www.google.com/search?q={text}")
    }

    /// Read the selection aloud.
    static func speakAction() -> PopBarActionConfig {
        PopBarActionConfig(title: L("popbar.action.speak"), iconSymbol: "speaker.wave.2.fill", kind: .speak)
    }

    /// Translate with macOS's own translator. From the templates, on macOS 15+.
    /// No target language: the user picks one before it can be saved.
    static func systemTranslateAction() -> PopBarActionConfig {
        PopBarActionConfig(title: L("template.systemTranslate"), iconSymbol: "translate", kind: .systemTranslate)
    }

    /// Pause the popup from the popup itself. Not in the seed: it is there for
    /// whoever wants a one-tap pause on their ring, from the templates.
    static func pauseAction() -> PopBarActionConfig {
        PopBarActionConfig(title: String(format: L("menu.pause.format"), Brand.name),
                           iconSymbol: "pause.circle", kind: .pause)
    }

    /// A debugging aid, from the templates: what the element holding the
    /// selection is and where it sits — what an ignore rule would match on.
    static func inspectAction() -> PopBarActionConfig {
        PopBarActionConfig(title: L("template.inspect"), iconSymbol: "scope", kind: .inspect)
    }

    /// Open the settings window from the ring or capsule. From the templates.
    static func settingsAction() -> PopBarActionConfig {
        PopBarActionConfig(title: L("template.settings"), iconSymbol: "gearshape", kind: .settings)
    }

    // MARK: - Builders

    static func openURL(_ title: String, _ icon: String, _ url: String,
                        in target: OpenURLTarget = .browser) -> PopBarActionConfig {
        var a = PopBarActionConfig(title: title, iconSymbol: icon, kind: .openURL)
        a.url = url
        if target != .browser { a.openIn = target.rawValue }
        return a
    }

    static func transform(_ title: String, _ icon: String, _ op: TextTransform) -> PopBarActionConfig {
        var a = PopBarActionConfig(title: title, iconSymbol: icon, kind: .transform)
        a.op = op.rawValue
        // A transform's result stands in for the selection, so the template puts
        // it there. The kind itself defaults to the panel (see `output`): a
        // hand-written transform never writes into a document by omission.
        if op.producesReplacement { a.output = ActionOutput.replace.rawValue }
        return a
    }

    static func ai(_ title: String, _ icon: String, _ prompt: String) -> PopBarActionConfig {
        PopBarActionConfig(title: title, iconSymbol: icon, kind: .ai, prompt: prompt)
    }
}

/// Ready-made actions the user adds from Settings → Actions → Add from Template.
/// Each is an ordinary action config, opened in the editor so it can be adjusted
/// before it is saved — there is no separate template format.
enum ActionTemplates {

    struct Section: Identifiable {
        let id: String
        let title: String
        let actions: [PopBarActionConfig]
    }

    static func sections() -> [Section] {
        [
            Section(id: "ai", title: L("template.section.ai"), actions: [
                DefaultActions.ai(L("template.summarize"), "text.quote", Prompts.summarize),
                DefaultActions.ai(L("template.grammar"), "text.badge.checkmark", Prompts.grammar),
                toneGroup(),
                DefaultActions.ai(L("template.analyze"), "graduationcap", Prompts.analyze),
                DefaultActions.ai(L("template.explainCode"), "chevron.left.forwardslash.chevron.right", Prompts.explainCode),
            ]),
            Section(id: "text", title: L("template.section.text"), actions: systemTranslateTemplates() + [
                DefaultActions.transform(L("transform.uppercase"), "textformat.size.larger", .uppercase),
                DefaultActions.transform(L("transform.lowercase"), "textformat.size.smaller", .lowercase),
                DefaultActions.transform(L("transform.titleCase"), "textformat", .titleCase),
                DefaultActions.transform(L("transform.sentenceCase"), "textformat.abc", .sentenceCase),
                DefaultActions.transform(L("transform.camelCase"), "textformat.alt", .camelCase),
                DefaultActions.transform(L("transform.snakeCase"), "textformat.alt", .snakeCase),
                DefaultActions.transform(L("transform.kebabCase"), "textformat.alt", .kebabCase),
                DefaultActions.transform(L("transform.joinLines"), "text.append", .joinLines),
                DefaultActions.transform(L("transform.trim"), "scissors", .trim),
                DefaultActions.transform(L("transform.sortLines"), "arrow.up.arrow.down", .sortLines),
                DefaultActions.transform(L("transform.uniqueLines"), "list.bullet", .uniqueLines),
                DefaultActions.transform(L("transform.reverseLines"), "arrow.up.arrow.down", .reverseLines),
                DefaultActions.transform(L("transform.toSimplified"), "character.zh", .toSimplified),
                DefaultActions.transform(L("transform.toTraditional"), "character.zh", .toTraditional),
                DefaultActions.transform(L("transform.pinyin"), "abc", .pinyin),
                DefaultActions.transform(L("transform.spaceCJK"), "text.word.spacing", .spaceCJK),
                DefaultActions.transform(L("transform.jsonPretty"), "curlybraces", .jsonPretty),
                DefaultActions.transform(L("transform.jsonMinify"), "curlybraces.square", .jsonMinify),
                DefaultActions.transform(L("transform.urlEncode"), "percent", .urlEncode),
                DefaultActions.transform(L("transform.urlDecode"), "percent", .urlDecode),
                DefaultActions.transform(L("transform.cleanURL"), "link", .cleanURL),
                DefaultActions.transform(L("transform.count"), "number", .count),
            ]),
            Section(id: "web", title: L("template.section.web"), actions: [
                DefaultActions.openURL("Google", "magnifyingglass", "https://www.google.com/search?q={text}"),
                DefaultActions.openURL(L("template.baidu"), "magnifyingglass", "https://www.baidu.com/s?wd={text}"),
                DefaultActions.openURL("Bing", "magnifyingglass", "https://www.bing.com/search?q={text}"),
                DefaultActions.openURL("DuckDuckGo", "magnifyingglass", "https://duckduckgo.com/?q={text}"),
                DefaultActions.openURL("Kagi", "magnifyingglass", "https://kagi.com/search?q={text}"),
                DefaultActions.openURL(L("template.wikipedia"), "book", "https://en.wikipedia.org/w/index.php?search={text}"),
                DefaultActions.openURL("GitHub", "chevron.left.forwardslash.chevron.right", "https://github.com/search?q={text}"),
                DefaultActions.openURL(L("template.dictionary"), "character.book.closed", "dict://{text}"),
                DefaultActions.openURL(L("template.maps"), "map", "maps://?q={text}"),
                DefaultActions.openURL(L("template.chatgpt"), "bubble.left.and.bubble.right", "https://chatgpt.com/?q={text}"),
                DefaultActions.openURL(L("template.claude"), "bubble.left.and.bubble.right", "https://claude.ai/new?q={text}"),
                DefaultActions.openURL(L("template.obsidian"), "note.text.badge.plus", "obsidian://new?content={text}"),
            ]),
            Section(id: "automation", title: L("template.section.automation"), actions: [
                DefaultActions.speakAction(),
                shortcutTemplate(),
                scriptTemplate(),
                DefaultActions.pauseAction(),
                DefaultActions.inspectAction(),
                DefaultActions.settingsAction(),
            ]),
        ]
    }

    /// Offered only where the kind can run: macOS 13/14 have no API that hands
    /// a translation back to the app.
    private static func systemTranslateTemplates() -> [PopBarActionConfig] {
        if #available(macOS 15.0, *) { return [DefaultActions.systemTranslateAction()] }
        return []
    }

    private static func toneGroup() -> PopBarActionConfig {
        var group = PopBarActionConfig(title: L("template.tone"), iconSymbol: "textformat.alt", kind: .group)
        group.children = [
            DefaultActions.ai(L("template.tone.formal"), "checkmark.seal", Prompts.formal),
            DefaultActions.ai(L("template.tone.casual"), "text.bubble", Prompts.casual),
            DefaultActions.ai(L("template.tone.concise"), "scissors", Prompts.concise),
        ]
        return group
    }

    private static func shortcutTemplate() -> PopBarActionConfig {
        var a = PopBarActionConfig(title: L("template.shortcut"), iconSymbol: "command", kind: .shortcut)
        a.shortcut = ""
        return a
    }

    private static func scriptTemplate() -> PopBarActionConfig {
        var a = PopBarActionConfig(title: L("template.script"), iconSymbol: "terminal", kind: .script)
        // A harmless example that shows the contract: the selection arrives on
        // standard input, whatever is printed comes back.
        a.script = "tr '[:lower:]' '[:upper:]'"
        return a
    }

    enum Prompts {
        static let summarize = """
        Summarize the user's text as a few short bullet points that keep every key fact. \
        Respond in the same language as the text. Output ONLY the summary.
        """
        static let grammar = """
        Correct the spelling, grammar and punctuation of the user's text. Change nothing \
        else — keep its wording, tone, language and formatting. Output ONLY the corrected text.
        """
        static let analyze = """
        The user is learning the language of the selected text. Break the sentence down: \
        its structure, the role of each part, and any idioms or grammar points worth \
        knowing. Explain in Simplified Chinese if the text is not Chinese, otherwise in English. \
        Be concise.
        """
        static let explainCode = """
        Explain what the user's code does, step by step, then point out any bugs or \
        risky spots. Be concise. Respond in the language the user most likely reads, \
        judging by any comments; default to English.
        """
        static let formal = """
        Rewrite the user's text in a formal, professional tone. Keep its language and \
        meaning. Output ONLY the rewritten text.
        """
        static let casual = """
        Rewrite the user's text in a friendly, casual tone. Keep its language and meaning. \
        Output ONLY the rewritten text.
        """
        static let concise = """
        Rewrite the user's text to be as short as possible without losing meaning. Keep \
        its language. Output ONLY the rewritten text.
        """
    }
}

/// Fills an `openURL` action's address with the selection.
///
/// `{text}` is replaced by the selection encoded as ONE query value: everything
/// outside `urlQueryAllowed` is escaped, and so are `& = + # ? /`, which would
/// otherwise change the query's structure. A space becomes `%20`. This is fixed
/// on purpose — changing it later would change what every saved template does.
enum URLTemplate {

    static let placeholder = "{text}"

    static let valueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?/")
        return set
    }()

    /// nil when the result is not a URL at all (an empty or malformed template).
    static func fill(_ template: String, with text: String) -> URL? {
        let value = text.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? ""
        let filled = template
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: placeholder, with: value)
        guard let url = URL(string: filled), url.scheme != nil else { return nil }
        return url
    }

    /// Whether a page at this URL can be shown in the popup's own mini-browser.
    /// Anything else (`dict:`, `obsidian:`, `mailto:`) belongs to another app.
    static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
