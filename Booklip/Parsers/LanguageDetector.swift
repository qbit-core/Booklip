import Foundation
import NaturalLanguage

/// Detects a book's main language from its text, on-device and offline.
///
/// Returns a BCP-47 code: "ko", "ja", "zh-Hans", "zh-Hant", "en", "fr", …, or
/// `LanguageDetector.undetermined` when there is no usable text (scanned PDF).
///
/// CJK is decided by Unicode script counts first — they are deterministic
/// where `NLLanguageRecognizer` can confuse kanji-heavy Japanese with Chinese:
/// Hangul means Korean, any real share of kana means Japanese (Japanese prose
/// is never kana-free), Han without kana means Chinese. Everything else (Latin,
/// Cyrillic, …) and the Simplified/Traditional split go to the recognizer.
nonisolated enum LanguageDetector {
    static let undetermined = "und"

    /// Characters examined per window; three windows (start, middle, late)
    /// so an English copyright page doesn't decide a Korean novel.
    private static let windowLength = 4000

    static func detect(_ text: String) -> String {
        let sample = self.sample(of: text)
        var hangul = 0, kana = 0, han = 0, otherLetters = 0
        for scalar in sample.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F:
                hangul += 1
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:
                kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                han += 1
            default:
                if scalar.properties.isAlphabetic { otherLetters += 1 }
            }
        }
        let cjk = hangul + kana + han
        guard cjk + otherLetters > 0 else { return undetermined }

        // One CJK character carries roughly a word; Latin needs ~4-5 letters
        // for the same. Weighting keeps a Korean book with English terms Korean.
        if cjk * 4 >= otherLetters {
            if hangul >= kana && hangul * 10 >= cjk * 3 { return "ko" }
            if kana * 10 >= cjk { return "ja" }
            if han > 0 {
                let recognizer = NLLanguageRecognizer()
                recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
                recognizer.processString(sample)
                return recognizer.dominantLanguage?.rawValue ?? "zh-Hans"
            }
            return hangul > 0 ? "ko" : "ja"
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage, language != .undetermined else {
            return undetermined
        }
        return language.rawValue
    }

    private static func sample(of text: String) -> String {
        let ns = text as NSString
        guard ns.length > windowLength * 3 else { return text }
        return [0.05, 0.5, 0.8].map { fraction -> String in
            let start = Int(Double(ns.length - windowLength) * fraction)
            let range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: windowLength))
            return ns.substring(with: range)
        }.joined(separator: "\n")
    }

    /// Localized name for a detected code ("Korean" / "한국어").
    static func displayName(for code: String) -> String {
        if code == undetermined { return String(localized: "Unknown") }
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// Language part only: "zh-Hant" → "zh".
    static func baseCode(_ code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code))
    }
}
