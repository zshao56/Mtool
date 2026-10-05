import AVFoundation

/// Plays 16-bit PCM as it arrives and reports where playback is, in frames of
/// the whole read — the clock word highlighting runs on.
///
/// Everything received is kept (a read is a few MB), so seeking, replaying and
/// recovering from an output-device change are all "schedule again from frame
/// N". The position is `baseFrame` (where the node's timeline started) plus the
/// node's own sample time, clamped to what was actually scheduled.
///
/// Running dry is handled by stopping the node when its last buffer has
/// played and restarting it from exactly there once enough new audio has
/// arrived; letting it run on in silence would push the clock ahead of the
/// audio and every highlight after it would be early.
///
/// Main thread only.
final class StreamingPCMPlayer {
    let format: TTSAudioFormat
    /// Called once, when every frame of a finished input has been played.
    var onFinish: (() -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let floatFormat: AVAudioFormat
    private(set) var pcm = Data()
    private var inputFinished = false
    private var baseFrame = 0
    private var scheduledFrames = 0
    private var outstanding = 0
    /// Bumped whenever the node is stopped, so completion callbacks from
    /// buffers it flushed are ignored.
    private var generation = 0
    private var nodeRunning = false
    private var userPaused = false
    private var pausedPosition: Int?
    private var finished = false
    /// Stopped for good: nothing — not even an output-device change — restarts it.
    private var stopped = false
    private var configObserver: NSObjectProtocol?
    private static let log = FileLog("Speech.Player")

    /// Audio to have in hand before starting (or restarting after running dry).
    private var prebufferFrames: Int { format.sampleRate / 5 }

    init(format: TTSAudioFormat) {
        self.format = format
        floatFormat = AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate),
                                    channels: AVAudioChannelCount(format.channels))!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: floatFormat)
        // AirPods connecting mid-read stop the engine; pick up where it was.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.recoverFromConfigurationChange() }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
    }

    var totalFrames: Int { pcm.count / format.bytesPerFrame }
    var isPaused: Bool { userPaused }
    var isFinished: Bool { finished }

    /// Frames of the read played so far.
    var position: Int {
        if let pausedPosition { return pausedPosition }
        guard nodeRunning, let render = node.lastRenderTime,
              let time = node.playerTime(forNodeTime: render) else { return baseFrame }
        return min(scheduledFrames, baseFrame + max(0, Int(time.sampleTime)))
    }

    // MARK: - Input

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        pcm.append(data)
        if nodeRunning { scheduleAvailable() } else { startIfReady() }
    }

    func finishInput() {
        inputFinished = true
        if nodeRunning { scheduleAvailable() } else { startIfReady() }
        if nodeRunning, outstanding == 0 { drained() }
    }

    /// A whole read at once (from the cache).
    func load(_ data: Data) {
        pcm = data
        finishInput()
    }

    // MARK: - Control

    func pause() {
        guard !userPaused, !finished else { return }
        pausedPosition = position
        userPaused = true
        if nodeRunning { node.pause() }
    }

    func resume() {
        guard userPaused else { return }
        userPaused = false
        pausedPosition = nil
        if nodeRunning { node.play() } else { startIfReady() }
    }

    /// Play again from `frame`. After the end, this is Replay.
    func seek(to frame: Int) {
        stopNode()
        finished = false
        baseFrame = max(0, min(frame, totalFrames))
        scheduledFrames = baseFrame
        pausedPosition = userPaused ? baseFrame : nil
        startIfReady()
    }

    func stop() {
        stopped = true
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        stopNode()
        engine.stop()
        onFinish = nil
    }

    // MARK: - Internals

    private func startIfReady() {
        guard !userPaused, !finished, !stopped else { return }
        let ahead = totalFrames - scheduledFrames
        guard ahead >= prebufferFrames || (inputFinished && ahead > 0) else {
            if inputFinished, ahead == 0, scheduledFrames >= totalFrames, totalFrames > 0 { finish() }
            return
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            Self.log.error("audio engine failed to start: \(error.localizedDescription)")
            return
        }
        scheduleAvailable()
        node.play()
        nodeRunning = true
    }

    private func scheduleAvailable() {
        let chunk = format.sampleRate / 10   // 100 ms buffers
        while scheduledFrames < totalFrames {
            let count = min(chunk, totalFrames - scheduledFrames)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(count)),
                  let out = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(count)
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0..<count {
                    out[i] = Float(Int16(littleEndian: samples[scheduledFrames + i])) / 32768
                }
            }
            scheduledFrames += count
            outstanding += 1
            let gen = generation
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    self.outstanding -= 1
                    if self.outstanding == 0 { self.drained() }
                }
            }
        }
    }

    /// Everything scheduled has been heard: either the end, or the network is
    /// behind — then wait, from exactly here, for more.
    private func drained() {
        if inputFinished && scheduledFrames >= totalFrames {
            finish()
        } else {
            let here = scheduledFrames
            stopNode()
            baseFrame = here
            scheduledFrames = here
            startIfReady()
        }
    }

    private func finish() {
        guard !finished else { return }
        stopNode()
        baseFrame = totalFrames
        scheduledFrames = totalFrames
        finished = true
        onFinish?()
    }

    private func stopNode() {
        generation &+= 1
        outstanding = 0
        if nodeRunning || node.isPlaying { node.stop() }
        nodeRunning = false
    }

    private func recoverFromConfigurationChange() {
        let here = position
        Self.log.info("output changed; resuming at frame \(here)")
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: floatFormat)
        guard !finished, !stopped else { return }
        seek(to: here)
    }
}
