import Foundation

/// Network plumbing shared by every adapter, so each provider file only says how
/// to build its request and how to read its replies.
enum TTSNetwork {
    /// One session for every provider, so a second read reuses the TLS
    /// connection. The benchmark swaps it out to measure a cold start.
    private(set) static var session = makeSession()

    static func resetSession() {
        session.invalidateAndCancel()
        session = makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // A read that has not produced audio in this long has failed; the
        // default 60 s would leave the user staring at silence.
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    /// Stream an HTTP response line by line. Emits `.connected` when headers
    /// arrive and `.connection` timings when the task ends; a non-2xx status
    /// becomes `TTSError.http` carrying the body the provider sent back.
    static func streamLines(_ request: URLRequest,
                            into continuation: AsyncThrowingStream<TTSEvent, Error>.Continuation,
                            onLine: (String) throws -> Void) async throws {
        let metrics = MetricsDelegate { continuation.yield(.diagnostic(.connection($0))) }
        let (bytes, response) = try await session.bytes(for: request, delegate: metrics)
        let status = (response as? HTTPURLResponse)?.statusCode
        continuation.yield(.diagnostic(.connected(status: status)))
        if let status, !(200..<300).contains(status) {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 8192 { break } }
            throw TTSError.http(status: status, body: String(decoding: body, as: UTF8.self))
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try onLine(line)
        }
    }

    static func timings(from metrics: URLSessionTaskMetrics) -> ConnectionTimings? {
        guard let t = metrics.transactionMetrics.last else { return nil }
        func ms(_ a: Date?, _ b: Date?) -> Double? {
            guard let a, let b else { return nil }
            return b.timeIntervalSince(a) * 1000
        }
        return ConnectionTimings(dnsMs: ms(t.domainLookupStartDate, t.domainLookupEndDate),
                                 tcpMs: ms(t.connectStartDate, t.secureConnectionStartDate ?? t.connectEndDate),
                                 tlsMs: ms(t.secureConnectionStartDate, t.secureConnectionEndDate),
                                 reused: t.isReusedConnection,
                                 remoteAddress: nil, // never logged: an IP is personal data
                                 networkProtocol: t.networkProtocolName)
    }
}

final class MetricsDelegate: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
    private let onMetrics: (ConnectionTimings) -> Void
    var onOpen: (() -> Void)?

    init(onMetrics: @escaping (ConnectionTimings) -> Void) { self.onMetrics = onMetrics }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        if let t = TTSNetwork.timings(from: metrics) { onMetrics(t) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onOpen?()
    }
}

/// A WebSocket with async send/receive. Opening is reported through
/// `.connected`; the receive loop belongs to the adapter.
final class TTSWebSocket {
    let task: URLSessionWebSocketTask
    private let delegate: MetricsDelegate

    init(_ request: URLRequest, continuation: AsyncThrowingStream<TTSEvent, Error>.Continuation) {
        delegate = MetricsDelegate { continuation.yield(.diagnostic(.connection($0))) }
        delegate.onOpen = { continuation.yield(.diagnostic(.connected(status: 101))) }
        task = TTSNetwork.session.webSocketTask(with: request)
        task.delegate = delegate
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
    }

    func send(json object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        do { try await task.send(.string(String(decoding: data, as: UTF8.self))) }
        catch { throw explained(error) }
    }

    func send(data: Data) async throws {
        do { try await task.send(.data(data)) }
        catch { throw explained(error) }
    }

    /// `URLSessionWebSocketTask.receive()` ignores Swift task cancellation, so
    /// a stopped read would sit waiting (and the server keep synthesizing)
    /// until the next message; cancelling the socket wakes it.
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withTaskCancellationHandler {
            do { return try await task.receive() }
            catch { throw Task.isCancelled ? CancellationError() : explained(error) }
        } onCancel: { [task] in
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    /// A refused handshake surfaces as a vague "bad response"; the status code
    /// is what tells a wrong key from a wrong address.
    private func explained(_ error: Error) -> Error {
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            return TTSError.http(status: http.statusCode, body: "WebSocket handshake rejected")
        }
        return error
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

/// Turns arbitrary byte chunks into whole 16-bit frames: a provider may split a
/// sample across two chunks, and a half sample handed to the player would shift
/// every sample after it by one byte — loud noise.
struct PCMAssembler {
    let format: TTSAudioFormat
    private var carry = Data()
    private(set) var framesEmitted = 0

    init(format: TTSAudioFormat) { self.format = format }

    mutating func push(_ bytes: Data) -> Data? {
        carry.append(bytes)
        let whole = carry.count - carry.count % format.bytesPerFrame
        guard whole > 0 else { return nil }
        let out = carry.prefix(whole)
        carry = Data(carry.dropFirst(whole))
        framesEmitted += whole / format.bytesPerFrame
        return Data(out)
    }
}

/// Wraps an adapter's async body in a stream whose cancellation cancels the
/// body — so stopping playback closes the connection.
func makeTTSStream(format: TTSAudioFormat,
                   _ body: @escaping (AsyncThrowingStream<TTSEvent, Error>.Continuation) async throws -> Void) -> TTSStream {
    let events = AsyncThrowingStream<TTSEvent, Error> { continuation in
        let task = Task {
            do {
                try await body(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
    return TTSStream(format: format, events: events)
}

extension Data {
    init?(hex: String) {
        var data = Data(capacity: hex.utf8.count / 2)
        var high: UInt8?
        for c in hex.utf8 {
            let v: UInt8
            switch c {
            case 48...57: v = c - 48
            case 97...102: v = c - 87
            case 65...70: v = c - 55
            default: return nil
            }
            if let h = high { data.append(h << 4 | v); high = nil } else { high = v }
        }
        self = data
    }
}

func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// Strip an SSE `data:` prefix; nil for comments, `event:` lines and blanks.
func sseData(_ line: String) -> String? {
    guard line.hasPrefix("data:") else { return nil }
    return line.dropFirst(5).trimmingCharacters(in: .whitespaces)
}

/// A provider message with every long string (audio payloads) replaced by its
/// length — safe and small enough to keep in the run notes, where it shows the
/// real response shape when a provider does not match its docs.
func previewOfMessage(_ text: String, limit: Int = 600) -> String {
    let collapsed = text.replacingOccurrences(of: "\"[^\"]{160,}\"", with: "\"<long string>\"",
                                              options: .regularExpression)
    return String(collapsed.prefix(limit))
}
