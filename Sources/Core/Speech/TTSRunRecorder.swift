import Foundation

/// Drains a `TTSStream`, timestamps everything that arrives, and computes the
/// numbers that decide whether a provider is usable for read-aloud.
///
/// All times are milliseconds from `start` — the moment just before the
/// request was issued. Audio positions are seconds of audio received so far.
struct TTSRunRecorder {

    struct Chunk: Codable { let arrivalMs: Double; let audioStartSec: Double; let seconds: Double }
    struct MarkArrival: Codable { let arrivalMs: Double; let mark: TextMark }

    private(set) var format: TTSAudioFormat
    private(set) var chunks: [Chunk] = []
    private(set) var marks: [MarkArrival] = []
    private(set) var pcm = Data()
    private(set) var connectedMs: Double?
    private(set) var httpStatus: Int?
    private(set) var connection: ConnectionTimings?
    private(set) var notes: [String] = []
    private(set) var endMs: Double = 0
    private(set) var error: String?
    private let start: DispatchTime

    init(format: TTSAudioFormat, start: DispatchTime) {
        self.format = format
        self.start = start
    }

    /// A recording made up front — for tests of the metrics arithmetic.
    init(format: TTSAudioFormat, chunks: [(arrivalMs: Double, frames: Int)], marks: [MarkArrival], endMs: Double) {
        self.format = format
        self.start = .now()
        var audio = 0.0
        for c in chunks {
            let seconds = format.seconds(frames: c.frames)
            self.chunks.append(Chunk(arrivalMs: c.arrivalMs, audioStartSec: audio, seconds: seconds))
            audio += seconds
            pcm.append(Data(count: c.frames * format.bytesPerFrame))
        }
        self.marks = marks
        self.endMs = endMs
    }

