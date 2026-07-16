import SwiftUI
import AVFoundation

struct TTSPanel: View {
    @ObservedObject var tts: TTSManager
    @ObservedObject var vm: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Playback controls
                Section {
                    HStack(spacing: 32) {
                        Spacer()
                        Button {
                            tts.togglePlayPause(text: vm.plainText, currentOffset: vm.ttsOffset)
                        } label: {
                            Image(systemName: tts.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 60))
                                .symbolEffect(.variableColor, isActive: tts.isPlaying)
                        }
                        .buttonStyle(.plain)
                        Button {
                            tts.stop()
                        } label: {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                // Voice selection
                Section("Voice") {
                    Picker("Voice", selection: $tts.selectedVoiceID) {
                        ForEach(tts.availableVoices, id: \.identifier) { voice in
                            VStack(alignment: .leading) {
                                Text(voice.name)
                                Text(voice.language)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(voice.identifier)
                        }
                    }
                    .pickerStyle(.inline)
                    .frame(height: 140)
                }

                // Speed
                Section("Speed  \(speedLabel)") {
                    Slider(value: $tts.rate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
                        .tint(.accentColor)
                }

                // Pitch
                Section("Pitch  \(pitchLabel)") {
                    Slider(value: $tts.pitch, in: 0.5...2.0)
                        .tint(.accentColor)
                }
            }
            .navigationTitle("Text to Speech")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .platformTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var speedLabel: String {
        let pct = (tts.rate - AVSpeechUtteranceMinimumSpeechRate) /
                  (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate)
        return String(format: "%.0f%%", pct * 100)
    }

    private var pitchLabel: String {
        String(format: "%.1fx", tts.pitch)
    }
}
