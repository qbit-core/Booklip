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
    /// Paragraph-level chunks — each becomes one AVSpeechUtterance.
    private var chunkRanges: [NSRange] = []
    private var currentChunkIndex = 0
    /// Global UTF-16 offset of the first character of the current utterance.
    /// nonisolated(unsafe): set on MainActor before synthesizer.speak(); read-only in delegate callbacks.
    nonisolated(unsafe) private var chunkBaseOffset = 0
    /// Sentence ranges within the CURRENT chunk (local / 0-based coords relative to chunkBaseOffset).
    /// nonisolated(unsafe): written on MainActor before synthesizer.speak(); read-only in delegate callbacks.
    nonisolated(unsafe) private var chunkSentenceRanges: [NSRange] = []

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
        chunkSentenceRanges = []
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

    /// Upper bound on one utterance. AVSpeechSynthesizer crashes/hangs on very
    /// large utterances (CLAUDE.md), so every chunk is capped regardless of how
    /// the text is paragraphed.
    private static let maxChunkLength = 500

    /// Splits text at paragraph breaks (2+ newlines), then subdivides any paragraph
    /// longer than `maxChunkLength` at sentence boundaries (hard-splitting a single
    /// overlong sentence). A .txt with single-newline paragraphs, or a chapter with
    /// no blank lines, previously became ONE whole-document utterance.
    /// willSpeakRangeOfSpeechString fires per-word inside each chunk.
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

        let nonBlank = CharacterSet.whitespacesAndNewlines.inverted
        for i in 0..<breakRanges.count - 1 {
            let start = NSMaxRange(breakRanges[i])
            let end   = breakRanges[i + 1].location
            guard end > start else { continue }
            let range = NSRange(location: start, length: end - start)
            // Emptiness test without copying the paragraph out.
            guard ns.rangeOfCharacter(from: nonBlank, options: [], range: range).location != NSNotFound
            else { continue }
            if range.length <= Self.maxChunkLength {
                result.append(range)
            } else {
                result.append(contentsOf: subdivide(range, in: ns))
            }
        }

        if result.isEmpty, !text.isEmpty {
            result.append(contentsOf: subdivide(NSRange(location: 0, length: totalLength), in: ns))
        }
        return result
    }

    /// Packs the sentences of `range` into chunks of at most `maxChunkLength`
    /// UTF-16 units; a sentence longer than the cap is hard-split at the cap.
    private func subdivide(_ range: NSRange, in ns: NSString) -> [NSRange] {
        let cap = Self.maxChunkLength
        let para = ns.substring(with: range)
        var chunks: [NSRange] = []
        var current: NSRange?
        for local in makeSentenceRanges(in: para) {
            var sentence = NSRange(location: range.location + local.location, length: local.length)
            // Hard-split an overlong sentence.
            while sentence.length > cap {
                if let c = current { chunks.append(c); current = nil }
                chunks.append(NSRange(location: sentence.location, length: cap))
                sentence = NSRange(location: sentence.location + cap, length: sentence.length - cap)
            }
            if let c = current, NSMaxRange(sentence) - c.location <= cap {
                current = NSRange(location: c.location, length: NSMaxRange(sentence) - c.location)
            } else {
                if let c = current { chunks.append(c) }
                current = sentence
            }
        }
        if let c = current { chunks.append(c) }
        return chunks.isEmpty ? [range] : chunks
    }

    // MARK: - Sentence segmentation

    /// Splits `text` into sentence ranges using NLTokenizer.
    /// Correctly handles Korean full-width punctuation (。？！), quoted sentences,
    /// and mixed-language text — all cases the previous ASCII-only scan missed.
    private func makeSentenceRanges(in text: String) -> [NSRange] {
        guard !text.isEmpty else { return [NSRange(location: 0, length: 0)] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let nsRange = NSRange(range, in: text)
            if nsRange.length > 0 { result.append(nsRange) }
            return true
        }
        if result.isEmpty {
            result.append(NSRange(location: 0, length: (text as NSString).length))
        }
        return result
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
        let raw = fullText.substring(with: range)
        // Compute sentence ranges in LOCAL (0-based) coords of this chunk.
        // Using local coords means AVFoundation's characterRange.location maps
        // directly — no global offset arithmetic needed for the lookup.
        chunkSentenceRanges = makeSentenceRanges(in: raw)
        // Normalize newlines (and EPUB image placeholders U+FFFC) to spaces 1:1 so
        // AVFoundation characterRange positions stay aligned with the original
        // local coords.
        let text = raw.replacingOccurrences(of: "\r", with: " ")
                      .replacingOccurrences(of: "\n", with: " ")
                      .replacingOccurrences(of: "\u{FFFC}", with: " ")
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
        // Look up the sentence in LOCAL (chunk-relative) coords.
        // chunkBaseOffset and chunkSentenceRanges are nonisolated(unsafe):
        // written on MainActor before synthesizer.speak(), so no concurrent writes.
        let localPos = characterRange.location
        guard let localSentence = chunkSentenceRanges.first(where: {
            $0.location <= localPos && localPos < NSMaxRange($0)
        }) else { return }
        let globalSentence = NSRange(location: chunkBaseOffset + localSentence.location,
                                     length: localSentence.length)
        Task { @MainActor [self] in
            if let current = spokenRange, NSEqualRanges(current, globalSentence) { return }
            spokenRange = globalSentence
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
