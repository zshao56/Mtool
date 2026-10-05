import AppKit

/// Where a popup's text came from: how it was opened and in which app. Captured
/// when the popup opens — a pinned window can run an action minutes later with
/// some other app in front, so it is never read at action time.
struct HistoryOrigin {
    let trigger: HistoryRecord.Trigger
    let appBundleID: String?
    let appName: String?

    init(trigger: HistoryRecord.Trigger, app: NSRunningApplication?) {
        self.trigger = trigger
        self.appBundleID = app?.bundleIdentifier
        self.appName = app?.localizedName
    }
}

/// Turns one finished run into a history record. The only thing that decides
/// what is recorded and how a presentation maps to a stored outcome.
enum HistoryRecorder {

    /// Record a run. Returns the ticket for patching what became of the result,
    /// or nil when the run is not recorded.
    ///
    /// - `partial`: the text streamed so far, for a run that was stopped.
    /// - `cancelled`: the run was given up on (popup closed, another action).
    @discardableResult
    static func record(_ action: PopBarActionConfig, input: String, origin: HistoryOrigin?,
                       presentation: PopBarPresentation, partial: String?, cancelled: Bool,
                       startedAt: Date, config: LLMConfig?) -> HistoryTicket? {
        // No origin: the onboarding sample or the preview — not the user's text.
        guard let origin, HistoryPreferences.enabled else { return nil }
        if HistoryPreferences.isExcluded(origin.appBundleID) { return nil }
        switch action.kind {
        case .pause, .inspect, .settings, .group: return nil
        case .copy where !HistoryPreferences.recordCopy: return nil
        default: break
        }

        var outcomeType: HistoryRecord.OutcomeType
        var output: String?
        var extras: [String: String] = [:]
        var status: HistoryRecord.Status = .ok
        var deliverMode: String?

        switch presentation {
        case .output(let text):
            outcomeType = .text
            output = text
            deliverMode = action.outputMode.rawValue
            if action.outputMode == .compare { extras["style"] = "compare" }
            if action.kind == .transform, let op = action.op,
               [TextTransform.jsonPretty.rawValue, TextTransform.jsonMinify.rawValue].contains(op) {
                extras["style"] = "mono"
            }
        case .result(let text):
            outcomeType = .message
            output = text
        case .error(let text):
            outcomeType = .message
            output = text
            status = .error
        case .openExternal(let url):
            outcomeType = .link
            output = url.absoluteString
            extras["target"] = "browser"
        case .webPreview(let url):
            outcomeType = .link
            output = url.absoluteString
            extras["target"] = "preview"
        case .quickLook(let url):
            outcomeType = .file
            output = url.path
            extras["isDirectory"] = "false"
        case .revealInFinder(let url, let isDirectory):
            outcomeType = .file
            output = url.path
            extras["isDirectory"] = isDirectory ? "true" : "false"
            extras["target"] = "finder"
        case .speak:
            outcomeType = .speech
            let reader = SpeechSettingsStore.shared.resolve(action.reader)
            extras["reader"] = reader.name
            // What the History page replays with — and, with the text, what
            // finds the read in the speech cache, so a replay costs nothing.
            extras["readerID"] = reader.id
        case .none:
            if cancelled {
                // Stopped before it finished: kept only if something came out,
                // since that is what was paid for and seen.
                guard let partial, !partial.isEmpty else { return nil }
                outcomeType = .text
                output = partial
                status = .cancelled
            } else {
                // A script the user declined to run also ends here: it did not run.
                if action.kind == .script, !ScriptApproval.isApproved(action.script ?? "") { return nil }
                outcomeType = .silent
            }
        case .pause, .inspect, .openSettings:
            return nil
        }

        let actionJSON = (try? JSONEncoder().encode(action)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let storedInput = HistoryRecord.truncated(input)
        if let text = output {
            let stored = HistoryRecord.truncated(text)
            output = stored.text
            if stored.truncated { extras["outputTruncated"] = "true" }
        }
        let timed: Set<PopBarActionConfig.Kind> = [.ai, .systemTranslate, .shortcut, .script]
        let record = HistoryRecord(
            createdAt: startedAt,
            trigger: origin.trigger.rawValue,
            appBundleID: origin.appBundleID,
            appName: origin.appName,
            actionID: action.id,
            actionKind: action.kind.rawValue,
            actionTitle: action.title,
            actionSymbol: action.iconSymbol,
            actionJSON: actionJSON,
            category: (status == .error ? HistoryRecord.Category.error : category(of: action.kind)).rawValue,
            input: storedInput.text,
            inputTruncated: storedInput.truncated,
            provider: action.isAI ? config?.provider : nil,
            model: action.isAI ? config?.model : nil,
            durationMs: timed.contains(action.kind) ? Int(Date().timeIntervalSince(startedAt) * 1000) : nil,
            outcomeType: outcomeType.rawValue,
            output: output,
            extras: extras,
            deliverMode: deliverMode,
            delivered: nil,
            status: status.rawValue)
        let ticket = HistoryTicket()
        HistoryStore.shared.insert(record, ticket: ticket)
        return ticket
    }

    static func category(of kind: PopBarActionConfig.Kind) -> HistoryRecord.Category {
        switch kind {
        case .ai, .systemTranslate:                              return .ai
        case .transform, .copy:                                  return .text
        case .speak:                                             return .speech
        case .openURL, .webPreview, .quickLook, .revealInFinder: return .web
        case .shortcut, .script:                                 return .automation
        case .pause, .inspect, .settings, .group:                return .text
        }
    }
}
