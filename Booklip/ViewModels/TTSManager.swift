import AVFoundation
import Combine
import MediaPlayer
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
    /// Index of the chunk currently being spoken (the one whose utterance started last).
    private var currentChunkIndex = 0
    /// Next chunk to hand to the synthesizer. Runs ahead of currentChunkIndex by
    /// up to `queueDepth` so the synthesizer's queue is never empty: an empty
    /// queue lets it deactivate the audio session, and a background app whose
    /// audio session goes silent is suspended within seconds (TTS "stopped when
    /// the screen turned off").
    private var nextChunkToEnqueue = 0
    private static let queueDepth = 2

    /// Per-utterance mapping back to document coordinates. Written on the main
    /// actor before speak(), read from AVFoundation's delegate callbacks under
    /// `metaLock` — the callbacks arrive on an internal AVFoundation queue.
    private struct UtteranceMeta {
        let chunkIndex: Int
        let baseOffset: Int          // global UTF-16 offset of the chunk's first char
        let sentences: [NSRange]     // local (0-based) sentence ranges in the chunk
    }
    nonisolated(unsafe) private var utteranceMeta: [ObjectIdentifier: UtteranceMeta] = [:]
    private let metaLock = NSLock()

    /// Playback state around an audio-session interruption (phone call, Siri).
    private var resumeAfterInterruption = false
    private var observers: [NSObjectProtocol] = []
    private var nowPlayingTitle = "Booklip"
    private var nowPlayingArtist = ""

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
        installSessionObservers()
#endif
        installRemoteCommands()
        refreshVoices()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
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

    /// What the lock screen / Control Center shows while speaking.
    func setNowPlaying(title: String, artist: String) {
        nowPlayingTitle = title
        nowPlayingArtist = artist
        updateNowPlaying()
    }

    func speak(text: String, from offset: Int = 0) {
        synthesizer.stopSpeaking(at: .immediate)
        clearMeta()
        fullText = text as NSString
        chunkRanges = makeParagraphChunks(in: text)
        // Start at the chunk that contains or starts at/after offset.
        startSpeaking(fromChunk: chunkRanges.firstIndex { NSMaxRange($0) > offset } ?? 0)
    }

    /// (Re)starts the synthesizer at `index` of the already-chunked text.
    private func startSpeaking(fromChunk index: Int) {
        currentChunkIndex = index
        nextChunkToEnqueue = index
        activateAudioSession()
        fillQueue()
        isPlaying = !chunkRanges.isEmpty
        if chunkRanges.isEmpty { spokenRange = nil }
        updateNowPlaying()
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
        isPlaying = false
        updateNowPlaying()
    }

    @discardableResult
    func resume() -> Bool {
        guard synthesizer.isPaused else { return false }
        activateAudioSession()
        guard synthesizer.continueSpeaking() else { return false }
        isPlaying = true
        updateNowPlaying()
        return true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        clearMeta()
        chunkRanges = []
        currentChunkIndex = 0
        nextChunkToEnqueue = 0
        isPlaying = false
        spokenRange = nil
        resumeAfterInterruption = false
        deactivateAudioSession()
        updateNowPlaying()
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepMinutes = minutes
        guard let minutes else { return }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
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

    // MARK: - Audio session (iOS)

    /// The synthesizer only keeps the session active while its queue is
    /// non-empty; owning activation ourselves keeps background playback alive
    /// across chunk boundaries and lets the lock screen show our controls.
    private func activateAudioSession() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
#endif
    }

    private func deactivateAudioSession() {
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

#if os(iOS)
    private func installSessionObservers() {
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        // Delivered on the main queue; pull the plain values out before hopping
        // to the actor so the non-Sendable Notification is not captured.
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: session, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in self?.handleInterruption(typeRaw: type, optionsRaw: opts) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: session, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in self?.handleRouteChange(reasonRaw: reason) }
        })
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let raw = typeRaw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // A call / Siri / another player took the session. Pause so the
            // synthesizer does not keep advancing chunks into a dead session.
            resumeAfterInterruption = isPlaying
            if isPlaying {
                synthesizer.pauseSpeaking(at: .immediate)
                isPlaying = false
                updateNowPlaying()
            }
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            if resumeAfterInterruption, opts.contains(.shouldResume) { resume() }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        guard let raw = reasonRaw,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        // Headphones unplugged: stop blasting through the speaker (system convention).
        if isPlaying { pause() }
    }
