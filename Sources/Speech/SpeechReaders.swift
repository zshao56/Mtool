import Foundation
import SwiftUI

/// A voice the user set up to read text aloud: one provider, model, voice and
/// speed, under a name the user chose ("Qwen 女声", "Japanese"). Speak actions
/// pick a reader by `id`; the macOS system voice is always available as the
/// reader `SpeechReader.systemID` and is not stored.
///
/// Only providers that stream and send word timings in real time are offered
/// (word highlighting is a hard requirement). First sound ≤ 800 ms is not: a
/// slower model such as ElevenLabs v3 is offered and the user picks — see
/// design/cloud-tts/provider-decisions.html.
struct SpeechReader: Identifiable, Equatable {
    static let systemID = "system"

    var id: String
    var name: String
    /// A `TTSEngineRegistry` id, e.g. "qwen-audio".
    var engine: String
    var model: String
    var voice: String
    /// Playback speed as a multiplier, 1.0 = normal.
    var speed: Double
    /// "cn" (mainland endpoint) or "intl" (international endpoint).
    var region: String

    var isSystem: Bool { id == Self.systemID }

    static func system() -> SpeechReader {
        SpeechReader(id: systemID, name: L("speech.reader.system"), engine: "system", model: "", voice: "",
                     speed: 1, region: "")
    }

    /// Settings handed to the engine adapter, with the provider's API key.
    func engineSettings(apiKey: String) -> TTSSettings {
        TTSSettings([
            "apiKey": .string(apiKey), "model": .string(model), "voice": .string(voice),
            "speed": .number(speed), "region": .string(region),
        ])
    }

    /// The speed the provider actually reads at: a stored speed outside the
    /// provider's range (ElevenLabs takes 0.7–1.2) counts as the nearest end.
    var effectiveSpeed: Double {
        let range = SpeechProviders.find(engine)?.speedRange ?? 0.5...2
        return min(max(speed, range.lowerBound), range.upperBound)
    }

    /// What decides whether two reads sound the same — the cache key's reader half.
    var cacheIdentity: String { [engine, model, voice, String(format: "%.2f", effectiveSpeed), region].joined(separator: "|") }

    // MARK: - Config file

    init(id: String, name: String, engine: String, model: String, voice: String, speed: Double, region: String) {
        self.id = id; self.name = name; self.engine = engine; self.model = model
        self.voice = voice; self.speed = speed; self.region = region
    }

    /// From one entry of `speech.readers`. Unknown keys are kept in `extra` so a
    /// hand-edited or newer file loses nothing when the app writes it back.
    init?(json: JSONValue) {
        guard let o = json.objectValue, let id = o["id"]?.stringValue, !id.isEmpty, id != Self.systemID,
              let engine = o["engine"]?.stringValue, SpeechProviders.find(engine) != nil else { return nil }
        let provider = SpeechProviders.find(engine)!
        self.id = id
        self.name = o["name"]?.stringValue ?? provider.displayName
        self.engine = engine
        self.model = o["model"]?.stringValue ?? provider.defaultModel
        self.voice = o["voice"]?.stringValue ?? provider.defaultVoice
        self.speed = min(2, max(0.5, o["speed"]?.doubleValue ?? 1))
        self.region = o["region"]?.stringValue ?? "cn"
        self.extra = o.filter { !Self.ownKeys.contains($0.key) }
    }

    private static let ownKeys: Set<String> = ["id", "name", "engine", "model", "voice", "speed", "region"]
    private var extra: [String: JSONValue] = [:]

    var json: JSONValue {
        var o = extra
        o["id"] = .string(id); o["name"] = .string(name); o["engine"] = .string(engine)
        o["model"] = .string(model); o["voice"] = .string(voice); o["speed"] = .number(speed)
        o["region"] = .string(region)
        return .object(o)
    }
}

/// The providers a reader can use, with what the settings page offers for each.
struct SpeechProvider {
    struct Voice: Identifiable { let id: String; let label: String }
    let id: String
    let displayName: String
    /// Name given to a new reader: "Qwen", then "Qwen 2", …
    let shortName: String
    let models: [String]
    let defaultModel: String
    let voices: [String: [Voice]]   // by model
    let defaultVoice: String
    let keyHint: String
    /// Settings-page icon tile for this provider's rows.
    let symbol: String
    let tint: Color
    /// The speeds the provider accepts; the settings slider covers exactly this.
    var speedRange: ClosedRange<Double> = 0.5...2
    /// Whether it has a mainland and an international endpoint to choose from.
    var hasRegions = true
}