    private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6 }

    mutating func drain(_ stream: TTSStream) async {
        do {
            for try await event in stream.events {
                let t = now()
                switch event {
                case .audio(let data):
                    let frames = data.count / format.bytesPerFrame
                    guard frames > 0 else { continue }
                    chunks.append(Chunk(arrivalMs: t, audioStartSec: audioSeconds,
                                        seconds: format.seconds(frames: frames)))
                    pcm.append(data)
                case .marks(let list):
                    marks += list.map { MarkArrival(arrivalMs: t, mark: $0) }
                case .diagnostic(.connected(let status)):
                    if connectedMs == nil { connectedMs = t; httpStatus = status }
                case .diagnostic(.connection(let timings)):
                    connection = timings
                case .diagnostic(.note(let note)):
                    notes.append(String(format: "%7.0f ms  ", t) + note)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        endMs = now()
    }

    var audioSeconds: Double { format.seconds(frames: pcm.count / format.bytesPerFrame) }
}

/// The verdict for one run. Field meanings are spelled out in
/// Tools/SpeechBench/README.md; they are the contract of the benchmark.
struct TTSRunMetrics: Codable {
    var provider = ""
    var textId = ""
    var textChars = 0
    var attempt = 0
    var error: String?

    var dnsMs: Double?
    var tcpMs: Double?
    var tlsMs: Double?
    var reusedConnection: Bool?
    var networkProtocol: String?
    /// Headers back (HTTP) or socket open (WebSocket).
    var connectedMs: Double?
    /// First audio byte in hand: the earliest sound could possibly start.
    var firstAudioMs: Double?
    /// First word timing in hand: the earliest highlighting could start.
    var firstMarkMs: Double?
    /// The whole stream finished.
    var totalMs = 0.0
    var audioSec = 0.0
    var chunks = 0

    /// Wall time to synthesize per second of audio, whole run. < 1 = faster than real time.
    var rtf: Double?
    /// The same, counted from the first audio byte (the part that races playback).
    var streamingRtf: Double?

    /// The earliest moment playback can start and never run dry, given when
    /// each chunk actually arrived: max over chunks of (arrival − audio before it).
    var noStallStartMs: Double?
    /// How much later than first audio that is. This is the extra buffering the
    /// player needs; ≤ the budget means the provider keeps up with real time.
    var bufferNeededMs: Double?
    /// Starting playback at first audio + the budget: how often and for how long it would stall.
    var stallsAtBudget = 0
    var stallMsAtBudget = 0.0
    var keepsUpWithRealTime: Bool?

    /// Share of the text's letters/characters covered by a located mark.
    var markCoverage: Double?
    /// Marks the provider sent that could not be found in the text.
    var marksUnplaced = 0
    var marksTotal = 0
    /// With playback starting at max(noStallStart, first audio + budget), how
    /// many marks arrived after their word was already audible, and the worst lateness.
    var marksLate = 0
    var worstMarkLateMs: Double?

    /// Sound that could reach the user's ears: first audio + buffering needed.
    var effectiveFirstSoundMs: Double?
}

extension TTSRunRecorder {
    func metrics(provider: String, textId: String, text: String, attempt: Int,
                 bufferBudgetMs: Double) -> TTSRunMetrics {
        var m = TTSRunMetrics()
        m.provider = provider
        m.textId = textId
        m.textChars = text.count
        m.attempt = attempt
        m.error = error
        m.dnsMs = connection?.dnsMs
        m.tcpMs = connection?.tcpMs
        m.tlsMs = connection?.tlsMs
        m.reusedConnection = connection?.reused
        m.networkProtocol = connection?.networkProtocol
        m.connectedMs = connectedMs
        m.firstAudioMs = chunks.first?.arrivalMs
        m.firstMarkMs = marks.first?.arrivalMs
        m.totalMs = endMs
        m.audioSec = audioSeconds
        m.chunks = chunks.count

        guard let first = chunks.first?.arrivalMs, audioSeconds > 0 else { return m }
        let lastArrival = chunks.last!.arrivalMs
        m.rtf = endMs / 1000 / audioSeconds
        m.streamingRtf = (lastArrival - first) / 1000 / audioSeconds

        let noStall = chunks.map { $0.arrivalMs - $0.audioStartSec * 1000 }.max() ?? first
        m.noStallStartMs = noStall
        m.bufferNeededMs = max(0, noStall - first)
        m.effectiveFirstSoundMs = max(noStall, first)

        // Simulate a player that starts at first audio + budget and pauses
        // whenever it runs out.
        var clock = first + bufferBudgetMs
        for chunk in chunks {
            if chunk.arrivalMs > clock {
                m.stallsAtBudget += 1
                m.stallMsAtBudget += chunk.arrivalMs - clock
                clock = chunk.arrivalMs
            }
            clock += chunk.seconds * 1000
        }
        m.keepsUpWithRealTime = m.stallsAtBudget == 0 && error == nil

        if !marks.isEmpty {
            m.marksTotal = marks.count
            // Punctuation some providers time as a "word" has nothing to highlight.
            m.marksUnplaced = marks.filter { $0.mark.location == nil && !MarkAligner.fold($0.mark.spoken).isEmpty }.count
            let playStart = max(noStall, first + bufferBudgetMs)
            var worst = 0.0
            for arrival in marks {
                let due = playStart + format.seconds(frames: arrival.mark.startFrame) * 1000
                let late = arrival.arrivalMs - due
                if late > 0 { m.marksLate += 1; worst = max(worst, late) }
            }
            m.worstMarkLateMs = m.marksLate > 0 ? worst : 0
            m.markCoverage = Self.coverage(text: text, marks: marks.map(\.mark))
        }
        return m
    }

    /// Fraction of letters/ideographs (not spaces or punctuation) that fall
    /// inside some located mark.
    static func coverage(text: String, marks: [TextMark]) -> Double {
        let ns = text as NSString
        var covered = IndexSet()
        for mark in marks { if let loc = mark.location { covered.insert(integersIn: loc..<(loc + mark.length)) } }
        var total = 0, hit = 0
        var i = 0
        while i < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: i)
            if !MarkAligner.fold(ns.substring(with: range)).isEmpty {
                total += 1
                if covered.contains(i) { hit += 1 }
            }
            i += range.length
        }
        return total == 0 ? 0 : Double(hit) / Double(total)
    }

    /// The audio as a 16-bit PCM WAV file, for listening to what was measured.
    func wav() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(UInt16(format.channels))
        u32(UInt32(format.sampleRate)); u32(UInt32(format.sampleRate * format.bytesPerFrame))
        u16(UInt16(format.bytesPerFrame)); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