#endif

    // MARK: - Remote commands / Now Playing

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.remotePlay() ? .success : .noActionableNowPlayingItem
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isPlaying { self.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isPlaying { self.pause(); return .success }
            return self.remotePlay() ? .success : .noActionableNowPlayingItem
        }
        center.stopCommand.addTarget { [weak self] _ in
            self?.stop(); return .success
        }
        // Nothing sensible to skip to; hide the buttons.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    /// Play from the lock screen / headset. Resumes a paused synthesizer; if the
    /// synthesizer lost its queue instead (the system tore the session down
    /// while we were silent), speaks again from the chunk it had reached.
    private func remotePlay() -> Bool {
        if synthesizer.isPaused {
            if resume() { return true }
        } else if synthesizer.isSpeaking {
            isPlaying = true
            updateNowPlaying()
            return true
        }
        guard currentChunkIndex < chunkRanges.count else { return false }
        synthesizer.stopSpeaking(at: .immediate)
        clearMeta()
        startSpeaking(fromChunk: currentChunkIndex)
        return isPlaying
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard isPlaying || synthesizer.isPaused else {
            center.nowPlayingInfo = nil
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: nowPlayingArtist,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
    }

    // MARK: - Chunking

    /// Target size of one utterance: whole sentences are packed together up to
    /// this many UTF-16 units. Kept short (a sentence or two) on purpose: the
    /// per-word `willSpeakRangeOfSpeechString` callbacks track the synthesizer,
    /// not the speaker, so with neural voices they can run ahead of the audio
    /// within one utterance and only re-align at the next one. A shorter chunk
    /// bounds that lead; queue-ahead (`queueDepth`) removes the gap that used
    /// to make short chunks costly. A single sentence longer than this is NOT
    /// cut — it becomes one utterance of its own, so it is read and highlighted
    /// as a whole.
    private static let maxChunkLength = 240

    /// Hard ceiling on one utterance. AVSpeechSynthesizer crashes/hangs on very
    /// large utterances (CLAUDE.md), so text the tokenizer cannot break into
    /// sentences (no punctuation for pages) is still split — at whitespace,
    /// never inside a word.
    private static let maxSentenceLength = 2000

    /// Splits text at paragraph breaks (2+ newlines), then subdivides any paragraph
    /// longer than `maxChunkLength` at sentence boundaries. A .txt with
    /// single-newline paragraphs, or a chapter with no blank lines, previously
    /// became ONE whole-document utterance.
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
    /// UTF-16 units. Sentences are never cut: one longer than the cap is a
    /// chunk by itself (only past `maxSentenceLength` is it split, at spaces).
    private func subdivide(_ range: NSRange, in ns: NSString) -> [NSRange] {
        let cap = Self.maxChunkLength
        let para = ns.substring(with: range)
        var chunks: [NSRange] = []
        var current: NSRange?
        for local in makeSentenceRanges(in: para) {
            let whole = NSRange(location: range.location + local.location, length: local.length)
            for sentence in splitAtWordBoundaries(whole, in: ns) {
                if let c = current, NSMaxRange(sentence) - c.location <= cap {
                    current = NSRange(location: c.location, length: NSMaxRange(sentence) - c.location)
                } else {
                    if let c = current { chunks.append(c) }
                    current = sentence
                }
            }
        }
        if let c = current { chunks.append(c) }
        return chunks.isEmpty ? [range] : chunks
    }

    /// Returns `range` unchanged unless it exceeds `maxSentenceLength`; then it
    /// is cut after the last whitespace that fits, so no word is split. Text
    /// with no whitespace at all (an unspaced CJK run) is cut at the ceiling,
    /// on a composed-character boundary.
    private func splitAtWordBoundaries(_ range: NSRange, in ns: NSString) -> [NSRange] {
        let cap = Self.maxSentenceLength
        var pieces: [NSRange] = []
        var rest = range
        while rest.length > cap {
            let window = NSRange(location: rest.location, length: cap)
            let space = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: window)
            var cut = rest.location + cap
            if space.location != NSNotFound, space.location > rest.location {
                cut = NSMaxRange(space)
            } else {
                let composed = ns.rangeOfComposedCharacterSequence(at: cut).location
                if composed > rest.location { cut = composed }
            }
            pieces.append(NSRange(location: rest.location, length: cut - rest.location))
            rest = NSRange(location: cut, length: NSMaxRange(rest) - cut)
        }
        if rest.length > 0 { pieces.append(rest) }
        return pieces
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

    /// Hands chunks to the synthesizer until `queueDepth` of them are queued
    /// beyond the one playing (or the text runs out).
    private func fillQueue() {
        while nextChunkToEnqueue < chunkRanges.count,
              nextChunkToEnqueue - currentChunkIndex < Self.queueDepth {
            enqueue(chunkIndex: nextChunkToEnqueue)
            nextChunkToEnqueue += 1
        }
    }

    private func enqueue(chunkIndex: Int) {
        let range = chunkRanges[chunkIndex]
        let raw = fullText.substring(with: range)
        // Sentence ranges in LOCAL (0-based) coords of this chunk, so
        // AVFoundation's characterRange.location maps directly.
        let sentences = makeSentenceRanges(in: raw)
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
        metaLock.lock()
        utteranceMeta[ObjectIdentifier(utterance)] = UtteranceMeta(
            chunkIndex: chunkIndex, baseOffset: range.location, sentences: sentences)
        metaLock.unlock()
        synthesizer.speak(utterance)
    }

    private nonisolated func meta(for utterance: AVSpeechUtterance) -> UtteranceMeta? {
        metaLock.lock(); defer { metaLock.unlock() }
        return utteranceMeta[ObjectIdentifier(utterance)]
    }

    private func clearMeta() {
        metaLock.lock(); utteranceMeta.removeAll(); metaLock.unlock()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        guard let m = meta(for: utterance) else { return }
        Task { @MainActor [self] in
            currentChunkIndex = m.chunkIndex
            fillQueue()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        guard let m = meta(for: utterance) else { return }
        let localPos = characterRange.location
        guard let localSentence = m.sentences.first(where: {
            $0.location <= localPos && localPos < NSMaxRange($0)
        }) else { return }
        let globalSentence = NSRange(location: m.baseOffset + localSentence.location,
                                     length: localSentence.length)
        // The callback marks when the synthesizer hands the word to the audio
        // output, not when the listener hears it: the output path adds the I/O
        // buffer plus the route's latency (≈0.2 s on Bluetooth headphones).
        // Delay the highlight by that much so it lands with the audio.
        let delay = Self.outputDelay()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let current = self.spokenRange, NSEqualRanges(current, globalSentence) { return }
            self.spokenRange = globalSentence
        }
    }

    /// Seconds between the synthesizer emitting audio and it leaving the speaker.
    private nonisolated static func outputDelay() -> TimeInterval {
#if os(iOS)
        let s = AVAudioSession.sharedInstance()
        return min(0.6, max(0, s.outputLatency + s.ioBufferDuration))
#else
        return 0
#endif
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        guard let m = meta(for: utterance) else { return }
        metaLock.lock(); utteranceMeta.removeValue(forKey: ObjectIdentifier(utterance)); metaLock.unlock()
        Task { @MainActor [self] in
            // Last chunk finished and nothing else is queued: done.
            if m.chunkIndex + 1 >= chunkRanges.count {
                chunkRanges = []
                currentChunkIndex = 0
                nextChunkToEnqueue = 0
                isPlaying = false
                spokenRange = nil
                deactivateAudioSession()
                updateNowPlaying()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        metaLock.lock(); utteranceMeta.removeValue(forKey: ObjectIdentifier(utterance)); metaLock.unlock()
    }
}
