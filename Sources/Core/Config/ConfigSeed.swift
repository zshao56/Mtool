import Foundation

/// Builds the config file the first time there isn't one.
///
/// Two jobs. It writes out every setting WITH its default, rather than an empty
/// object, because a file you are meant to hand-edit should show you what there
/// is to edit — a schema tells an editor what is allowed, but only the file tells
/// a person what exists. And it carries across anything already in `UserDefaults`
/// and the old actions file, so turning on the config file does not silently
/// reset a configured app back to factory settings.
///
/// This runs once. After the file exists it is the only source of truth, and
/// `UserDefaults` keeps nothing but window frames and Sparkle's bookkeeping.
enum ConfigSeed {

    private static let log = FileLog("Config.Seed")

    static func initialDocument() -> JSONValue {
        let d = UserDefaults.standard
        var doc = JSONValue.object([:])

        // A relative reference: editors resolve it next to the config file, so the
        // schema is found whether or not the folder is symlinked somewhere else.
        doc.set(path: "$schema", to: "./config.schema.json")
        doc.set(path: "version", to: 1)

        func bool(_ path: String, _ key: String, default fallback: Bool) {
            doc.set(path: path, to: .bool(d.object(forKey: key) as? Bool ?? fallback))
        }
        func number(_ path: String, _ key: String, default fallback: Double) {
            let value = (d.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
            doc.set(path: path, to: .number(value))
        }
        func string(_ path: String, _ key: String, default fallback: String) {
            doc.set(path: path, to: .string(d.string(forKey: key) ?? fallback))
        }

        // ── General ───────────────────────────────────────────────────────────
        // Absent means "follow the system", which is why this one is nullable
        // rather than defaulting to a language.
        let language = d.string(forKey: Preferences.Key.languageOverride) ?? ""
        doc.set(path: "general.language", to: language.isEmpty ? .null : .string(language))
        bool("general.analytics", Preferences.Key.analyticsEnabled, default: true)

        // ── Mtool: main shortcut + trigger ────────────────────────────────────
        doc.set(path: "main.hotKeyEnabled", to: .bool(true))
        doc.set(path: "main.hotKey", to: .string(MtoolPreferences.defaultMainHotKey.configString))
        doc.set(path: "main.autoPopupOnSelect", to: .bool(false))
        doc.set(path: "main.autoPopupDelayMs", to: .number(300))
        doc.set(path: "main.doubleCommandEnabled", to: .bool(false))
        doc.set(path: "main.doubleCommandThresholdMs", to: .number(350))
        doc.set(path: "search.askPrompt", to: .string(MtoolPreferences.defaultAskPrompt))

        // ── Mtool: clipboard history + snippets ───────────────────────────────
        doc.set(path: "clipboard.enabled", to: .bool(true))
        doc.set(path: "clipboard.paused", to: .bool(false))
        doc.set(path: "clipboard.maxItems", to: .number(500))
        doc.set(path: "clipboard.retentionDays", to: .number(30))
        doc.set(path: "clipboard.maxImageMB", to: .number(20))
        doc.set(path: "clipboard.plainTextPaste", to: .bool(true))
        doc.set(path: "clipboard.excludedApps",
                to: .array(ClipboardPreferences.defaultExcludedApps.map(JSONValue.string)))

        // ── Popup ─────────────────────────────────────────────────────────────
        // No `enabled`: the popup IS the app, and it runs whenever the app does.
        // A new install gets Liquid Glass. An upgrade from before the config file
        // keeps the default it has been using — the capsule — when it never picked
        // a style, so updating does not swap the popup out from under anyone.
        let isUpgrade = d.object(forKey: Preferences.Key.lastSeenVersion) != nil
            || d.dictionaryRepresentation().keys.contains { $0.hasPrefix("popbar.") }
        string("popup.style", "popbar.style",
               default: (isUpgrade ? PopBarStyle.capsule : PopBarStyle.liquidGlass).rawValue)
        bool("popup.autoExpandHeight", "popbar.autoExpandHeight", default: true)
        number("popup.resultFontSize", "popbar.resultFontSize",
               default: PopBarPreferences.resultFontSizeDefault)
        // The popup hotkey (issue #4) is newer than the UserDefaults era: off, and
        // no combo — there is nothing to carry across.
        doc.set(path: "popup.hotKeyEnabled", to: .bool(false))
        doc.set(path: "popup.hotKey", to: .string(""))

        // ── Wheel geometry ────────────────────────────────────────────────────
        number("wheel.outerRadius", "popbar.wheel.outerRadius",
               default: PopBarPreferences.wheelOuterRadiusDefault)
        number("wheel.innerRadius", "popbar.wheel.innerRadius",
               default: PopBarPreferences.wheelInnerRadiusDefault)
        number("wheel.subSeam", "popbar.wheel.subSeam",
               default: PopBarPreferences.wheelSubSeamDefault)
        number("wheel.subThickness", "popbar.wheel.subThickness",
               default: PopBarPreferences.wheelSubThicknessDefault)
        bool("wheel.showIcons", "popbar.wheel.showIcons", default: true)
        bool("wheel.showLabels", "popbar.wheel.showLabels", default: true)
        bool("wheel.autoHideOnExit", "popbar.wheel.autoHideOnExit", default: true)
        // 3D Glass keeps its own copy of the same knobs, starting from Liquid's.
        for name in PopBarPreferences.RingPrefs.knobNames {
            if let v = doc[path: "wheel.\(name)"] { doc.set(path: "donut.\(name)", to: v) }
        }

        // ── Capsule ───────────────────────────────────────────────────────────
        doc.set(path: "capsule.iconSize", to: .number(PopBarPreferences.capsuleIconSizeDefault))
        doc.set(path: "capsule.labelSize", to: .number(PopBarPreferences.capsuleLabelSizeDefault))
        doc.set(path: "capsule.border", to: .bool(true))

        // ── Screenshot OCR ────────────────────────────────────────────────────
        bool("ocr.enabled", "popbar.ocr.enabled", default: false)
        bool("ocr.autoCopy", "popbar.ocr.autoCopy", default: true)
        doc.set(path: "ocr.hotKey", to: .string(seededHotKey(d).configString))

        // ── Web preview ───────────────────────────────────────────────────────
        bool("webPreview.fallbackToSearch", "popbar.preview.fallbackToSearch", default: true)
        string("webPreview.searchEngine", "popbar.preview.searchEngine",
               default: PreviewSearchEngine.bing.rawValue)

        // ── Model (the API KEY is not here — it stays in the Keychain) ─────────
        let provider = d.string(forKey: "llm.provider") ?? "deepseek"
        let providerDefaults = LLMConfig.providerDefaults(provider)
        doc.set(path: "models.provider", to: .string(provider))
        doc.set(path: "models.model", to: .string(d.string(forKey: "llm.model") ?? providerDefaults.model))
        doc.set(path: "models.apiURL", to: .string(d.string(forKey: "llm.apiURL") ?? providerDefaults.apiURL))
        doc.set(path: "models.thinking", to: .string(d.string(forKey: "llm.reasoningEffort") ?? "none"))

        // ── Actions ───────────────────────────────────────────────────────────
        doc.set(path: "actions", to: seededActions())

        return doc
    }

    /// The OCR hotkey was stored as the encoded `KeyCombo` struct. Read it in that
    /// shape once, then write it out the way a person would type it.
    private static func seededHotKey(_ d: UserDefaults) -> KeyCombo {
        guard let raw = d.string(forKey: "popbar.ocr.hotKey"),
              let data = raw.data(using: .utf8),
              let combo = try? JSONDecoder().decode(KeyCombo.self, from: data)
        else { return .defaultScreenOCR }
        return combo
    }

    /// The actions lived in their own file under Application Support. Fold them in
    /// verbatim — this is the user's own work and must survive the move exactly.
    /// The old file is READ and left in place, never deleted.
    private static func seededActions() -> JSONValue {
        let legacy = Brand.supportDirectory.appendingPathComponent("popbar-actions-v2.json")
        guard let data = try? Data(contentsOf: legacy),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              let list = decoded.arrayValue, !list.isEmpty else {
            let defaults = DefaultActions.seed()
            log.info("no existing actions file — seeding \(defaults.count) default action(s)")
            return encode(defaults)
        }
        log.info("carried \(list.count) action(s) over from \(legacy.lastPathComponent)")
        return decoded
    }

    /// `[PopBarActionConfig]` → `JSONValue`, through the same encoder the actions
    /// were always written with, so the shape in the config file is the shape the
    /// decoder already knows.
    static func encode(_ actions: [PopBarActionConfig]) -> JSONValue {
        guard let data = try? JSONEncoder().encode(actions),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            log.error("could not encode the action list")
            return .array([])
        }
        return value
    }

    /// `JSONValue` → `[PopBarActionConfig]`. Returns nil when the config's
    /// `actions` is missing or malformed, so the caller can keep what it had
    /// rather than replacing a good list with an empty one.
    static func decodeActions(_ value: JSONValue?) -> [PopBarActionConfig]? {
        guard let value, value.arrayValue != nil,
              let data = try? JSONEncoder().encode(value),
              let actions = try? JSONDecoder().decode([PopBarActionConfig].self, from: data) else {
            return nil
        }
        return actions
    }
}
