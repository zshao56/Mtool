import AVFoundation
import NaturalLanguage

/// Which system voice fits a piece of text. The reading itself lives in
/// `SpeechPlayback` (Sources/Core/Speech), which uses this for the system reader.
///
/// The voice follows the text's language, detected on the spot, so English is
/// read by an English voice and Chinese by a Chinese one without the user having
/// to choose.
enum Speaker {

    /// A BCP-47 tag a system voice exists for, or nil to use the system default
    /// voice. Kana anywhere means Japanese outright — the recognizer alone
    /// mistakes short mixed text like "Swift で書く" for English.
    static func voiceLanguage(for text: String) -> String? {
        if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) {
            return "ja-JP"
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(500)))
        guard let language = recognizer.dominantLanguage else { return nil }
        switch language {
        case .simplifiedChinese:  return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        case .english:            return nil == AVSpeechSynthesisVoice(language: userEnglish) ? "en-US" : userEnglish
        default:
            // The system's own default voice for the language (fr → fr-FR, not
            // whichever French voice happens to be listed first), else any voice
            // for it.
            let code = language.rawValue
            return AVSpeechSynthesisVoice(language: code)?.language
                ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(code) }?.language
        }
    }

    /// The user's own English variant (en-GB, en-AU…) when their locale is
    /// English, so a British user is not read to in an American accent.
    private static var userEnglish: String {
        let locale = Locale.current
        guard locale.language.languageCode?.identifier == "en",
              let region = locale.region?.identifier else { return "en-US" }
        return "en-\(region)"
    }
}
