import SwiftUI

struct ReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var settings: ReadingSettings
    @StateObject private var vm: ReaderViewModel
    @StateObject private var tts = TTSManager()
    @State private var showAppearance = false
    @State private var showTTS = false
    @State private var showContents = false
    @State private var showBars = true
    @State private var autoScrolling = false
    @State private var highlightMode = false
    @State private var sessionStart = Date()

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
                PDFReaderView(document: vm.pdfDocument, background: settings.currentPreset.background, progress: $vm.progress)
                    .ignoresSafeArea()
            } else {
                TextReaderView(vm: vm, settings: settings, tts: tts, showBars: $showBars, autoScrolling: $autoScrolling, highlightMode: $highlightMode)
                    .ignoresSafeArea()
            }

            // Middle-third tap zone for bar toggle — works for both text and PDF,
            // fires instantly via SwiftUI (no UIKit gesture competition).
            // Left/right thirds pass through to the text reader for paging.
            if !vm.isLoading && vm.errorMessage == nil && !highlightMode {
                HStack(spacing: 0) {
                    Color.clear.allowsHitTesting(false)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showBars.toggle() }
                    Color.clear.allowsHitTesting(false)
                }
                .ignoresSafeArea()
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
        .onAppear {
            sessionStart = Date()
            loadBookSettings()
        }
        .onDisappear { saveProgress(); saveBookSettings() }
        .sheet(isPresented: $showAppearance) { AppearancePanel(settings: settings) }
        .sheet(isPresented: $showTTS) { TTSPanel(tts: tts, vm: vm) }
        .sheet(isPresented: $showContents) { ContentsPanel(vm: vm) { vm.jump(to: $0) } }
#if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
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
            HStack(spacing: 18) {
                Button { showContents = true } label: {
                    Image(systemName: "list.bullet").font(.headline)
                }
                Button { highlightMode.toggle() } label: {
                    Image(systemName: "highlighter")
                        .font(.headline)
                        .foregroundStyle(highlightMode ? .orange : .accentColor)
                }
                Button { vm.addBookmark() } label: {
                    Image(systemName: vm.isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.headline)
                        .foregroundStyle(vm.isCurrentPositionBookmarked ? .orange : .accentColor)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background {
            #if os(iOS)
            // iOS 26 liquid glass makes all SwiftUI materials transparent.
            // Use a solid system color so bars are always visible.
            Color(UIColor.secondarySystemBackground)
            #else
            Rectangle().fill(.thinMaterial)
            #endif
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            ReadingProgressBar(progress: $vm.progress)

            // Auto-scroll speed appears while auto-scrolling
            if autoScrolling {
                HStack(spacing: 12) {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                    Slider(value: $settings.autoScrollSpeed, in: 15...150)
                    Image(systemName: "hare").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)
            }

            HStack(spacing: 28) {
                Button { showTTS = true } label: {
                    Image(systemName: tts.isPlaying ? "waveform" : "play.circle")
                        .font(.title2)
                        .symbolEffect(.variableColor, isActive: tts.isPlaying)
                }
                Button { autoScrolling.toggle() } label: {
                    Image(systemName: autoScrolling ? "pause.circle.fill" : "arrow.down.circle")
                        .font(.title2)
                        .foregroundStyle(autoScrolling ? Color.accentColor : .primary)
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
        .background {
            #if os(iOS)
            // iOS 26 liquid glass makes all SwiftUI materials transparent.
            // Use a solid system color so bars are always visible.
            Color(UIColor.secondarySystemBackground)
            #else
            Rectangle().fill(.thinMaterial)
            #endif
        }
    }

    private func saveProgress() {
        autoScrolling = false
        ReadingStats.record(seconds: Date().timeIntervalSince(sessionStart))
        library.updateProgress(for: book.id, progress: vm.progress)
        tts.stop()
    }

    // MARK: - Per-book appearance

    private func loadBookSettings() {
        guard let s = BookStore.loadSettings(book.id) else { return }
        settings.fontName    = s.fontName
        settings.fontSize    = s.fontSize
        settings.lineSpacing = s.lineSpacing
        settings.presetId    = s.presetId
    }

    private func saveBookSettings() {
        BookStore.saveSettings(.init(fontName: settings.fontName,
                                     fontSize: settings.fontSize,
                                     lineSpacing: settings.lineSpacing,
                                     presetId: settings.presetId),
                               for: book.id)
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

