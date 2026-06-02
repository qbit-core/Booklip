import AVFoundation
import Combine
import SwiftUI

class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @MainActor @Published var isPlaying = false
    @MainActor @Published var selectedVoiceID: String = ""
    @MainActor @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @MainActor @Published var pitch: Float = 1.0

    // Synthesizer lives on a dedicated serial queue — keeps it off the main actor
    // so AVSpeechSynthesizer's internal lower-QoS threads don't cause priority inversion.
    private let synthQueue = DispatchQueue(label: "tts.synth", qos: .userInitiated)
    private let synthesizer = AVSpeechSynthesizer()

    var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { $0.language == $1.language ? $0.name < $1.name : $0.language < $1.language }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        Task { @MainActor in
            self.selectedVoiceID = self.availableVoices.first?.identifier ?? ""
        }
#if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
#endif
    }

    // MARK: - Playback (call from @MainActor — captures settings before hopping to synthQueue)

    @MainActor
    func speak(text: String, from offset: Int = 0) {
        let voiceID = selectedVoiceID
        let rate    = rate
        let pitch   = pitch
        synthQueue.async { [weak self] in
            guard let self else { return }
            synthesizer.stopSpeaking(at: .immediate)
            let chunk = String(text.dropFirst(max(0, offset)))
            guard !chunk.isEmpty else { return }
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate  = rate
            utterance.pitchMultiplier = pitch
            synthesizer.speak(utterance)
            Task { @MainActor in self.isPlaying = true }
        }
    }

    @MainActor
    func pause() {
        synthQueue.async { [weak self] in
            self?.synthesizer.pauseSpeaking(at: .word)
            Task { @MainActor in self?.isPlaying = false }
        }
    }

    @MainActor
    func resume() {
        let isPaused = synthesizer.isPaused
        synthQueue.async { [weak self] in
            guard let self, isPaused else { return }
            synthesizer.continueSpeaking()
            Task { @MainActor in self.isPlaying = true }
        }
    }

    @MainActor
    func stop() {
        synthQueue.async { [weak self] in
            self?.synthesizer.stopSpeaking(at: .immediate)
            Task { @MainActor in self?.isPlaying = false }
        }
    }

    @MainActor
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

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isPlaying = false }
    }
}
