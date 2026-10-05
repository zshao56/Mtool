import Carbon.HIToolbox

/// A hotkey as something a person can type into the config file.
///
/// `KeyCombo` is stored in the shape `RegisterEventHotKey` wants — a virtual key
/// code and a Carbon bitmask — which is right for the API and useless in a file
/// meant to be hand-edited: `{"keyCode":1,"carbonModifiers":768}` tells you
/// nothing and cannot be changed without looking up a table. In the config it is
/// written the way it is spoken: `"shift+cmd+s"`.
extension KeyCombo {

    /// Modifier order is fixed so a round trip is stable and a diff of the config
    /// file does not churn: ctrl, opt, shift, cmd — the same order as the glyphs.
    var configString: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("ctrl") }
        if carbonModifiers & UInt32(optionKey)  != 0 { parts.append("opt") }
        if carbonModifiers & UInt32(shiftKey)   != 0 { parts.append("shift") }
        if carbonModifiers & UInt32(cmdKey)     != 0 { parts.append("cmd") }
        parts.append(Self.names[keyCode] ?? "key\(keyCode)")
        return parts.joined(separator: "+")
    }

    /// Parse `"shift+cmd+s"`. Tolerant on purpose — this comes out of a file a
    /// person typed, so spaces, dashes, case and the common aliases all work.
    /// Returns nil only when the KEY itself is unrecognizable, which is the one
    /// case where guessing would silently bind the wrong shortcut.
    init?(configString: String) {
        let tokens = configString
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(whereSeparator: { $0 == "+" || $0 == "-" })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        var modifiers: UInt32 = 0
        var key: UInt32?
        for token in tokens {
            switch token {
            case "ctrl", "control", "⌃":            modifiers |= UInt32(controlKey)
            case "opt", "option", "alt", "⌥":       modifiers |= UInt32(optionKey)
            case "shift", "⇧":                      modifiers |= UInt32(shiftKey)
            case "cmd", "command", "meta", "⌘":     modifiers |= UInt32(cmdKey)
            default:
                // The last non-modifier token wins, so "cmd+shift+s" and a stray
                // duplicate both land on one key rather than failing outright.
                if let code = Self.codes[token] { key = code } else { return nil }
            }
        }
        guard let key else { return nil }
        self.init(keyCode: key, carbonModifiers: modifiers)
    }

    // MARK: - Names

    /// Written-out names for the keys the recorder can produce. Kept separate from
    /// `display`'s glyph table: glyphs are for the UI, these are for typing.
    private static let names: [UInt32: String] = {
        var map: [UInt32: String] = [:]
        let letters = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
                       "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"]
        let letterCodes = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
                           kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
                           kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
                           kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
                           kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
                           kVK_ANSI_Z]
        for (name, code) in zip(letters, letterCodes) { map[UInt32(code)] = name }

        let digitCodes = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                          kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, code) in digitCodes.enumerated() { map[UInt32(code)] = String(i) }

        let fCodes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                      kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in fCodes.enumerated() { map[UInt32(code)] = "f\(i + 1)" }

        map[UInt32(kVK_Space)]      = "space"
        map[UInt32(kVK_Return)]     = "return"
        map[UInt32(kVK_Tab)]        = "tab"
        map[UInt32(kVK_Escape)]     = "escape"
        map[UInt32(kVK_Delete)]     = "delete"
        map[UInt32(kVK_LeftArrow)]  = "left"
        map[UInt32(kVK_RightArrow)] = "right"
        map[UInt32(kVK_UpArrow)]    = "up"
        map[UInt32(kVK_DownArrow)]  = "down"
        return map
    }()

    /// The reverse table, plus the aliases someone is likely to type.
    private static let codes: [String: UInt32] = {
        var map = Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) })
        map["esc"]   = UInt32(kVK_Escape)
        map["enter"] = UInt32(kVK_Return)
        map["del"]   = UInt32(kVK_Delete)
        map["backspace"] = UInt32(kVK_Delete)
        map["arrowleft"]  = UInt32(kVK_LeftArrow)
        map["arrowright"] = UInt32(kVK_RightArrow)
        map["arrowup"]    = UInt32(kVK_UpArrow)
        map["arrowdown"]  = UInt32(kVK_DownArrow)
        return map
    }()
}
