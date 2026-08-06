import AVFoundation
import Combine
import NaturalLanguage
import SwiftUI

// AVSpeechSynthesizer is designed to be driven from the main thread.
// The [Internal] QoS warning from pauseSpeaking/speak is emitted by
// AVFoundation's own internal audio threads and cannot be suppressed
// from user code — it is a known framework characteristic.
@MainActor
class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isPlaying = false
    @Published var selectedVoiceID: String = ""
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @Published var pitch: Float = 1.0

    /// Full sentence range (UTF-16, in the full document text) currently being spoken.
    /// nil when stopped. Views observe this to highlight the sentence & auto-scroll.
    @Published var spokenRange: NSRange?

    /// Active sleep-timer duration in minutes (nil = off).
    @Published var sleepMinutes: Int?
    private var sleepTimer: Timer?

    private let synthesizer = AVSpeechSynthesizer()

    private var fullText: NSString = ""
    private var sentenceRanges: [NSRange] = []
    private var currentSentenceIndex = 0

    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                let lang = voice.language.lowercased()
                let name = voice.name.lowercased()
                return (lang.hasPrefix("en-us") || lang.hasPrefix("ko-kr")) &&
                    (name.contains("yuna") || name.contains("eddy") ||
                     name.contains("flo") || name.contains("samantha"))
            }
            .sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language }
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

    // MARK: - Public API

    func speak(text: String, from offset: Int = 0) {
        synthesizer.stopSpeaking(at: .immediate)
        fullText = text as NSString
        sentenceRanges = makeSentenceRanges(in: text)
        // Start from the sentence that contains or starts at/after offset.
        currentSentenceIndex = sentenceRanges.firstIndex {
            $0.location + $0.length > offset
        } ?? 0
        speakCurrentSentence()
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
        isPlaying = false
    }

    func resume() {
        guard synthesizer.isPaused else { return }
        synthesizer.continueSpeaking()
        isPlaying = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        sentenceRanges = []
        currentSentenceIndex = 0
        isPlaying = false
        spokenRange = nil
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepMinutes = minutes
        guard let minutes else { return }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stop()
                self.sleepMinutes = nil
            }
        }
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

    // MARK: - Sentence segmentation

    private func makeSentenceRanges(in text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let ns = NSRange(range, in: text)
            if ns.length > 0 { ranges.append(ns) }
            return true
        }
        // Fallback: if tokenizer produced nothing (empty/whitespace-only text), treat whole text.
        if ranges.isEmpty, !text.isEmpty {
            ranges.append(NSRange(location: 0, length: (text as NSString).length))
        }
        return ranges
    }

    private func speakCurrentSentence() {
        guard currentSentenceIndex < sentenceRanges.count else {
            isPlaying = false
            spokenRange = nil
            return
        }
        let range = sentenceRanges[currentSentenceIndex]
        let sentence = fullText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else {
            // Skip blank/whitespace-only sentences.
            currentSentenceIndex += 1
            speakCurrentSentence()
            return
        }
        // Highlight the full sentence before the utterance starts so the view
        // scrolls to it immediately rather than waiting for the first word callback.
        spokenRange = range
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = selectedVoice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        synthesizer.speak(utterance)
        isPlaying = true
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        // Keep spokenRange at the full sentence — do not narrow it to the word range.
        Task { @MainActor [self] in
            guard currentSentenceIndex < sentenceRanges.count else { return }
            spokenRange = sentenceRanges[currentSentenceIndex]
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [self] in
            currentSentenceIndex += 1
            speakCurrentSentence()
        }
    }
}
