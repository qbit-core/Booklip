import AVFoundation
import Combine
import SwiftUI
import NaturalLanguage

@MainActor
class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isPlaying = false
    @Published var selectedVoiceID: String = ""
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @Published var pitch: Float = 1.0
    // feature 5: sentence-level highlight range (relative to full text)
    @Published var highlightRange: NSRange? = nil

    private let synthesizer = AVSpeechSynthesizer()
    private var fullText = ""
    private var startOffset = 0

    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }
            .sorted { $0.name < $1.name }
    }

    var selectedVoice: AVSpeechSynthesisVoice? {
        availableVoices.first { $0.identifier == selectedVoiceID } ?? availableVoices.first
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        selectedVoiceID = availableVoices.first?.identifier ?? ""
#if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
#endif
    }

    func speak(text: String, from offset: Int = 0) {
        synthesizer.stopSpeaking(at: .immediate)
        fullText = text
        startOffset = offset
        let chunk = String(text.dropFirst(offset))
        let utterance = AVSpeechUtterance(string: chunk)
        utterance.voice = selectedVoice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        synthesizer.speak(utterance)
        isPlaying = true
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
        isPlaying = false
    }

    func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isPlaying = true
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        highlightRange = nil
    }

    func togglePlayPause(text: String, currentOffset: Int) {
        if isPlaying {
            pause()
        } else if synthesizer.isPaused {
            resume()
        } else {
            speak(text: text, from: currentOffset)
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPlaying = false
            self.highlightRange = nil
        }
    }

    // feature 5: expand the spoken word range to its containing sentence
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        // characterRange is relative to the utterance string (which starts at startOffset)
        let absoluteRange = NSRange(
            location: characterRange.location + startOffset,
            length: characterRange.length
        )
        let sentenceRange = sentenceBounds(in: fullText, containing: absoluteRange)
        Task { @MainActor in
            self.highlightRange = sentenceRange
        }
    }

    // Use NLTokenizer to find the sentence that contains the given character range.
    private nonisolated func sentenceBounds(in text: String, containing wordRange: NSRange) -> NSRange {
        guard !text.isEmpty,
              wordRange.location < text.utf16.count,
              let range = Range(wordRange, in: text) else { return wordRange }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let sentenceRange = tokenizer.tokenRange(for: range)
        return NSRange(sentenceRange, in: text)
    }
}
