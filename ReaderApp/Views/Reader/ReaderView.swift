import SwiftUI

struct ReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var settings: ReadingSettings
    @StateObject private var vm: ReaderViewModel
    @StateObject private var tts = TTSManager()
    @State private var showAppearance = false
    @State private var showTTS = false
    @State private var showBars = true

    init(book: Book) {
        self.book = book
        _vm = StateObject(wrappedValue: ReaderViewModel(book: book))
    }

    var body: some View {
        ZStack {
            settings.currentPreset.background.ignoresSafeArea()

            if vm.isLoading {
                ProgressView("Loading…")
            } else if let error = vm.errorMessage {
                ContentUnavailableView("Cannot Open Book", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if book.format == .pdf {
                PDFReaderView(document: vm.pdfDocument, progress: $vm.progress)
            } else {
                TextReaderView(vm: vm, settings: settings, tts: tts, showBars: $showBars)
            }

            if showBars {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
            }
        }
        .hideNavigationBar()
        .task { vm.load() }
        .onDisappear { saveProgress() }
        .sheet(isPresented: $showAppearance) { AppearancePanel(settings: settings) }
        .sheet(isPresented: $showTTS) { TTSPanel(tts: tts, vm: vm) }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            BackButton()
            Spacer()
            VStack(spacing: 2) {
                Text(book.title).font(.headline).lineLimit(1)
                Text(book.author).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Balance the back button so the title stays centered
            Color.clear.frame(width: 20, height: 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            ReadingProgressBar(progress: $vm.progress)
            HStack(spacing: 32) {
                Button { showTTS = true } label: {
                    Image(systemName: tts.isPlaying ? "waveform" : "play.circle")
                        .font(.title2)
                        .symbolEffect(.variableColor, isActive: tts.isPlaying)
                }
                Spacer()
                Button { showAppearance = true } label: {
                    Image(systemName: "textformat")
                        .font(.title2)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)

            // Centered progress percentage, just below the bottom navigation bar
            Text("\(Int(vm.progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 6)
        }
        .background(.ultraThinMaterial)
    }

    private func saveProgress() {
        library.updateProgress(for: book.id, progress: vm.progress)
        tts.stop()
    }
}

private struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.headline)
        }
    }
}