enum SpeechProviders {
    /// Qwen-Audio voices from the official list (Model Studio › Qwen-Audio-TTS
    /// voice list, 2026-09-28). All speak Mandarin and English unless noted.
    static let qwenAudio = SpeechProvider(
        id: "qwen-audio",
        displayName: "Qwen-Audio (Alibaba)",
        shortName: "Qwen",
        models: ["qwen-audio-3.0-tts-flash", "qwen-audio-3.0-tts-plus"],
        defaultModel: "qwen-audio-3.0-tts-flash",
        voices: [
            "qwen-audio-3.0-tts-flash": [
                .init(id: "longanhuan_v3.6", label: "龙安欢 · 女"),
                .init(id: "longanfengyue", label: "龙安风月 · 女 · 自然亲切"),
                .init(id: "longanxiaoxin", label: "龙安小欣 · 女 · 活泼"),
                .init(id: "longanlingxi", label: "龙安灵犀 · 女 · 甜美"),
                .init(id: "longanyuanfei", label: "龙安元妃 · 女 · 端庄"),
                .init(id: "longchuanshu_v3.6", label: "龙川叔 · 男 · 川味"),
                .init(id: "longhuohuo_v3.6", label: "龙火火 · 男孩"),
                .init(id: "longjielidou_v3.6", label: "龙杰力豆 · 男童"),
                .init(id: "longpaopao_v3.6", label: "龙泡泡 · 女童"),
                .init(id: "loongjohn", label: "John · Male · US (English only)"),
                .init(id: "loongeva_v3.6", label: "Eva · Female · US (English only)"),
                .init(id: "loongmary", label: "Mary · Female · UK (English only)"),
            ],
            "qwen-audio-3.0-tts-plus": [
                .init(id: "longanlingxin", label: "龙安灵心 · 女 · 温暖"),
                .init(id: "longanlufeng", label: "龙安路风 · 男 · 阳光"),
            ],
        ],
        defaultVoice: "longanhuan_v3.6",
        keyHint: L("speech.key.hint.qwen"),
        symbol: "cloud.fill", tint: .orange)

    /// MiniMax Speech 2.8. turbo is the default: first sound and word timings
    /// measured the same as hd (2026-09-29), at ¥2.0 instead of ¥3.5 per 10k
    /// characters. Every voice works with both models. The English voices are
    /// from the international site's list; the mainland endpoint accepts them
    /// too (checked 2026-09-29), it just does not list them.
    private static let miniMaxVoices: [SpeechProvider.Voice] = [
        .init(id: "English_radiant_girl", label: "Radiant Girl · Female (English)"),
        .init(id: "English_CalmWoman", label: "Calm Woman · Female (English)"),
        .init(id: "English_ConfidentWoman", label: "Confident Woman · Female (English)"),
        .init(id: "English_Upbeat_Woman", label: "Upbeat Woman · Female (English)"),
        .init(id: "English_captivating_female1", label: "Captivating Female · Female (English)"),
        .init(id: "English_Wiselady", label: "Wise Lady · Female (English)"),
        .init(id: "English_Soft-spokenGirl", label: "Soft-Spoken Girl · Female (English)"),
        .init(id: "English_expressive_narrator", label: "Expressive Narrator (English)"),
        .init(id: "English_Trustworthy_Man", label: "Trustworthy Man · Male · US (English)"),
        .init(id: "English_Gentle-voiced_man", label: "Gentle-voiced Man · Male · US (English)"),
        .init(id: "Chinese (Mandarin)_News_Anchor", label: "新闻女声 · 女"),
        .init(id: "Chinese (Mandarin)_Warm_Bestie", label: "温暖闺蜜 · 女"),
        .init(id: "Chinese (Mandarin)_Sweet_Lady", label: "甜美女声 · 女"),
        .init(id: "Chinese (Mandarin)_Gentle_Senior", label: "温柔学姐 · 女"),
        .init(id: "Chinese (Mandarin)_Male_Announcer", label: "播报男声 · 男"),
        .init(id: "Chinese (Mandarin)_Gentleman", label: "温润男声 · 男"),
    ]

