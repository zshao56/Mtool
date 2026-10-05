import Foundation

/// 豆包语音合成 2.0 over the bidirectional WebSocket
/// (`wss://openspeech.bytedance.com/api/v3/tts/bidirection`,
/// volcengine.com/docs/6561/1329505).
///
/// Every message is a binary frame (integers big-endian):
///   byte 0  0x11 (protocol v1, 4-byte header)
///   byte 1  message type (high nibble) | flags (low nibble; 0b0100 = has event)
///   byte 2  serialization (high: 0 raw, 1 JSON) | compression (low: 0 none)
///   byte 3  0
///   then    int32 event, [uint32 id length + id], uint32 payload length + payload
/// Connection events (1/2/50/51/52) carry a connection id, session and data
/// events a session id. Error frames (type 0b1111) carry uint32 code instead.
///
/// Flow: StartConnection(1) → ConnectionStarted(50) → StartSession(100) →
/// SessionStarted(150) → TaskRequest(200) per sentence → FinishSession(102) →
/// audio (352), subtitles, … → SessionFinished(152) → FinishConnection(2).
/// Subtitles came as event 364 when measured (2026-09-28; the number is not in
/// the docs), so any JSON frame with `words` is taken as subtitles. As the docs
/// say, a clause's subtitles arrive only after all of that clause's audio.
struct VolcengineBidirectional {
    let settings: TTSSettings

    func synthesize(_ request: TTSRequest) throws -> TTSStream {
        let headers = try VolcengineEngine.authHeaders(settings)
        guard let url = URL(string: settings.string("endpoint", "wss://openspeech.bytedance.com/api/v3/tts/bidirection")) else {
            throw TTSError.missingSetting("endpoint")
        }
        let format = TTSAudioFormat(sampleRate: 24000, channels: 1)
        let params = VolcengineEngine.requestParams(settings, sampleRate: format.sampleRate)
        let text = request.text
        let trace = settings.bool("trace", false)
        let pieces = !settings.bool("splitSentences", true) ? [text]
            : settings.bool("quickStart", false) ? TextChunker.quickStartPieces(text) : TextChunker.sentences(text)

        return makeTTSStream(format: format) { continuation in
            var req = URLRequest(url: url)
            for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
            let socket = TTSWebSocket(req, continuation: continuation)
            defer { socket.close() }
            let session = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            func payload(event: Int, extra: [String: Any] = [:]) throws -> Data {
                var body: [String: Any] = ["user": ["uid": "mtool"], "event": event, "namespace": "BidirectionalTTS"]
                body.merge(extra) { _, new in new }
                return try JSONSerialization.data(withJSONObject: body)
            }

            try await socket.send(data: VolcFrame.client(event: 1, id: nil, payload: Data("{}".utf8)))
            var assembler = PCMAssembler(format: format)
            var aligner = MarkAligner(text: text)
            var sentTasks = false

            while true {
                try Task.checkCancellation()
                guard case .data(let bytes) = try await socket.receive() else { continue }
                let frame = try VolcFrame(parsing: bytes)
                if trace {
                    let what = frame.isAudio ? "audio \(frame.payload.count) bytes"
                        : "event \(frame.event ?? -1) \(previewOfMessage(String(decoding: frame.payload, as: UTF8.self), limit: 140))"
                    continuation.yield(.diagnostic(.note("trace " + what)))
                }
                if let code = frame.errorCode {
                    throw TTSError.provider("\(code) \(String(decoding: frame.payload, as: UTF8.self))")
                }
                switch frame.event {
                case 50:   // ConnectionStarted
                    var p = params
                    p["text"] = ""
                    try await socket.send(data: VolcFrame.client(event: 100, id: session,
                                                                 payload: try payload(event: 100, extra: ["req_params": p])))
                case 150:  // SessionStarted: send the text sentence by sentence, then finish
                    guard !sentTasks else { continue }
                    sentTasks = true
                    for piece in pieces {
                        var p = params
                        p["text"] = piece
                        try await socket.send(data: VolcFrame.client(event: 200, id: session,
                                                                     payload: try payload(event: 200, extra: ["req_params": p])))
                    }
                    try await socket.send(data: VolcFrame.client(event: 102, id: session, payload: Data("{}".utf8)))
                case 51, 153:  // ConnectionFailed, SessionFailed
                    throw TTSError.provider(String(decoding: frame.payload, as: UTF8.self))
                case 152:  // SessionFinished
                    try? await socket.send(data: VolcFrame.client(event: 2, id: nil, payload: Data("{}".utf8)))
                    return
                default:
                    if frame.isAudio {
                        if let whole = assembler.push(frame.payload) { continuation.yield(.audio(whole)) }
                    } else if let json = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any],
                              let words = json["words"] as? [[String: Any]], !words.isEmpty {
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
}

/// One frame of Volcengine's binary WebSocket protocol.
struct VolcFrame {
    var messageType: UInt8
    var event: Int?
    var errorCode: UInt32?
    var id: String?
    var payload: Data

    /// Audio-only response (type 0b1011), or raw serialization with event 352.
    var isAudio: Bool { messageType == 0b1011 }

    static func client(event: Int32, id: String?, payload: Data) -> Data {
        var d = Data([0x11, 0x14, 0x10, 0x00])
        d.appendBigEndian(UInt32(bitPattern: event))
        if let id {
            let idData = Data(id.utf8)
            d.appendBigEndian(UInt32(idData.count))
            d.append(idData)
        }
        d.appendBigEndian(UInt32(payload.count))
        d.append(payload)
        return d
    }

    init(parsing data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw TTSError.badResponse("frame of \(bytes.count) bytes") }
        let headerSize = Int(bytes[0] & 0x0F) * 4
        messageType = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        var i = headerSize
        func u32() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw TTSError.badResponse("truncated frame") }
            defer { i += 4 }
            return UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
        func chunk() throws -> Data {
            let n = Int(try u32())
            guard i + n <= bytes.count else { throw TTSError.badResponse("truncated frame") }
            defer { i += n }
            return Data(bytes[i..<(i + n)])
        }
        if messageType == 0b1111 {                 // error frame
            errorCode = try u32()
            payload = (try? chunk()) ?? Data(bytes[min(i, bytes.count)...])
            return
        }
        if flags & 0b0100 != 0 { event = Int(Int32(bitPattern: try u32())) }
        // Every event carries an id (connection or session) before the payload.
        if event != nil {
            let idData = try chunk()
            id = String(decoding: idData, as: UTF8.self)
        }
        payload = try chunk()
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
