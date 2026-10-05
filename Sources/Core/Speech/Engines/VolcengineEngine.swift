import Foundation

/// 豆包语音合成 2.0 (Volcengine seed-tts-2.0). Two transports, chosen by the
/// `transport` setting: `websocket` (default, the bidirectional endpoint in
/// VolcengineBidirectional.swift) or `http`, the V3 HTTP chunked endpoint
/// (volcengine.com/docs/6561/1598757) described below.
///
/// The response is newline-delimited JSON: `{"code":0,"data":"<base64 pcm>"}`
/// for audio, `{"code":0,"data":null,"sentence":{"words":[{word,startTime,endTime}]}}`
/// for word timings (seconds, relative to the whole session, words in the
/// original text), and `{"code":20000000}` at the end. Timings for a sentence may
/// arrive after the next sentence's audio.
struct VolcengineEngine: TTSEngine {
    static let descriptor = TTSEngineDescriptor(id: "volcengine", displayName: "豆包语音 (Volcengine)",
                                                marks: .word, transport: "WebSocket bidirectional / HTTP")
    let settings: TTSSettings

    /// Headers both transports authenticate with: the new console's single
    /// key, or the old console's app id + access key.
    static func authHeaders(_ settings: TTSSettings) throws -> [String: String] {
        let apiKey = settings.string("apiKey")
        let appId = settings.string("appId")
        let accessKey = settings.string("accessKey")
        var headers = ["X-Api-Resource-Id": settings.string("resourceId", "seed-tts-2.0"),
                       "X-Api-Request-Id": UUID().uuidString]
        if !apiKey.isEmpty {
            headers["X-Api-Key"] = apiKey
        } else if !appId.isEmpty, !accessKey.isEmpty {
            headers["X-Api-App-Id"] = appId
            headers["X-Api-Access-Key"] = accessKey
        } else {
            throw TTSError.missingSetting("apiKey (or appId + accessKey)")
        }
        return headers
    }

    /// `req_params` without the text: speaker, 24 kHz PCM, subtitles on, speed.
    static func requestParams(_ settings: TTSSettings, sampleRate: Int) -> [String: Any] {
        // Speed 1.0× = 0; the API maps 100 → 2.0× and −50 → 0.5×.
        let speechRate = Int(((settings.double("speed", 1) - 1) * 100).rounded())
        var audioParams: [String: Any] = [
            "format": "pcm", "sample_rate": sampleRate, "enable_subtitle": true,
            "speech_rate": max(-50, min(100, speechRate)),
        ]
        audioParams.merge(settings.extra["audio_params"] as? [String: Any] ?? [:]) { _, new in new }
        var params: [String: Any] = [
            "speaker": settings.string("voice", "zh_female_vv_uranus_bigtts"),
            "audio_params": audioParams,
        ]
        if let additions = settings.extra["additions"] {
            // The API wants a string holding JSON, not an object.
            params["additions"] = (additions as? String)
                ?? String(decoding: (try? JSONSerialization.data(withJSONObject: additions)) ?? Data(), as: UTF8.self)
        }
        return params
    }

    func synthesize(_ request: TTSRequest) throws -> TTSStream {
        if settings.string("transport", "websocket") != "http" {
            return try VolcengineBidirectional(settings: settings).synthesize(request)
        }
        let headers = try Self.authHeaders(settings)
        guard let url = URL(string: settings.string("endpoint", "https://openspeech.bytedance.com/api/v3/tts/unidirectional")) else {
            throw TTSError.missingSetting("endpoint")
        }
        let format = TTSAudioFormat(sampleRate: 24000, channels: 1)
        var reqParams = Self.requestParams(settings, sampleRate: format.sampleRate)
        reqParams["text"] = request.text
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["user": ["uid": "mtool"], "req_params": reqParams])
        let text = request.text

        return makeTTSStream(format: format) { continuation in
            var assembler = PCMAssembler(format: format)
            var aligner = MarkAligner(text: text)
            var previews = 0
            let trace = settings.bool("trace", false)
            try await TTSNetwork.streamLines(req, into: continuation) { line in
                guard let msg = jsonObject(line) else { return }
                if trace {
                    let words = ((msg["sentence"] as? [String: Any])?["words"] as? [Any])?.count
                    let kind = msg["data"] is String ? "audio \((msg["data"] as! String).count * 3 / 4) bytes"
                        : words.map { "subtitle \($0) words: \(((msg["sentence"] as? [String: Any])?["text"] as? String ?? "").prefix(30))" }
                        ?? previewOfMessage(line, limit: 120)
                    continuation.yield(.diagnostic(.note("trace " + kind)))
                }
                if previews < 3, !(msg["data"] is String) {
                    previews += 1
                    continuation.yield(.diagnostic(.note("volcengine: \(previewOfMessage(line))")))
                }
                let code = msg["code"] as? Int ?? 0
                if code == 20000000 { return }
                if code != 0 { throw TTSError.provider("\(code) \(msg["message"] ?? "")") }
                if let b64 = msg["data"] as? String, let audio = Data(base64Encoded: b64),
                   let whole = assembler.push(audio) {
                    continuation.yield(.audio(whole))
                }
                if let sentence = msg["sentence"] as? [String: Any],
                   let words = sentence["words"] as? [[String: Any]], !words.isEmpty {
                    let marks = words.map { w in
                        aligner.place(w["word"] as? String ?? "",
                                      startFrame: format.frames(seconds: w["startTime"] as? Double ?? 0),
                                      endFrame: format.frames(seconds: w["endTime"] as? Double ?? 0))
                    }
                    continuation.yield(.marks(marks))
                }
            }
        }
    }
}