    static let miniMax = SpeechProvider(
        id: "minimax",
        displayName: "MiniMax",
        shortName: "MiniMax",
        models: ["speech-2.8-turbo", "speech-2.8-hd"],
        defaultModel: "speech-2.8-turbo",
        voices: ["speech-2.8-turbo": miniMaxVoices, "speech-2.8-hd": miniMaxVoices],
        defaultVoice: "English_radiant_girl",
        keyHint: L("speech.key.hint.minimax"),
        symbol: "waveform", tint: .pink)

    /// ElevenLabs. flash v2.5 is the default: first sound 450–900 ms, where v3
    /// takes 1.7–2.7 s (measured 2026-09-30), at about half v3's price. v3 is
    /// offered for its voice quality; the user picks. Only the premade voices:
    /// a free account gets 402 for any other voice over the API. Every one of
    /// them reads Chinese too, with both models.
    private static let elevenLabsVoices: [SpeechProvider.Voice] = [
        .init(id: "EXAVITQu4vr4xnSDxMaL", label: "Sarah · Female · US"),
        .init(id: "FGY2WhTYpPnrIDTdsKH5", label: "Laura · Female · US"),
        .init(id: "cgSgspJ2msm6clMCkdW9", label: "Jessica · Female · US"),
        .init(id: "XrExE9yKIg1WjnnlVkGX", label: "Matilda · Female · US"),
        .init(id: "hpp4J3VqNfWAUOO0d1Us", label: "Bella · Female · US"),
        .init(id: "Xb7hH8MSUJpSbSDYk0k2", label: "Alice · Female · UK"),
        .init(id: "pFZP5JQG7iQjIQuC4Bku", label: "Lily · Female · UK"),
        .init(id: "SAz9YHcvj6GT2YYXdXww", label: "River · Neutral · US"),
        .init(id: "CwhRBWXzGAHq8TQ4Fs17", label: "Roger · Male · US"),
        .init(id: "N2lVS1w4EtoT3dr4eOWO", label: "Callum · Male · US"),
        .init(id: "SOYHLrjzK2X1ezoPC6cr", label: "Harry · Male · US"),
        .init(id: "TX3LPaxmHKxFdv7VOQHJ", label: "Liam · Male · US"),
        .init(id: "bIHbv24MWmeRgasZH58o", label: "Will · Male · US"),
        .init(id: "cjVigY5qzO86Huf0OWal", label: "Eric · Male · US"),
        .init(id: "iP95p4xoKVk53GoZ742B", label: "Chris · Male · US"),
        .init(id: "nPczCjzI2devNBz1zQrb", label: "Brian · Male · US"),
        .init(id: "pNInz6obpgDQGcFmaJgB", label: "Adam · Male · US"),
        .init(id: "pqHfZKP75CvOlQylNhV4", label: "Bill · Male · US"),
        .init(id: "JBFqnCBsd6RMkjVDRZzb", label: "George · Male · UK"),
        .init(id: "onwK4e9ZLuTAKqWW03F9", label: "Daniel · Male · UK"),
        .init(id: "IKne3meq5aSn9XLyUdCD", label: "Charlie · Male · Australian"),
    ]

    static let elevenLabs = SpeechProvider(
        id: "elevenlabs",
        displayName: "ElevenLabs",
        shortName: "ElevenLabs",
        models: ["eleven_flash_v2_5", "eleven_v3"],
        defaultModel: "eleven_flash_v2_5",
        voices: ["eleven_flash_v2_5": elevenLabsVoices, "eleven_v3": elevenLabsVoices],
        defaultVoice: "EXAVITQu4vr4xnSDxMaL",
        keyHint: L("speech.key.hint.elevenlabs"),
        symbol: "waveform.path", tint: .indigo,
        // The API refuses anything outside 0.7–1.2 (HTTP 400, checked 2026-09-30).
        speedRange: 0.7...1.2,
        hasRegions: false)

    static let all = [qwenAudio, miniMax, elevenLabs]

    static func find(_ id: String) -> SpeechProvider? { all.first { $0.id == id } }
}

