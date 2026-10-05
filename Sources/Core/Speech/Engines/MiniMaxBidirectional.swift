import Foundation

/// MiniMax T2A over the bidirectional WebSocket
/// (platform.minimax.cn/docs/api-reference/speech-t2a-websocket-bidi, read 2026-09-29).
///
/// connected_success → task_start → task_started → task_continue (text) →
/// task_finish; the server answers with sentence_start / task_continued (audio,
/// hex in `data.audio`) / sentence_end per sentence it batched, then
/// task_finished. `subtitle_enable` + `subtitle_type: word_streaming` asks for
/// word timings. The doc does not say where they come; measured 2026-09-29:
/// audio messages carry `data.subtitle` = { text, text_begin, time_begin,
/// time_end, timestamped_words: [{word, time_begin, time_end, word_begin,
/// word_end}] } for the sentence being synthesized. The word list GROWS with
/// each message (earlier words repeated), times are ms from that sentence's
/// start, and whitespace comes as words of its own. A sentence's subtitles all
/// arrive between its sentence_start and sentence_end. The first words arrive
/// ~35 ms after the sentence's first audio.
struct MiniMaxBidirectional {
    let settings: TTSSettings

    func synthesize(_ request: TTSRequest) throws -> TTSStream {
        let key = settings.string("apiKey")
        guard !key.isEmpty else { throw TTSError.missingSetting("apiKey") }
        let host = settings.string("wsURL", settings.string("region", "cn") == "intl"
                                   ? "wss://api.minimax.io" : "wss://api.minimax.cn")
        guard let url = URL(string: "\(host)/ws/v1/t2a_v2_bidi") else { throw TTSError.missingSetting("wsURL") }
        let format = TTSAudioFormat(sampleRate: 24000, channels: 1)
        var start: [String: Any] = [
            "event": "task_start",
            "model": settings.string("model", "speech-2.8-turbo"),
            "voice_setting": ["voice_id": settings.string("voice", "Chinese (Mandarin)_News_Anchor"),
                              "speed": settings.double("speed", 1), "vol": 1, "pitch": 0],
            "audio_setting": ["sample_rate": format.sampleRate, "format": "pcm", "channel": 1],
            "language_boost": settings.string("languageBoost", "auto"),
            "subtitle_enable": true,
            "subtitle_type": settings.string("subtitleType", "word_streaming"),
        ]
        start.merge(settings.extra) { _, new in new }
        let text = request.text
        let trace = settings.bool("trace", false)

        return makeTTSStream(format: format) { continuation in
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let socket = TTSWebSocket(req, continuation: continuation)
            defer { socket.close() }

            var assembler = PCMAssembler(format: format)
            var aligner = MarkAligner(text: text)
            var sentenceStarts: [Int] = []          // frame where each server sentence began, in order
            var emitted = 0                         // current sentence's words already turned into marks
            var previews = 0
            let plain: Set<String> = ["event", "data", "is_final", "extra_info", "session_id",
                                      "trace_id", "connect_id", "base_resp"]

            while true {
                try Task.checkCancellation()
                guard case .string(let json) = try await socket.receive(),
                      let msg = jsonObject(json) else { continue }
                if let base = msg["base_resp"] as? [String: Any], let code = base["status_code"] as? Int, code != 0 {
                    throw TTSError.provider("\(code) \(base["status_msg"] ?? "")")
                }
                let event = msg["event"] as? String ?? ""
                let data = msg["data"] as? [String: Any] ?? [:]
                // Log the shape of anything that is not plain audio, to learn
                // where the word timings live.
                let unusual = msg.keys.contains { !plain.contains($0) } || data.keys.contains { $0 != "audio" }
                if trace || (unusual && previews < 8) {
                    previews += 1
                    continuation.yield(.diagnostic(.note("minimax ws \(event): \(previewOfMessage(json))")))
                }
                switch event {
                case "connected_success":
                    try await socket.send(json: start)
                case "task_started":
                    // The server batches text into sentences itself.
                    try await socket.send(json: ["event": "task_continue", "text": text])
                    try await socket.send(json: ["event": "task_finish"])
                case "sentence_start":
                    // Events come strictly in order (measured): sentence_start,
                    // that sentence's audio and subtitles, sentence_end, next.
                    sentenceStarts.append(assembler.framesEmitted)
                    emitted = 0
                case "task_continued":
                    if let hex = data["audio"] as? String, !hex.isEmpty, let audio = Data(hex: hex),
                       let whole = assembler.push(audio) {
                        continuation.yield(.audio(whole))
                    }
                    guard let sub = data["subtitle"] as? [String: Any],
                          let words = sub["timestamped_words"] as? [[String: Any]] else { continue }
                    let base = sentenceStarts.last ?? assembler.framesEmitted
                    guard words.count > emitted else { continue }
                    let fresh = words[emitted...]
                    emitted = words.count
                    let marks = fresh.compactMap { w -> TextMark? in
                        guard let word = w["word"] as? String,
                              !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                        let begin = (w["time_begin"] as? Double ?? 0) / 1000
                        let end = (w["time_end"] as? Double ?? 0) / 1000
                        // MiniMax times pieces of English words ("ben", "ch", "mar", "ks");
                        // highlight the whole word for each piece.
                        let mark = aligner.place(word, startFrame: base + format.frames(seconds: begin),
                                                 endFrame: base + format.frames(seconds: end))
                        return aligner.widenedToWord(mark)
                    }
                    if !marks.isEmpty { continuation.yield(.marks(marks)) }
                case "task_finished":
                    return
                case "task_failed":
                    throw TTSError.provider("task_failed")
                default:
                    continue
                }
            }
        }
    }
}
