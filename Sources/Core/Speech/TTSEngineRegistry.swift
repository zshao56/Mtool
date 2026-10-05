import Foundation

/// Every adapter, by id. Adding a provider is one file plus one line here.
enum TTSEngineRegistry {
    static let all: [String: (TTSSettings) -> TTSEngine] = [
        VolcengineEngine.descriptor.id: { VolcengineEngine(settings: $0) },
        ElevenLabsEngine.descriptor.id: { ElevenLabsEngine(settings: $0) },
        MiniMaxEngine.descriptor.id:    { MiniMaxEngine(settings: $0) },
        QwenAudioEngine.descriptor.id:  { QwenAudioEngine(settings: $0) },
        CosyVoiceEngine.descriptor.id:  { CosyVoiceEngine(settings: $0) },
        GeminiEngine.descriptor.id:     { GeminiEngine(settings: $0) },
        SystemVoiceEngine.descriptor.id: { SystemVoiceEngine(settings: $0) },
    ]

    /// Adapters kept in the code but not run (decided 2026-09-28). Gemini: no
    /// word timings anywhere, and word highlighting is a hard requirement.
    /// CosyVoice: voice quality judged only average by ear, and its word
    /// timings arrive 1–2.6 s after first audio.
    /// Volcengine: subtitles only after each clause's audio is complete, on
    /// both HTTP and the bidirectional WebSocket — not real-time.
    /// Why each was kept or dropped: design/cloud-tts/provider-decisions.html.
    static let paused: Set<String> = [GeminiEngine.descriptor.id, CosyVoiceEngine.descriptor.id,
                                      VolcengineEngine.descriptor.id]

    static let descriptors: [String: TTSEngineDescriptor] = [
        VolcengineEngine.descriptor.id: VolcengineEngine.descriptor,
        ElevenLabsEngine.descriptor.id: ElevenLabsEngine.descriptor,
        MiniMaxEngine.descriptor.id:    MiniMaxEngine.descriptor,
        QwenAudioEngine.descriptor.id:  QwenAudioEngine.descriptor,
        CosyVoiceEngine.descriptor.id:  CosyVoiceEngine.descriptor,
        GeminiEngine.descriptor.id:     GeminiEngine.descriptor,
        SystemVoiceEngine.descriptor.id: SystemVoiceEngine.descriptor,
    ]
}
