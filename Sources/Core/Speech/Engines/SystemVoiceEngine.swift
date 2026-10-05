import AVFoundation

/// The macOS system voice rendered to PCM through `AVSpeechSynthesizer.write`.
///
/// In the benchmark it is the baseline every cloud provider is compared with,
/// and the one engine that can be measured without any key — it proves the
/// measuring itself works. (In the app, system speech keeps playing itself; see
/// design/cloud-tts/plan.html §三.)
struct SystemVoiceEngine: TTSEngine {
    static let descriptor = TTSEngineDescriptor(id: "system", displayName: "macOS system voice",
                                                marks: .word, transport: "local")
    let settings: TTSSettings
    private let format = TTSAudioFormat(sampleRate: 24000, channels: 1)

    func synthesize(_ request: TTSRequest) throws -> TTSStream {
        let language = settings.string("language", request.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } ? "zh-CN" : "en-US")
        let voiceId = settings.string("voice")
        let format = self.format
        return makeTTSStream(format: format) { continuation in
            let utterance = AVSpeechUtterance(string: request.text)
            utterance.voice = voiceId.isEmpty ? AVSpeechSynthesisVoice(language: language)
                                              : AVSpeechSynthesisVoice(identifier: voiceId)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(settings.double("speed", 1))
            let render = SystemRender(format: format, continuation: continuation)
            try await render.run(utterance)
        }
    }
}

/// Holds the synthesizer alive for the duration of one render and converts
/// whatever format the voice produces into 24 kHz mono Int16.
///
/// Two things `write` does that its docs do not say (measured 2026-09-28,
/// macOS 27): a long utterance is rendered in several internal segments, each
/// ending with an EMPTY buffer — so an empty buffer is not the end, the
/// delegate's didFinish is — and marker `byteSampleOffset`s restart from 0 in
/// each segment.
private final class SystemRender: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let format: TTSAudioFormat
    private let continuation: AsyncThrowingStream<TTSEvent, Error>.Continuation
    private var converter: AVAudioConverter?
    private var sourceFrames = 0          // all frames the voice has produced
    private var segmentBase = 0           // source frame where the current segment began
    private var sourceRate = 0.0
    private var sourceBytesPerFrame = 0
    private var done: CheckedContinuation<Void, Error>?
    /// Word markers that came before the first buffer told us the voice's format.
    private var pendingMarkers: [AVSpeechSynthesisMarker] = []
    /// Buffer, marker and delegate callbacks arrive on the synthesizer's own
    /// threads; every piece of state above is touched only on this queue, which
    /// also keeps the audio and marks in the order they were produced.
    private let queue = DispatchQueue(label: "SystemRender")

    init(format: TTSAudioFormat, continuation: AsyncThrowingStream<TTSEvent, Error>.Continuation) {
        self.format = format
        self.continuation = continuation
        super.init()
        synthesizer.delegate = self
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish() }

    private func finish() {
        queue.async { [self] in
            done?.resume()
            done = nil
        }
    }

    func run(_ utterance: AVSpeechUtterance) async throws {
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(format.sampleRate),
                                   channels: 1, interleaved: true)!
        continuation.yield(.diagnostic(.connected(status: nil)))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                DispatchQueue.main.async { [self] in
                    self.done = done
                    synthesizer.write(utterance, toBufferCallback: { [self] buffer in
                        queue.async { self.handle(buffer, target: target) }
                    }, toMarkerCallback: { [self] markers in
                        queue.async { self.handle(markers) }
                    })
                }
            }
        } onCancel: { [synthesizer] in
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func handle(_ buffer: AVAudioBuffer, target: AVAudioFormat) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        guard pcm.frameLength > 0 else {       // end of an internal segment
            segmentBase = sourceFrames
            return
        }
        if converter == nil {
            converter = AVAudioConverter(from: pcm.format, to: target)
            sourceRate = pcm.format.sampleRate
            sourceBytesPerFrame = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        }
        sourceFrames += Int(pcm.frameLength)
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * target.sampleRate / pcm.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        _ = converter?.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        if out.frameLength > 0, let ch = out.int16ChannelData {
            continuation.yield(.audio(Data(bytes: ch[0], count: Int(out.frameLength) * 2)))
        }
        if !pendingMarkers.isEmpty {
            let pending = pendingMarkers
            pendingMarkers = []
            handle(pending)
        }
    }

    private func handle(_ markers: [AVSpeechSynthesisMarker]) {
        guard sourceRate > 0 else { pendingMarkers += markers; return }
        let marks = markers.filter { $0.mark == .word }.map { marker -> TextMark in
            let local = sourceBytesPerFrame > 0 ? Int(marker.byteSampleOffset) / sourceBytesPerFrame : 0
            let source = segmentBase + local
            let frame = sourceRate > 0 ? Int(Double(source) * Double(format.sampleRate) / sourceRate) : 0
            let location = marker.textRange.location == NSNotFound ? nil : marker.textRange.location
            return TextMark(location: location, length: marker.textRange.length,
                            spoken: "", startFrame: frame, endFrame: frame)
        }
        if !marks.isEmpty { continuation.yield(.marks(marks)) }
    }
}
