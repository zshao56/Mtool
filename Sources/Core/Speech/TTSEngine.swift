import Foundation

/// One text-to-speech provider behind a common shape: text in, a stream of raw
/// PCM chunks and word/character timings out.
///
/// Every provider speaks a different protocol (HTTP chunks, SSE, WebSocket with
/// its own framing) and reports timings in its own units and granularity. An
/// adapter's whole job is to hide that: whatever the provider sends, the caller
/// sees `.audio` in the format declared up front and `.marks` whose ranges point
/// into the request text and whose times are sample frames counted from the
/// first sample of THIS stream. Frames rather than seconds so a timeline built
/// from several chunks, paused and resumed, never drifts.
protocol TTSEngine {
    static var descriptor: TTSEngineDescriptor { get }

    /// Start synthesizing. The stream ends when the provider is done; cancelling
    /// the consuming task must close the connection so nothing keeps
    /// downloading (or billing) after the user pressed stop.
    func synthesize(_ request: TTSRequest) throws -> TTSStream
}

struct TTSEngineDescriptor {
    let id: String
    let displayName: String
    /// How the provider reports timing. Providers with `.none` are not viable
    /// for read-aloud: word highlighting is a hard requirement.
    let marks: MarkGranularity
    let transport: String
}

enum MarkGranularity: String, Codable {
    case none, character, word, sentence
}

struct TTSRequest {
    let text: String
}

/// A provider's settings: a JSON object read with forgiving accessors, so a
/// hand-edited file with a number written as a string still works, and keys an
/// adapter does not know are simply ignored.
struct TTSSettings {
    let raw: [String: JSONValue]

    init(_ raw: [String: JSONValue]) { self.raw = raw }

    func string(_ key: String, _ fallback: String = "") -> String {
        let s = raw[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? fallback : s
    }
    func double(_ key: String, _ fallback: Double) -> Double { raw[key]?.doubleValue ?? fallback }
    func int(_ key: String, _ fallback: Int) -> Int { raw[key]?.doubleValue.map { Int($0) } ?? fallback }
    func bool(_ key: String, _ fallback: Bool) -> Bool { raw[key]?.boolValue ?? fallback }
    /// Free-form extra request fields, merged into the provider's body as-is.
    var extra: [String: Any] {
        guard let value = raw["extra"], let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

struct TTSAudioFormat: Equatable, Codable {
    /// Always signed 16-bit little-endian interleaved PCM; only the rate and
    /// channel count vary. Every adapter asks its provider for exactly this, so
    /// nothing downstream needs a decoder.
    let sampleRate: Int
    let channels: Int

    var bytesPerFrame: Int { 2 * channels }
    func seconds(frames: Int) -> Double { Double(frames) / Double(sampleRate) }
    func frames(seconds: Double) -> Int { Int((seconds * Double(sampleRate)).rounded()) }
}

struct TTSStream {
    let format: TTSAudioFormat
    let events: AsyncThrowingStream<TTSEvent, Error>
}

enum TTSEvent {
    /// Whole frames only — adapters carry a split sample over to the next chunk.
    case audio(Data)
    case marks([TextMark])
    /// Transport facts for measurement and logs; never needed for playback.
    case diagnostic(TTSDiagnostic)
}

struct TextMark: Codable, Equatable {
    /// UTF-16 range into `TTSRequest.text`; nil when the provider's word could
    /// not be found in the text (it was normalized beyond recognition).
    let location: Int?
    let length: Int
    /// What the provider said it spoke, kept for debugging alignment.
    let spoken: String
    let startFrame: Int
    let endFrame: Int
}

enum TTSDiagnostic {
    /// Response headers arrived (HTTP) or the socket opened (WebSocket).
    case connected(status: Int?)
    /// URLSession's timing breakdown, delivered when the task finishes.
    case connection(ConnectionTimings)
    /// Anything worth keeping in the run log (request id, provider message).
    case note(String)
}

struct ConnectionTimings: Codable, Equatable {
    var dnsMs: Double?
    var tcpMs: Double?
    var tlsMs: Double?
    var reused: Bool
    var remoteAddress: String?
    var networkProtocol: String?
}

enum TTSError: LocalizedError {
    case missingSetting(String)
    case http(status: Int, body: String)
    case provider(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingSetting(let key): return "missing setting: \(key)"
        case .http(let status, let body):
            let flat = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            return "HTTP \(status): \(flat.prefix(400))"
        case .provider(let message): return "provider error: \(message.prefix(400))"
        case .badResponse(let message): return "unexpected response: \(message.prefix(400))"
        }
    }
}
