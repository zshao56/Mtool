import Foundation

/// Alibaba Cloud Model Studio (百炼 / DashScope) task WebSocket. One protocol
/// serves two model lines, registered as two providers because their models and
/// voices differ:
/// - `qwen-audio`: qwen-audio-3.0-tts-flash / -plus
/// - `cosyvoice`:  cosyvoice-v3-flash / -plus, cosyvoice-v2
///
/// Protocol (help/en/model-studio/cosyvoice-websocket-api): run-task → wait for
/// task-started → continue-task with the text → finish-task; the server sends
/// JSON events and, after each `sentence-synthesis` event, one binary audio
/// frame. Word timings come in the `sentence-end` event as `words[]` with
/// `begin_time`/`end_time` in ms. The docs do not say whether those times count
/// from the stream start or from each sentence, so both are handled: see
/// `sentenceRelative`.
struct DashScopeEngine {
    let settings: TTSSettings
    let defaultModel: String
    let defaultVoice: String

    func synthesize(_ request: TTSRequest) throws -> TTSStream {
        let key = settings.string("apiKey")
        guard !key.isEmpty else { throw TTSError.missingSetting("apiKey") }
        let region = settings.string("region", "cn")
        let endpoint = settings.string("endpoint", region == "intl"
            ? "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference"
            : "wss://dashscope.aliyuncs.com/api-ws/v1/inference")
        guard let url = URL(string: endpoint) else { throw TTSError.missingSetting("endpoint") }
        let format = TTSAudioFormat(sampleRate: 24000, channels: 1)
        let model = settings.string("model", defaultModel)
        let voice = settings.string("voice", defaultVoice)
        let speed = settings.double("speed", 1)
        let extra = settings.extra
        let text = request.text
        let splitSentences = settings.bool("splitSentences", true)
        let quickStart = settings.bool("quickStart", false)

        return makeTTSStream(format: format) { continuation in
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let socket = TTSWebSocket(req, continuation: continuation)
            defer { socket.close() }
            let taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            func header(_ action: String) -> [String: Any] {
                ["action": action, "task_id": taskId, "streaming": "duplex"]
            }
            var parameters: [String: Any] = [
                "text_type": "PlainText", "voice": voice, "format": "pcm", "sample_rate": format.sampleRate,
                "volume": 50, "rate": speed, "pitch": 1.0, "word_timestamp_enabled": true,
            ]
            parameters.merge(extra) { _, new in new }
            try await socket.send(json: ["header": header("run-task"), "payload": [
                "task_group": "audio", "task": "tts", "function": "SpeechSynthesizer", "model": model,
                "parameters": parameters, "input": [String: Any](),
            ] as [String: Any]])

            var assembler = PCMAssembler(format: format)
            var aligner = MarkAligner(text: text)
            var sentenceStartFrame: [Int: Int] = [:]
            var sentenceRelative: Bool?
            var emitted: [Int: Int] = [:]
            var firstSeen: [Int: [Double]] = [:]   // begin times as first reported, per sentence
            var sentTask = false

            let trace = settings.bool("trace", false)
            while true {
                try Task.checkCancellation()
                let message = try await socket.receive()
                if trace {
                    switch message {
                    case .data(let bytes): continuation.yield(.diagnostic(.note("trace audio \(bytes.count) bytes")))
                    case .string(let json):
                        let e = jsonObject(json) ?? [:]
                        let head = e["header"] as? [String: Any]
                        let out = (e["payload"] as? [String: Any])?["output"] as? [String: Any]
                        let s = out?["sentence"] as? [String: Any]
                        let words = (s?["words"] as? [Any])?.count ?? 0
                        continuation.yield(.diagnostic(.note("trace \(head?["event"] ?? "?") \(out?["type"] ?? "") sentence=\(s?["index"] ?? "-") words=\(words)")))
                    @unknown default: break
                    }
                }
                switch message {
                case .data(let bytes):
                    if let whole = assembler.push(bytes) { continuation.yield(.audio(whole)) }
                case .string(let json):
                    guard let event = jsonObject(json), let head = event["header"] as? [String: Any] else { continue }
                    switch head["event"] as? String {
                    case "task-started":
                        if !sentTask {
                            sentTask = true
                            // One message per sentence: sent as one block, the
                            // server treats a whole paragraph as a single
                            // "sentence" and reports its word times only once
                            // all of it is synthesized (measured 2026-09-28).
                            let pieces = !splitSentences ? [text]
                                : quickStart ? TextChunker.quickStartPieces(text) : TextChunker.sentences(text)
                            for piece in pieces {
                                try await socket.send(json: ["header": header("continue-task"),
                                                             "payload": ["input": ["text": piece]]])
                            }
                            try await socket.send(json: ["header": header("finish-task"),
                                                         "payload": ["input": [String: Any]()]])
                        }
                    case "result-generated":
                        let output = (event["payload"] as? [String: Any])?["output"] as? [String: Any]
                        let sentence = output?["sentence"] as? [String: Any]
                        let index = sentence?["index"] as? Int ?? 0
                        let type = output?["type"] as? String
                        if type == "sentence-begin" { sentenceStartFrame[index] = assembler.framesEmitted }
                        // Words arrive progressively: each `sentence-synthesis`
                        // event carries the sentence's words known so far (a
                        // growing list, measured 2026-09-28 — the docs only
                        // mention `sentence-end`), so only the new tail is taken.
                        guard let words = sentence?["words"] as? [[String: Any]], !words.isEmpty else { continue }
                        if type == "sentence-end", trace {
                            // Were times given early revised later? Compare with the final list.
                            let final = words.map { $0["begin_time"] as? Double ?? 0 }
                            let drift = zip(firstSeen[index] ?? [], final).map { abs($0 - $1) }.max() ?? 0
                            continuation.yield(.diagnostic(.note("trace sentence \(index): \(words.count) words, max revision of an early time \(Int(drift)) ms")))
                        }
                        guard words.count > emitted[index, default: 0] else { continue }
                        let fresh = words[emitted[index, default: 0]...]
                        firstSeen[index, default: []] += fresh.map { $0["begin_time"] as? Double ?? 0 }
                        emitted[index] = words.count
                        let base = sentenceStartFrame[index] ?? 0
                        let firstBegin = words.first?["begin_time"] as? Double ?? 0
                        if sentenceRelative == nil, index > 0, base > format.sampleRate / 5 {
                            // A later sentence whose first word starts well before
                            // the audio already received means times restart per
                            // sentence. Needs ≥ 200 ms of earlier audio to tell.
                            sentenceRelative = format.frames(seconds: firstBegin / 1000) < base / 2
                            continuation.yield(.diagnostic(.note("word times are \(sentenceRelative! ? "per-sentence" : "stream-absolute")")))
                        }
                        let offset = sentenceRelative == true ? base : 0
                        let marks = fresh.map { w -> TextMark in
                            let begin = format.frames(seconds: (w["begin_time"] as? Double ?? 0) / 1000) + offset
                            let end = format.frames(seconds: (w["end_time"] as? Double ?? 0) / 1000) + offset
                            return aligner.place(w["text"] as? String ?? "", startFrame: begin, endFrame: end)
                        }
                        continuation.yield(.marks(marks))
                    case "task-finished":
                        return
                    case "task-failed":
                        throw TTSError.provider("\(head["error_code"] ?? "") \(head["error_message"] ?? "")")
                    default:
                        continue
                    }
                @unknown default:
                    continue
                }
            }
        }
    }
}

struct QwenAudioEngine: TTSEngine {
    static let descriptor = TTSEngineDescriptor(id: "qwen-audio", displayName: "Alibaba Qwen-Audio TTS",
                                                marks: .word, transport: "WebSocket")
    let settings: TTSSettings
    func synthesize(_ request: TTSRequest) throws -> TTSStream {
        try DashScopeEngine(settings: settings, defaultModel: "qwen-audio-3.0-tts-flash",
                            defaultVoice: "longanhuan_v3.6").synthesize(request)
    }
}

struct CosyVoiceEngine: TTSEngine {
    static let descriptor = TTSEngineDescriptor(id: "cosyvoice", displayName: "Alibaba CosyVoice",
                                                marks: .word, transport: "WebSocket")
    let settings: TTSSettings
    func synthesize(_ request: TTSRequest) throws -> TTSStream {
        try DashScopeEngine(settings: settings, defaultModel: "cosyvoice-v3-flash",
                            defaultVoice: "longanyang").synthesize(request)
    }
}
