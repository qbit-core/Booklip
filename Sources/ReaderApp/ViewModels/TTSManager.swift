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
    /// Sentence-level ranges for highlight lookup.
    /// nonisolated(unsafe): written on MainActor before speak(); read-only in delegate callbacks.
    nonisolated(unsafe) private var sentenceRanges: [NSRange] = []
    /// Paragraph-level chunks — each becomes one AVSpeechUtterance.
    private var chunkRanges: [NSRange] = []
    private var currentChunkIndex = 0
    /// Global UTF-16 offset of the first character of the current utterance.
    /// nonisolated(unsafe): set on MainActor before synthesizer.speak(); read-only in delegate callbacks.
    nonisolated(unsafe) private var chunkBaseOffset = 0

    // Cached once — speechVoices() hits an AVFoundation internal decoder on
    // repeated calls which logs a DecodingError and can return an empty list.
    @Published private(set) var availableVoices: [AVSpeechSynthesisVoice] = []

    var selectedVoice: AVSpeechSynthesisVoice? {
        availableVoices.first { $0.identifier == selectedVoiceID } ?? availableVoices.first
    }

    override init() {
        super.init()
        synthesizer.delegate = self
#if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
#endif
        refreshVoices()
    }

    func refreshVoices() {
        let all = AVSpeechSynthesisVoice.speechVoices()
        // Prefer high-quality named voices; fall back to any en-US / ko-KR voice.
        let preferred = all.filter { voice in
            let lang = voice.language.lowercased()
            let name = voice.name.lowercased()
            return (lang.hasPrefix("en-us") || lang.hasPrefix("ko-kr")) &&
                (name.contains("yuna") || name.contains("eddy") ||
                 name.contains("flo") || name.contains("samantha"))
        }
        let voices = preferred.isEmpty
            ? all.filter { $0.language.lowercased().hasPrefix("en-us") || $0.language.lowercased().hasPrefix("ko-kr") }
            : preferred
        availableVoices = voices.sorted {
            $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language
        }
        if selectedVoiceID.isEmpty || !availableVoices.contains(where: { $0.identifier == selectedVoiceID }) {
            selectedVoiceID = availableVoices.first?.identifier ?? ""
        }
    }

    // MARK: - Public API

    func speak(text: String, from offset: Int = 0) {
        synthesizer.stopSpeaking(at: .immediate)
        fullText = text as NSString
        sentenceRanges = makeSentenceRanges(in: text)
        chunkRanges = makeParagraphChunks(in: text)
        // Start at the chunk that contains or starts at/after offset.
        currentChunkIndex = chunkRanges.firstIndex { NSMaxRange($0) > offset } ?? 0
        speakCurrentChunk()
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
        chunkRanges = []
        currentChunkIndex = 0
        chunkBaseOffset = 0
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

    // MARK: - Chunking

    /// Splits text at paragraph breaks (2+ newlines). Each paragraph becomes one utterance
    /// so there are no inter-utterance gaps. willSpeakRangeOfSpeechString fires per-word
    /// inside each chunk, giving exact synchronization.
    private func makeParagraphChunks(in text: String) -> [NSRange] {
        let ns = text as NSString
        let totalLength = ns.length
        var result: [NSRange] = []

        var breakRanges: [NSRange] = [NSRange(location: 0, length: 0)]
        // Match any 2+ consecutive newlines including \r\n (EPUB paragraph breaks).
        if let regex = try? NSRegularExpression(pattern: "(?:\\r\\n|\\r|\\n){2,}") {
            regex.enumerateMatches(in: text,
                                   range: NSRange(location: 0, length: totalLength)) { m, _, _ in
                if let r = m?.range { breakRanges.append(r) }
            }
        }
        breakRanges.append(NSRange(location: totalLength, length: 0))

        for i in 0..<breakRanges.count - 1 {
            let start = NSMaxRange(breakRanges[i])
            let end   = breakRanges[i + 1].location
            guard end > start else { continue }
            let range = NSRange(location: start, length: end - start)
            let paraText = ns.substring(with: range)
            guard !paraText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result.append(range)
        }

        if result.isEmpty, !text.isEmpty {
            result.append(NSRange(location: 0, length: totalLength))
        }
        return result
    }

    // MARK: - Sentence segmentation

    private func makeSentenceRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let totalLength = ns.length

        // Pure regex sentence segmentation — more reliable than NLTokenizer for
        // EPUB text where sentence boundaries follow standard rules.
        //
        // A sentence break occurs at either:
        //   (A) sentence-ending punct [.?!] + optional closing quote (\p{Pf})
        //       + horizontal whitespace + (uppercase letter or opening quote \p{Pi})
        //   (B) a paragraph break (2+ consecutive newlines, any variant)
        //
        // All positions are in the ORIGINAL text's UTF-16 units, so they match
        // the chunkBaseOffset + AVFoundation characterRange arithmetic exactly.
        //
        // \p{Pf} / \p{Pi} avoid embedding curly-quote literals in source.
        let pattern = "[.?!]\\p{Pf}?[ \\t]+(?=[A-Z\\p{Pi}])" +
                      "|[.?!]\\p{Pf}?[ \\t]*(?:\\r\\n|\\r|\\n)+" +
                      "|(?:\\r\\n|\\r|\\n){2,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [NSRange(location: 0, length: totalLength)]
        }

        var breakStarts: [Int] = [0]
        regex.enumerateMatches(in: text,
                               range: NSRange(location: 0, length: totalLength)) { m, _, _ in
            guard let r = m?.range else { return }
            // The next sentence begins right after the separator.
            let next = r.location + r.length
            if next < totalLength { breakStarts.append(next) }
        }
        breakStarts.append(totalLength)

        var result: [NSRange] = []
        for i in 0..<breakStarts.count - 1 {
            let s = breakStarts[i], e = breakStarts[i + 1]
            guard e > s else { continue }
            result.append(NSRange(location: s, length: e - s))
        }
        print("[TTS] sentenceRanges: \(result.count) sentences, first=\(result.first.map{"\($0.location)..\(NSMaxRange($0))"} ?? "nil")")
        return result.isEmpty ? [NSRange(location: 0, length: totalLength)] : result
    }

    // MARK: - Playback

    private func speakCurrentChunk() {
        guard currentChunkIndex < chunkRanges.count else {
            isPlaying = false
            spokenRange = nil
            return
        }
        let range = chunkRanges[currentChunkIndex]
        // Store before speak() so willSpeakRangeOfSpeechString can map offsets.
        chunkBaseOffset = range.location
        // Normalize newlines to spaces before passing to AVSpeechUtterance.
        // AVFoundation skips \r/\n in its internal character model, causing
        // characterRange offsets to drift from our sentenceRanges. Each
        // replacement is 1:1 UTF-16 so chunkBaseOffset + offset stays correct.
        let raw = fullText.substring(with: range)
        let text = raw.replacingOccurrences(of: "\r", with: " ")
                      .replacingOccurrences(of: "\n", with: " ")
        let utterance = AVSpeechUtterance(string: text)
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
        // Do the O(n) sentence lookup on AVFoundation's thread so the highlight
        // update reaches the main actor immediately after the word begins.
        // chunkBaseOffset and sentenceRanges are nonisolated(unsafe): written on the
        // MainActor before synthesizer.speak(), so there are no concurrent writes here.
        let globalPos = chunkBaseOffset + characterRange.location
        guard let sentence = sentenceRanges.first(where: {
            $0.location <= globalPos && globalPos < NSMaxRange($0)
        }) else { return }
        // Only dispatch when the sentence changes (avoids one main-actor round-trip
        // per word within the same sentence).
        Task { @MainActor [self] in
            if let current = spokenRange, NSEqualRanges(current, sentence) { return }
            spokenRange = sentence
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [self] in
            currentChunkIndex += 1
            speakCurrentChunk()
        }
    }
}
