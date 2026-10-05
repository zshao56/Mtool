import AppKit

/// Runs a configured action against the selected text and produces a
/// `PopBarPresentation` — the single seam between "what an action does" and "how its
/// output is shown". The session resolves the model config (default or per-action
/// override) via the shared `LLMService` and passes both in; a nil `config` for an
/// AI action means "no API key for that provider" → a clear, actionable message. The
/// actual inference goes through `LLMService`, the app-level facade.
enum ActionRegistry {

    private static let log = FileLog("PopBar.Action")

    static func run(_ action: PopBarActionConfig, on text: String, url: URL?,
                    service: LLMService?, config: LLMConfig?) async -> PopBarPresentation {
        // Written by a newer build (see `PopBarActionConfig.unsupportedKindRaw`).
        // Say so plainly — the alternative is running it as the empty AI action it
        // decoded to, which produces a baffling "no prompt" error for something the
        // user never configured as a prompt.
        guard !action.isUnsupported else {
            log.info("action '\(action.title)' needs a newer build — not run")
            return .error("⚠️ \(L("popbar.error.unsupported"))")
        }
        log.debug("run action '\(action.title)' (\(action.kind.rawValue)) on \(text.count) char(s)")
        switch action.kind {
        case .copy:
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return .none

        case .webPreview:
            return webPreviewPresentation(url: url, text: text)

        case .quickLook:
            return pathPresentation(text: text, forceFinder: false)

        case .revealInFinder:
            return pathPresentation(text: text, forceFinder: true)

        case .openURL:
            return openURLPresentation(action, text: text)

        case .speak:
            return .speak(text)

        case .pause:
            return .pause

        case .settings:
            return .openSettings

        case .inspect:
            return .inspect

        case .transform:
            return transformPresentation(action, text: text)

        case .shortcut:
            let name = (action.shortcut ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .error("⚠️ \(L("popbar.error.noshortcut"))") }
            return processPresentation(await ProcessRunner.runShortcut(name, input: text))

        case .script:
            let script = action.script ?? ""
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("⚠️ \(L("popbar.error.noscript"))")
            }
            let allowed = await MainActor.run { () -> Bool in
                if ScriptApproval.isApproved(script) { return true }
                guard ScriptApproval.ask(title: action.title, script: script) else { return false }
                ScriptApproval.approve(script)
                return true
            }
            guard allowed else {
                log.info("script '\(action.title)' not approved — not run")
                return .none
            }
            return processPresentation(await ProcessRunner.runScript(script, input: text))

        case .systemTranslate:
            let translated = await SystemTranslator.translate(text, to: action.targetLanguage)
            // Given up on while it ran (popup closed, another action): nothing
            // to show, and above all nothing to write into a document.
            if Task.isCancelled { return .none }
            switch translated {
            case .success(let out):
                return out.isEmpty ? .error(L("popbar.error.empty")) : .output(out)
            case .failure(.needsNewerSystem):
                return .error("⚠️ \(L("systemTranslate.error.needsNewerSystem"))")
            case .failure(.noTarget):
                return .error("⚠️ \(L("systemTranslate.error.noTarget"))")
            case .failure(.alreadyInTarget(let target)):
                let name = SystemTranslator.displayName(of: target)
                return .error("⚠️ \(String(format: L("systemTranslate.error.alreadyInTarget"), name))")
            case .failure(.unsupportedPair(let source, let target)):
                let names = [source, target].map(SystemTranslator.displayName(of:))
                return .error("⚠️ \(String(format: L("systemTranslate.error.unsupported"), names[0], names[1]))")
            case .failure(.cancelled):
                // Superseded by another popup's translation (a pinned one still
                // waiting), or the window closed by hand: say so.
                return .error("⚠️ \(L("systemTranslate.error.closed"))")
            case .failure(.notDownloaded):
                return .error("⚠️ \(L("systemTranslate.error.notDownloaded"))")
            case .failure(.didNotStart):
                return .error("⚠️ \(L("systemTranslate.error.didNotStart"))")
            case .failure(.failed(let reason)):
                return .error("⚠️ \(L("systemTranslate.error.prefix"))" + (reason.isEmpty ? "" : "\n\n\(reason)"))
            }

        case .group:
            // A group is not runnable. The wheel never sends one here (tapping a
            // group just keeps its ring open) and the capsule shows its children
            // in its place, so this is only reached by a hand-edited file.
            log.debug("action '\(action.title)' is a group — nothing to run")
            return .none

        case .ai:
            guard !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("⚠️ \(L("popbar.error.noprompt"))")
            }
            guard let service, let config else {
                return .error("⚠️ \(L("popbar.error.nokey"))")
            }
            do {
                let output = try await service.complete(config, system: action.prompt, user: text)
                return output.isEmpty ? .error(L("popbar.error.empty")) : .output(output)
            } catch {
                log.error("LLM '\(action.title)' failed: \(error.localizedDescription)")
                return .error("⚠️ \(L("popbar.error.prefix"))\n\n\(error.localizedDescription)")
            }
        }
    }

    /// The web-preview action's presentation: the resolved link if any; otherwise the
    /// opt-in fallback search of the selected text; otherwise a "no link" message.
    private static func webPreviewPresentation(url: URL?, text: String) -> PopBarPresentation {
        if let url { return .webPreview(url) }
        if PopBarPreferences.previewFallbackToSearch, let search = PreviewSearch.searchURL(for: text) {
            log.debug("web preview: no link in selection → fallback web search")
            return .webPreview(search)
        }
        log.debug("web preview: no link in selection and fallback search off → message")
        return .error("⚠️ \(L("popbar.error.nolink"))")
    }

    private static func openURLPresentation(_ action: PopBarActionConfig, text: String) -> PopBarPresentation {
        guard let template = action.url, let url = URLTemplate.fill(template, with: text) else {
            log.debug("openURL '\(action.title)': no usable address")
            return .error("⚠️ \(L("popbar.error.badurl"))")
        }
        // The mini-browser can only show web pages; any other scheme belongs to
        // the app that owns it, whatever the action asked for.
        if action.openTarget == .preview, URLTemplate.isWeb(url) { return .webPreview(url) }
        return .openExternal(url)
    }

    private static func transformPresentation(_ action: PopBarActionConfig, text: String) -> PopBarPresentation {
        guard let op = action.op.flatMap(TextTransform.init(rawValue:)) else {
            return .error("⚠️ \(L("popbar.error.unknownop"))")
        }
        if op == .count {
            return .result(TextTransform.countReport(text, labels: (
                L("transform.count.characters"), L("transform.count.charactersNoSpaces"),
                L("transform.count.words"), L("transform.count.lines"))))
        }
        switch op.apply(text) {
        case .success(let out):
            return .output(out)
        case .failure(.invalidJSON):
            return .error("⚠️ \(L("popbar.error.invalidjson"))")
        case .failure(.notDecodable):
            return .error("⚠️ \(L("popbar.error.notdecodable"))")
        }
    }

    private static func processPresentation(_ result: Result<String, ProcessRunner.Failure>) -> PopBarPresentation {
        switch result {
        case .success(let out):
            // A Shortcut or script that only does something (saves a note) prints
            // nothing: that is success, and there is nothing to show.
            return out.isEmpty ? .none : .output(out)
        case .failure(.timedOut):
            return .error("⚠️ \(L("popbar.error.timeout"))")
        case .failure(.exited(let status, let stderr)):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .error("⚠️ \(String(format: L("popbar.error.exited"), Int(status)))"
                           + (detail.isEmpty ? "" : "\n\n```\n\(detail.prefix(2000))\n```"))
        case .failure(.couldNotStart(let reason)):
            return .error("⚠️ \(L("popbar.error.prefix"))\n\n\(reason)")
        }
    }

    /// Both path actions resolve the selection the same way and differ only in what
    /// they do with a FILE — Quick Look it, or reveal it in Finder. A FOLDER has no
    /// Quick Look preview at all, so "Preview" on one opens it in Finder: the useful
    /// outcome rather than an error the user can do nothing with.
    ///
    /// Resolution happens here, lazily, when the action is actually tapped. It's a
    /// single `stat` on text we already hold, so unlike link resolution there's
    /// nothing to pre-compute at trigger time and nothing to plumb through the
    /// selection layer.
    private static func pathPresentation(text: String, forceFinder: Bool) -> PopBarPresentation {
        guard let target = PathResolver.resolve(text) else {
            // Privacy: never log the selection itself — it can be anything.
            log.debug("path action: selection (\(text.count) chars) is not an existing local path")
            return .error("⚠️ \(L("popbar.error.nopath"))")
        }
        if forceFinder || target.isDirectory {
            log.debug("path action → Finder (isDirectory=\(target.isDirectory))")
            return .revealInFinder(target.url, isDirectory: target.isDirectory)
        }
        log.debug("path action → Quick Look")
        return .quickLook(target.url)
    }

    /// Streaming variant for AI actions: deltas (displayed text so far) arrive via
    /// `onDelta` as they're produced, then the final presentation is returned. Non-AI
    /// cases are identical to `run` (no stream to drive). If the stream fails to
    /// *start* (e.g. provider/proxy doesn't support SSE), this falls back to the
    /// one-shot `complete()` path so behavior never regresses. `onDelta` is always
    /// called on the same actor as the awaiting caller.
    static func runStreaming(
        _ action: PopBarActionConfig,
        on text: String,
        url: URL?,
        service: LLMService?,
        config: LLMConfig?,
        onDelta: @escaping (String) -> Void
    ) async -> PopBarPresentation {
        guard action.kind == .ai else {
            return await run(action, on: text, url: url, service: service, config: config)
        }

        log.debug("stream action '\(action.title)' on \(text.count) char(s)")
        guard !action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("⚠️ \(L("popbar.error.noprompt"))")
        }
        guard let service, let config else {
            return .error("⚠️ \(L("popbar.error.nokey"))")
        }

        // Track whether any token reached the UI: a failure AFTER content is shown
        // must NOT silently re-run the one-shot path (double charge + lost partial).
        let emitted = StreamProgress()
        do {
            let output = try await service.stream(config, system: action.prompt, user: text) { displayed in
                if !displayed.isEmpty { emitted.didEmit = true }
                onDelta(displayed)
            }
            return output.isEmpty ? .error(L("popbar.error.empty")) : .output(output)
        } catch is CancellationError {
            return .none   // re-triggered / panel closed — drop silently
        } catch {
            // `URLSession.bytes` surfaces task cancellation as `URLError.cancelled`,
            // NOT `CancellationError` — treat both as a silent dismiss so a canceled
            // stream never spawns a second (paid) one-shot request.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return .none }
            // Fall back to the proven one-shot path ONLY if nothing streamed yet
            // (e.g. a provider/proxy that doesn't support SSE). Once partial output
            // has been shown, surface the error rather than restarting the request.
            guard !emitted.didEmit else {
                log.error("LLM stream '\(action.title)' failed mid-stream: \(error.localizedDescription)")
                return .error("⚠️ \(L("popbar.error.prefix"))\n\n\(error.localizedDescription)")
            }
            log.error("LLM stream '\(action.title)' failed to start: \(error.localizedDescription) — falling back to one-shot")
            do {
                let output = try await service.complete(config, system: action.prompt, user: text)
                return output.isEmpty ? .error(L("popbar.error.empty")) : .output(output)
            } catch is CancellationError {
                return .none
            } catch let fallbackError {
                log.error("LLM one-shot fallback '\(action.title)' failed: \(fallbackError.localizedDescription)")
                return .error("⚠️ \(L("popbar.error.prefix"))\n\n\(fallbackError.localizedDescription)")
            }
        }
    }

    /// Tiny reference box so the escaping `onDelta` closure can flip a flag the
    /// surrounding async function reads after the stream ends (value-type capture
    /// wouldn't propagate the mutation back).
    private final class StreamProgress { var didEmit = false }
}
