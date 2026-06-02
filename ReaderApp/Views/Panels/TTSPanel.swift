import SwiftUI
import AVFoundation

struct TTSPanel: View {
    @ObservedObject var tts: TTSManager
    @ObservedObject var vm: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Playback controls
                    HStack(spacing: 32) {
                        Spacer()
                        Button {
                            tts.togglePlayPause(text: vm.plainText, currentOffset: vm.ttsOffset)
                        } label: {
                            Image(systemName: tts.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 64))
                        }
                        .buttonStyle(.plain)

                        Button { tts.stop() } label: {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.vertical, 8)

                    // Voice
                    PanelSection(title: "Voice") {
                        Picker(selection: $tts.selectedVoiceID, label: EmptyView()) {
                            ForEach(tts.availableVoices, id: \.identifier) { voice in
                                Text("\(voice.name)  (\(voice.language))")
                                    .tag(voice.identifier)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Speed
                    PanelSection(title: "Speed") {
                        HStack {
                            Slider(value: $tts.rate,
                                   in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
                                .tint(.accentColor)
                            Text(speedLabel)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }

                    // Pitch
                    PanelSection(title: "Pitch") {
                        HStack {
                            Slider(value: $tts.pitch, in: 0.5...2.0)
                                .tint(.accentColor)
                            Text(pitchLabel)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
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

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
