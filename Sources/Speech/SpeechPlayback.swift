import AVFoundation
import Foundation

/// One read of one piece of text by one reader: what the reading window shows
/// and controls. Only one plays at a time — starting a read stops the previous
/// one (`SpeechCenter`).
///
/// Main thread only.
final class SpeechPlayback: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle               // made but not started (a History record, before Play)
        case preparing          // waiting for the first audio
        case playing
        case paused
        case finished
        case failed(String)
    }

    /// Longest text read in one go; the rest is not read (and the window says so).
    static let maxCharacters = 5000
    /// No audio after this long counts as a failure rather than a slow start.
    static let firstAudioTimeout: TimeInterval = 8

    let id = UUID()
    let text: String
    let wasTruncated: Bool
    let reader: SpeechReader

    @Published private(set) var state: State = .idle
    /// The word being spoken, as a UTF-16 range into `text`.
    @Published private(set) var highlight: NSRange?
    /// This read was played from the local cache, not fetched.
    @Published private(set) var fromCache = false

    private var backend: SpeechBackend?
    private static let log = FileLog("Speech.Playback")

    deinit { backend?.stop() }

    init(text: String, reader: SpeechReader) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        wasTruncated = trimmed.count > Self.maxCharacters
        self.text = wasTruncated ? String(trimmed.prefix(Self.maxCharacters)) : trimmed
        self.reader = reader
    }

    var isActive: Bool { state == .preparing || state == .playing || state == .paused }

    func start() {
        backend?.stop()
        highlight = nil
        fromCache = false   // set again by the backend when the cache answers
        state = .preparing
        let backend: SpeechBackend = reader.isSystem ? SystemSpeechBackend(owner: self) : StreamingSpeechBackend(owner: self)
        self.backend = backend
        // Privacy: which reader and how long, never the text.
        Self.log.info("read \(self.text.count) char(s) with \(self.reader.engine)")
        backend.start()
    }

    func togglePause() {
        switch state {
        case .playing: backend?.pause(); state = .paused
        case .paused: backend?.resume(); state = .playing
        default: break
        }
    }

    /// From the start. A finished streamed read replays from memory; anything
    /// else starts over (from the cache when the read had completed before).
    func replay() {
        if state == .finished, let backend, backend.canReplayLocally {
            highlight = nil
            fromCache = true   // replayed from memory: no network either
            state = .playing
            backend.replay()
        } else {
            start()
        }
    }

    func stop() {
        backend?.stop()
        backend = nil
        if isActive { state = .finished }
        highlight = nil
    }

    // MARK: - Called by backends

    fileprivate func backendStarted() { if state == .preparing { state = .playing } }
    fileprivate func backendHighlight(_ range: NSRange?) { if highlight != range { highlight = range } }
    fileprivate func backendFinished() { state = .finished; highlight = nil }
    fileprivate func backendFromCache() { fromCache = true }
    fileprivate func backendFailed(_ message: String) {
        backend?.stop()
        state = .failed(message)
        highlight = nil
    }
}

/// The one read playing now, app-wide.
final class SpeechCenter {
    static let shared = SpeechCenter()
    private(set) weak var current: SpeechPlayback?

    @discardableResult
    func read(_ text: String, with reader: SpeechReader) -> SpeechPlayback {
        current?.stop()
        let playback = SpeechPlayback(text: text, reader: reader)
        current = playback
        playback.start()
        return playback
    }

    /// Start a read made earlier and not playing (one shown before it is
    /// asked for), as the one read playing now.
    func start(_ playback: SpeechPlayback) {
        if current !== playback { current?.stop() }
        current = playback
        playback.start()
    }

    /// Read `playback` again from the start (or start it, if it never was), as
    /// the one read playing now — whatever else was reading stops.
    func replay(_ playback: SpeechPlayback) {
        if current !== playback { current?.stop() }
        current = playback
        playback.replay()
    }

    func stop(_ playback: SpeechPlayback?) {
        guard let playback else { return }
        playback.stop()
        if current === playback { current = nil }
    }
}

// MARK: - Backends

private protocol SpeechBackend: AnyObject {
    var canReplayLocally: Bool { get }
    func start()
    func pause()
    func resume()
    func replay()
    func stop()
}

/// The macOS system voice, playing itself: it handles its own output device
/// changes and reports each word as it is spoken.
private final class SystemSpeechBackend: NSObject, SpeechBackend, AVSpeechSynthesizerDelegate {
    private weak var owner: SpeechPlayback?
    private let synthesizer = AVSpeechSynthesizer()
    private let text: String

    init(owner: SpeechPlayback) {
        self.owner = owner
        self.text = owner.text
        super.init()
        synthesizer.delegate = self
    }

    var canReplayLocally: Bool { false }

    func start() {
        let utterance = AVSpeechUtterance(string: text)
        let language = Speaker.voiceLanguage(for: text)
        utterance.voice = language.flatMap(AVSpeechSynthesisVoice.init(language:))
        synthesizer.speak(utterance)
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func resume() { synthesizer.continueSpeaking() }
    func replay() { synthesizer.stopSpeaking(at: .immediate); start() }
    func stop() { synthesizer.delegate = nil; synthesizer.stopSpeaking(at: .immediate) }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        owner?.backendStarted()
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange,
                           utterance: AVSpeechUtterance) {
        owner?.backendHighlight(range)
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        owner?.backendFinished()
    }
}

