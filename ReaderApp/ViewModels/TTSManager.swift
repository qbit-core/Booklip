import AVFoundation
import Combine
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

    /// Character range (UTF-16, in the full document text) currently being spoken.
    /// nil when stopped. Views observe this to highlight & auto-scroll.
    @Published var spokenRange: NSRange?

    /// Active sleep-timer duration in minutes (nil = off).
    @Published var sleepMinutes: Int?
    private var sleepTimer: Timer?

    private let synthesizer = AVSpeechSynthesizer()

    // Chunked playback state — each chunk is an exact substring of `fullText`
    // so its global UTF-16 offset is known precisely.
    private var fullText: NSString = ""
    private var chunkRanges: [NSRange] = []
    private var currentChunkIndex = 0

    private let maxChunkSize = 500

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
        chunkRanges = makeChunkRanges(in: fullText, startingAt: offset)
        currentChunkIndex = 0
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
        chunkRanges = []
        currentChunkIndex = 0
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

    // MARK: - Chunking (exact substrings → preserves global offsets)

    private func makeChunkRanges(in ns: NSString, startingAt start: Int) -> [NSRange] {
        let length = ns.length
        var ranges: [NSRange] = []
        var i = max(0, min(start, length))
        while i < length {
            var end = min(i + maxChunkSize, length)
            if end < length {
                // Prefer to break at a whitespace/newline in the second half of the window
                let window = NSRange(location: i, length: end - i)
                let r = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: window)
                if r.location != NSNotFound && r.location > i + maxChunkSize / 2 {
                    end = r.location + r.length
                }
            }
            ranges.append(NSRange(location: i, length: end - i))
            i = end
        }
        return ranges
    }

    private func speakCurrentChunk() {
        guard currentChunkIndex < chunkRanges.count else {
            isPlaying = false
            spokenRange = nil
            return
        }
        let chunk = fullText.substring(with: chunkRanges[currentChunkIndex])
        let utterance = AVSpeechUtterance(string: chunk)
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
        Task { @MainActor [self] in
            guard currentChunkIndex < chunkRanges.count else { return }
            let base = chunkRanges[currentChunkIndex].location
            spokenRange = NSRange(location: base + characterRange.location, length: characterRange.length)
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
