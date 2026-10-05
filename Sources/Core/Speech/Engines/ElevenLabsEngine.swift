import Foundation

/// ElevenLabs `POST /v1/text-to-speech/{voice}/stream/with-timestamps`
/// (elevenlabs.io/docs/api-reference/text-to-speech/stream-with-timestamps).
///
/// One JSON object per line: `audio_base64` plus `alignment` with a start/end
/// time per CHARACTER of the original text. Characters are grouped back into
/// words here (a run of letters, or a single CJK character). The docs do not say
/// whether chunk times count from the stream start or restart per chunk, so
/// that is detected per chunk.
struct ElevenLabsEngine: TTSEngine {
    static let descriptor = TTSEngineDescriptor(id: "elevenlabs", displayName: "ElevenLabs",
                                                marks: .character, transport: "HTTP chunked")
    let settings: TTSSettings

    func synthesize(_ request: TTSRequest) throws -> TTSStream {
        let key = settings.string("apiKey")
        guard !key.isEmpty else { throw TTSError.missingSetting("apiKey") }
        let voice = settings.string("voice")
        guard !voice.isEmpty else { throw TTSError.missingSetting("voice (a voice id from your ElevenLabs account)") }
        let base = settings.string("baseURL", "https://api.elevenlabs.io")
        guard let url = URL(string: "\(base)/v1/text-to-speech/\(voice)/stream/with-timestamps?output_format=pcm_24000") else {
            throw TTSError.missingSetting("baseURL")
        }
        let format = TTSAudioFormat(sampleRate: 24000, channels: 1)
        var body: [String: Any] = [
            "text": request.text,
            "model_id": settings.string("model", "eleven_flash_v2_5"),
            // The API takes 0.7–1.2 and answers 400 to anything else.
            "voice_settings": ["speed": min(1.2, max(0.7, settings.double("speed", 1)))],
        ]
        body.merge(settings.extra) { _, new in new }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let text = request.text

        return makeTTSStream(format: format) { continuation in
            var assembler = PCMAssembler(format: format)
            var grouper = CharacterGrouper(text: text, format: format)
            var perChunk: Bool?
            try await TTSNetwork.streamLines(req, into: continuation) { line in
                guard let msg = jsonObject(line) else { return }
                let chunkStart = format.seconds(frames: assembler.framesEmitted)
                if let b64 = msg["audio_base64"] as? String, let audio = Data(base64Encoded: b64),
                   let whole = assembler.push(audio) {
                    continuation.yield(.audio(whole))
                }
                guard let alignment = msg["alignment"] as? [String: Any],
                      let chars = alignment["characters"] as? [String],
                      let starts = alignment["character_start_times_seconds"] as? [Double],
                      let ends = alignment["character_end_times_seconds"] as? [Double],
                      !chars.isEmpty, chars.count == starts.count, chars.count == ends.count else { return }
                // Decided once, on the first chunk well into the audio: times
                // near zero there mean they restart per chunk. Earlier chunks
                // start near zero either way, so the choice cannot affect them.
                if perChunk == nil, chunkStart > 0.3 {
                    perChunk = starts[0] < chunkStart / 2
                    continuation.yield(.diagnostic(.note("character times are \(perChunk! ? "per-chunk" : "stream-absolute")")))
                }
                let offset = perChunk == true ? chunkStart : 0
                let marks = grouper.push(chars: chars, starts: starts.map { $0 + offset }, ends: ends.map { $0 + offset })
                if !marks.isEmpty { continuation.yield(.marks(marks)) }
            }
            let tail = grouper.flush()
            if !tail.isEmpty { continuation.yield(.marks(tail)) }
        }
    }
}