/// Keychain storage for reader API keys: ONE key per provider (account
/// `tts-key-<provider>`), shared by every reader of that provider and kept
/// apart from the LLM keys. Never written to the config file.
struct SpeechKeyStore {
    private static let keychain = KeychainStore(service: Brand.keychainService)
    private static let log = FileLog("Speech.Keys")
    private static func account(_ provider: String) -> String { "tts-key-\(provider)" }

    func key(for provider: String) -> String { Self.keychain.get(Self.account(provider)) ?? "" }

    @discardableResult
    func save(_ key: String, for provider: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            try Self.keychain.set(trimmed, account: Self.account(provider))
            Self.log.info("API key saved for \(provider)")
            return nil
        } catch {
            Self.log.error("keychain save failed for \(provider): \(error)")
            return "\(error)"
        }
    }

    func clear(for provider: String) {
        Self.keychain.remove(Self.account(provider))
        Self.log.info("API key cleared for \(provider)")
    }
}

/// The readers the user set up, the default reader, and the provider keys —
/// the single source of truth behind the Speech tab and every Speak action.
/// Main thread only.
final class SpeechSettingsStore: ObservableObject {
    static let shared = SpeechSettingsStore()

    private enum P {
        static let readers = "speech.readers"
        static let defaultReader = "speech.defaultReader"
    }
    private let keys = SpeechKeyStore()
    private var config: ConfigStore { .shared }

    @Published private(set) var readers: [SpeechReader] = []
    @Published private(set) var defaultReaderID = SpeechReader.systemID
    @Published private(set) var keyedProviders: Set<String> = []

    private init() {
        readers = (ConfigStore.shared.value(P.readers)?.arrayValue ?? []).compactMap(SpeechReader.init(json:))
        let stored = ConfigStore.shared.string(P.defaultReader, default: SpeechReader.systemID)
        defaultReaderID = readers.contains { $0.id == stored } ? stored : SpeechReader.systemID
        refreshKeys()
    }

    /// The system voice first, then the user's readers.
    var allReaders: [SpeechReader] { [SpeechReader.system()] + readers }

    /// The reader an action asked for, else the default, else the system voice.
    /// An action naming a reader that was deleted falls back to the default.
    func resolve(_ id: String?) -> SpeechReader {
        let wanted = id ?? defaultReaderID
        return allReaders.first { $0.id == wanted }
            ?? allReaders.first { $0.id == defaultReaderID }
            ?? SpeechReader.system()
    }

    func name(of id: String?) -> String? {
        guard let id else { return nil }
        return allReaders.first { $0.id == id }?.name
    }

    // MARK: - Editing

    @discardableResult
    func addReader(provider: SpeechProvider) -> SpeechReader {
        let count = readers.filter { $0.engine == provider.id }.count
        let reader = SpeechReader(id: UUID().uuidString, name: count == 0 ? provider.shortName : "\(provider.shortName) \(count + 1)",
                                  engine: provider.id, model: provider.defaultModel, voice: provider.defaultVoice,
                                  speed: 1, region: "cn")
        readers.append(reader)
        persist()
        return reader
    }

    func update(_ reader: SpeechReader) {
        guard let i = readers.firstIndex(where: { $0.id == reader.id }) else { return }
        readers[i] = reader
        persist()
    }

    func remove(_ id: String) {
        readers.removeAll { $0.id == id }
        if defaultReaderID == id { defaultReaderID = SpeechReader.systemID }
        persist()
    }

    func setDefault(_ id: String) {
        defaultReaderID = allReaders.contains { $0.id == id } ? id : SpeechReader.systemID
        persist()
    }

    private func persist() {
        config.set(P.readers, .array(readers.map(\.json)))
        config.set(P.defaultReader, .string(defaultReaderID))
    }

    // MARK: - Keys

    func apiKey(for provider: String) -> String { keys.key(for: provider) }
    func hasKey(for provider: String) -> Bool { keyedProviders.contains(provider) }

    func saveKey(_ key: String, for provider: String) -> String? {
        let error = keys.save(key, for: provider)
        refreshKeys()
        return error
    }

    func clearKey(for provider: String) {
        keys.clear(for: provider)
        refreshKeys()
    }

    private func refreshKeys() {
        keyedProviders = Set(SpeechProviders.all.map(\.id).filter { !keys.key(for: $0).isEmpty })
    }
}
