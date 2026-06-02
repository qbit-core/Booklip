import AVFoundation
import Combine
import SwiftUI

@MainActor
class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isPlaying = false
    @Published var selectedVoiceID: String = ""
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @Published var pitch: Float = 1.0

    private let synthesizer = AVSpeechSynthesizer()
    private var fullText = ""
    private var startOffset = 0

    var availableVoices: [AVSpeechSynthesisVoice] {
        // Show all installed voices sorted by language then name,
        // so Korean voices appear when reading Korean books.
        AVSpeechSynthesisVoice.speechVoices()
            .sorted {
                $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language
            }
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
        Task { @MainActor in self.isPlaying = false }
    }
}
