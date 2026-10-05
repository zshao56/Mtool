import Foundation

/// MiniMax T2A v2. Default transport is the bidirectional WebSocket
/// (`MiniMaxBidirectional`); `"transport": "http"` selects HTTP SSE
/// (platform.minimax.io/docs/api-reference/speech-t2a-http), described below.
///
/// Audio arrives hex-encoded in `data.audio`, `data.status` 2 marks the end.
/// Word timings are the open question: the docs only describe a subtitle FILE
/// linked from the final event (`data.subtitle_file`), i.e. timings after the
/// whole text is synthesized. This adapter asks for `word_streaming`, takes
/// any inline timings it finds, and otherwise downloads the file at the end —
/// the benchmark then reports those marks as late, which is the honest answer.
struct MiniMaxEngine: TTSEngine {
    static let descriptor = TTSEngineDescriptor(id: "minimax", displayName: "MiniMax Speech",
                                                marks: .word, transport: "WebSocket")
    let settings: TTSSettings

    func synthesize(_ request: TTSRequest) throws -> TTSStream {
        if settings.string("transport", "websocket") != "http" {
            return try MiniMaxBidirectional(settings: settings).synthesize(request)
        }
        let key = settings.string("apiKey")
        guard !key.isEmpty else { throw TTSError.missingSetting("apiKey") }
        let host = settings.string("baseURL", settings.string("region", "cn") == "intl"
                                   ? "https://api.minimax.io" : "https://api.minimax.cn")
        guard let url = URL(string: "\(host)/v1/t2a_v2") else { throw TTSError.missingSetting("baseURL") }
        let format = TTSAudioFormat(sampleRate: 24000, channels: 1)
        var body: [String: Any] = [
            "model": settings.string("model", "speech-2.8-turbo"),
            "text": request.text,
            "stream": true,
            "stream_options": ["exclude_aggregated_audio": true],
            "voice_setting": ["voice_id": settings.string("voice", "Chinese (Mandarin)_News_Anchor"),
                              "speed": settings.double("speed", 1), "vol": 1, "pitch": 0],
            "audio_setting": ["sample_rate": format.sampleRate, "format": "pcm", "channel": 1],
            "language_boost": settings.string("languageBoost", "auto"),
            "subtitle_enable": true,
            "subtitle_type": settings.string("subtitleType", "word_streaming"),
        ]
        body.merge(settings.extra) { _, new in new }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let text = request.text

        return makeTTSStream(format: format) { continuation in
            var assembler = PCMAssembler(format: format)
            var aligner = MarkAligner(text: text)
            var subtitleFile: String?
            var previews = 0
            try await TTSNetwork.streamLines(req, into: continuation) { line in
                // Errors come back as a plain JSON body (HTTP 200), not as SSE.
                guard let payload = sseData(line) ?? (line.hasPrefix("{") ? line : nil),
                      let msg = jsonObject(payload) else { return }
                if let base = msg["base_resp"] as? [String: Any], let code = base["status_code"] as? Int, code != 0 {
                    throw TTSError.provider("\(code) \(base["status_msg"] ?? "")")
                }
                guard let data = msg["data"] as? [String: Any] else { return }
                // Keep the shape of the first few events and every event
                // carrying something other than audio, to see where timings live.
                if previews < 2 || data.keys.contains(where: { $0 != "audio" && $0 != "status" }) {
                    if previews < 8 {
                        previews += 1
                        continuation.yield(.diagnostic(.note("minimax: \(previewOfMessage(payload))")))
                    }
                }
                if let hex = data["audio"] as? String, !hex.isEmpty, let audio = Data(hex: hex),
                   let whole = assembler.push(audio) {
                    continuation.yield(.audio(whole))
                }
                let inline = Self.words(in: data["subtitle"] ?? data["subtitles"] ?? data["timestamped_words"])
                if !inline.isEmpty {
                    continuation.yield(.marks(inline.map {
                        aligner.place($0.text, startFrame: format.frames(seconds: $0.begin), endFrame: format.frames(seconds: $0.end))
                    }))
                }
                if let file = data["subtitle_file"] as? String, !file.isEmpty { subtitleFile = file }
            }
            if let file = subtitleFile, let fileURL = URL(string: file) {
                let (data, _) = try await TTSNetwork.session.data(from: fileURL)
                continuation.yield(.diagnostic(.note("minimax subtitle file: \(previewOfMessage(String(decoding: data, as: UTF8.self), limit: 1500))")))
                let object = try? JSONSerialization.jsonObject(with: data)
                let words = Self.words(in: object)
                if !words.isEmpty {
                    continuation.yield(.marks(words.map {
                        aligner.place($0.text, startFrame: format.frames(seconds: $0.begin), endFrame: format.frames(seconds: $0.end))
                    }))
                }
            }
        }
    }

    /// Word timings out of whatever shape MiniMax used: a list of sentences each
    /// with `timestamped_words`, or a flat list of words; times in ms under
    /// `time_begin`/`time_end` (or `begin_time`/`start_time`/`end_time`).
    static func words(in value: Any?) -> [(text: String, begin: Double, end: Double)] {
        guard let list = (value as? [[String: Any]]) ?? ((value as? [String: Any]).map { [$0] }) else { return [] }
        var out: [(String, Double, Double)] = []
        for item in list {
            if let nested = item["timestamped_words"] ?? item["words"] {
                out += words(in: nested)
                continue
            }
            guard let text = (item["word"] ?? item["text"]) as? String else { continue }
            let begin = (item["time_begin"] ?? item["begin_time"] ?? item["start_time"]) as? Double
            let end = (item["time_end"] ?? item["end_time"]) as? Double
            // Sentence-level entries (the non-word subtitle type) are skipped:
            // they cannot drive word highlighting.
            guard let begin, let end, text.count <= 12 else { continue }
            out.append((text, begin / 1000, end / 1000))
        }
        return out
    }
}
