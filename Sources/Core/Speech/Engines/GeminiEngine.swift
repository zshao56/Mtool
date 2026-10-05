import Foundation

/// Google Gemini TTS over `streamGenerateContent?alt=sse`
/// (ai.google.dev/gemini-api/docs/generate-content/speech-generation).
///
/// Gemini returns NO word timings anywhere (Gemini API, Cloud TTS, Chirp 3 HD
/// — checked 2026-09-28), so it fails the highlighting requirement. It is here
/// to measure its latency for comparison only.
struct GeminiEngine: TTSEngine {
    static let descriptor = TTSEngineDescriptor(id: "gemini", displayName: "Google Gemini TTS",
                                                marks: .none, transport: "HTTP SSE")
    let settings: TTSSettings

    func synthesize(_ request: TTSRequest) throws -> TTSStream {
        let key = settings.string("apiKey")
        guard !key.isEmpty else { throw TTSError.missingSetting("apiKey") }
        let model = settings.string("model", "gemini-3.8-flash-tts")
        let base = settings.string("baseURL", "https://generativelanguage.googleapis.com/v1beta")
        guard let url = URL(string: "\(base)/models/\(model):streamGenerateContent?alt=sse") else {
            throw TTSError.missingSetting("baseURL")
        }
        let format = TTSAudioFormat(sampleRate: 24000, channels: 1)
        var generation: [String: Any] = [
            "responseModalities": ["AUDIO"],
            // The 3.8 single-speaker form; 2.5/3.1 used prebuiltVoiceConfig.voiceName,
            // which can be supplied through "extra" if needed.
            "speechConfig": ["voiceConfig": ["voice": settings.string("voice", "Kore")]],
        ]
        generation.merge(settings.extra) { _, new in new }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": request.text]]]],
            "generationConfig": generation,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        return makeTTSStream(format: format) { continuation in
            var assembler = PCMAssembler(format: format)
            try await TTSNetwork.streamLines(req, into: continuation) { line in
                guard let payload = sseData(line), let event = jsonObject(payload) else { return }
                if let error = event["error"] as? [String: Any] {
                    throw TTSError.provider("\(error["message"] ?? error)")
                }
                let candidates = event["candidates"] as? [[String: Any]] ?? []
                let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                for part in parts {
                    guard let inline = part["inlineData"] as? [String: Any],
                          let b64 = inline["data"] as? String, let audio = Data(base64Encoded: b64) else { continue }
                    if let mime = inline["mimeType"] as? String, !mime.contains("rate=24000") {
                        continuation.yield(.diagnostic(.note("unexpected audio type \(mime)")))
                    }
                    if let whole = assembler.push(audio) { continuation.yield(.audio(whole)) }
                }
            }
        }
    }
}
