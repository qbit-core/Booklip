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

    private let synthesizer = AVSpeechSynthesizer()

    // Chunked playback state
    private var chunks: [String] = []
    private var currentChunkIndex = 0

    // Max characters per utterance — keeps AVSpeechSynthesizer stable
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
        let remaining = String(text.dropFirst(max(0, min(offset, text.count))))
        chunks = split(remaining)
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
        chunks = []
        currentChunkIndex = 0
        isPlaying = false
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

    /// Splits text at paragraph/sentence boundaries into ≤ maxChunkSize pieces.
    private func split(_ text: String) -> [String] {
        var result: [String] = []
        // Split at paragraph boundaries first
        let paragraphs = text.components(separatedBy: "\n\n")
        for para in paragraphs where !para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if para.count <= maxChunkSize {
                result.append(para)
            } else {
                // Further split long paragraphs at sentence endings
                var current = ""
                for sentence in para.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
                    let trimmed = sentence.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    if current.count + trimmed.count + 2 > maxChunkSize {
                        if !current.isEmpty { result.append(current) }
                        current = trimmed
                    } else {
                        current += (current.isEmpty ? "" : ". ") + trimmed
                    }
                }
                if !current.isEmpty { result.append(current) }
            }
        }
        return result.isEmpty ? [text] : result
    }

    private func speakCurrentChunk() {
        guard currentChunkIndex < chunks.count else {
            isPlaying = false
            return
        }
        let text = chunks[currentChunkIndex]
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedVoice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        synthesizer.speak(utterance)
        isPlaying = true
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [self] in
            currentChunkIndex += 1
            speakCurrentChunk()
        }
    }
}