/// A cloud reader: streams from the provider (or plays the cached read),
/// plays as audio arrives, and lights up each word as the player reaches it.
private final class StreamingSpeechBackend: SpeechBackend {
    private weak var owner: SpeechPlayback?
    private let reader: SpeechReader
    private let text: String
    private var player: StreamingPCMPlayer?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var watchdog: DispatchWorkItem?
    /// Located marks in time order.
    private var marks: [TextMark] = []
    private var markCursor = 0
    private var complete = false
    private static let log = FileLog("Speech.Stream")

    init(owner: SpeechPlayback) {
        self.owner = owner
        self.reader = owner.reader
        self.text = owner.text
    }

    var canReplayLocally: Bool { complete }

    // The timer is held by the run loop, not by us: without this a backend
    // dropped without stop() would keep ticking.
    deinit { stop() }

    func start() {
        let key = SpeechCache.key(reader: reader, text: text)
        if let cached = SpeechCache.shared.load(key: key) {
            owner?.backendFromCache()
            let player = makePlayer(format: cached.entry.format)
            marks = cached.entry.marks.filter { $0.location != nil }.sorted { $0.startFrame < $1.startFrame }
            complete = true
            player.load(cached.pcm)
            owner?.backendStarted()
            return
        }
        let settings = SpeechSettingsStore.shared
        let apiKey = settings.apiKey(for: reader.engine)
        guard !apiKey.isEmpty else {
            owner?.backendFailed(L("speech.error.noKey"))
            return
        }
        guard let make = TTSEngineRegistry.all[reader.engine] else {
            owner?.backendFailed(L("speech.error.unavailable"))
            return
        }
        let engine = make(reader.engineSettings(apiKey: apiKey))
        let stream: TTSStream
        do { stream = try engine.synthesize(TTSRequest(text: text)) } catch {
            owner?.backendFailed(Self.describe(error))
            return
        }
        let player = makePlayer(format: stream.format)
        armWatchdog()
        task = Task { @MainActor [weak self] in
            var allMarks: [TextMark] = []
            var gotAudio = false
            do {
                // Cancelling ends this loop WITHOUT an error (the stream just
                // finishes), so every step after it re-checks: a stopped read
                // must not be cached as complete or reported as a failure.
                for try await event in stream.events {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .audio(let data):
                        if !gotAudio { gotAudio = true; self.watchdog?.cancel(); self.owner?.backendStarted() }
                        player.append(data)
                    case .marks(let list):
                        allMarks += list
                        let located = list.filter { $0.location != nil }
                        let inOrder = (self.marks.last?.startFrame ?? 0) <= (located.first?.startFrame ?? .max)
                        self.marks += located
                        // The highlight clock walks the list in time order.
                        if !inOrder { self.marks.sort { $0.startFrame < $1.startFrame } }
                    case .diagnostic:
                        break
                    }
                }
                guard let self, !Task.isCancelled else { return }
                player.finishInput()
                self.complete = true
                if player.totalFrames > 0 {
                    SpeechCache.shared.store(key: key, entry: .init(format: stream.format, marks: allMarks), pcm: player.pcm)
                } else {
                    self.owner?.backendFailed(L("speech.error.noAudio"))
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                Self.log.error("read failed: \(error.localizedDescription)")
                self.owner?.backendFailed(Self.describe(error))
            }
        }
    }

    private func makePlayer(format: TTSAudioFormat) -> StreamingPCMPlayer {
        let player = StreamingPCMPlayer(format: format)
        player.onFinish = { [weak self] in
            self?.timer?.invalidate()
            self?.owner?.backendFinished()
        }
        self.player = player
        startTimer()
        return player
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The word whose start the player has passed most recently.
    private func tick() {
        guard let player else { return }
        let position = player.position
        if markCursor >= marks.count || (markCursor > 0 && marks[markCursor - 1].startFrame > position) {
            markCursor = 0   // after a replay, or marks arrived out of order
        }
        while markCursor < marks.count, marks[markCursor].startFrame <= position { markCursor += 1 }
        guard markCursor > 0 else { owner?.backendHighlight(nil); return }
        let mark = marks[markCursor - 1]
        owner?.backendHighlight(mark.location.map { NSRange(location: $0, length: mark.length) })
    }

    private func armWatchdog() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Self.log.error("no audio within \(Int(SpeechPlayback.firstAudioTimeout)) s")
            self.owner?.backendFailed(L("speech.error.timeout"))
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + SpeechPlayback.firstAudioTimeout, execute: item)
    }

    func pause() { player?.pause() }
    func resume() { player?.resume() }

    func replay() {
        markCursor = 0
        startTimer()
        player?.seek(to: 0)
    }

    func stop() {
        watchdog?.cancel()
        task?.cancel()
        task = nil
        timer?.invalidate()
        timer = nil
        player?.stop()
    }

    /// A message a person can act on.
    static func describe(_ error: Error) -> String {
        if let tts = error as? TTSError {
            switch tts {
            case .http(let status, _) where status == 401 || status == 403:
                return L("speech.error.badKey")
            case .missingSetting(let key) where key.hasPrefix("apiKey"):
                return L("speech.error.noKey")
            default:
                return String(format: L("speech.error.provider"), tts.localizedDescription)
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                return L("speech.error.offline")
            case .timedOut:
                return L("speech.error.timeout")
            default: break
            }
        }
        return String(format: L("speech.error.provider"), error.localizedDescription)
    }
}
