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
    // feature 1: -1 = prev page, 0 = idle, 1 = next page
    @State private var pageNavigationDirection: Int = 0
    // feature 10: search state
    @State private var showSearch = false
    @State private var searchInputText = ""
    @State private var committedSearchQuery = ""
    // feature 9: text selection
    @State private var selectedTextRange: NSRange? = nil
    // feature 7: save progress when app backgrounds
    @Environment(\.scenePhase) private var scenePhase

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
                ContentUnavailableView("Cannot Open Book", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if book.format == .pdf {
                PDFReaderView(
                    document: vm.pdfDocument,
                    progress: $vm.progress,
                    displayMode: settings.displayMode,
                    pageNavigationDirection: $pageNavigationDirection,
                    searchQuery: committedSearchQuery
                )
            } else {
                TextReaderView(
                    vm: vm,
                    settings: settings,
                    showBars: $showBars,
                    tts: tts,
                    pageNavigationDirection: $pageNavigationDirection,
                    searchQuery: committedSearchQuery,
                    selectedRange: $selectedTextRange
                )
            }

            if showBars {
                VStack {
                    topBar
                    Spacer()
                    VStack(spacing: 0) {
                        if showSearch { searchBar }
                        bottomBar
                    }
                }
            }
        }
        .hideNavigationBar()
        // feature 3: apply color scheme globally so bars & system UI also adapt
        .preferredColorScheme(settings.preferredColorScheme)
        .task { vm.load() }
        .onDisappear { saveProgress() }
        // feature 7: save when app goes to background or becomes inactive
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { saveProgress() }
        }
        .sheet(isPresented: $showAppearance) { AppearancePanel(settings: settings) }
        .sheet(isPresented: $showTTS) { TTSPanel(tts: tts, vm: vm) }
        // feature 1: Tab / arrow keys navigate pages (hardware keyboard on iPad/macOS)
        .focusable()
        .onKeyPress(.tab) { press in
            pageNavigationDirection = press.modifiers.contains(.shift) ? -1 : 1
            return .handled
        }
        .onKeyPress(.rightArrow) { _ in pageNavigationDirection = 1;  return .handled }
        .onKeyPress(.leftArrow)  { _ in pageNavigationDirection = -1; return .handled }
        .onKeyPress(.pageDown)   { _ in pageNavigationDirection = 1;  return .handled }
        .onKeyPress(.pageUp)     { _ in pageNavigationDirection = -1; return .handled }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 16) {
            BackButton()
            Spacer()
            VStack(spacing: 2) {
                Text(book.title).font(.headline).lineLimit(1)
                Text(book.author).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(vm.progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            ReadingProgressBar(progress: $vm.progress)
            HStack(spacing: 28) {
                // TTS button
                Button { showTTS = true } label: {
                    Image(systemName: tts.isPlaying ? "waveform" : "play.circle")
                        .font(.title2)
                        .symbolEffect(.variableColor, isActive: tts.isPlaying)
                }

                // feature 10: search toggle
                Button {
                    showSearch.toggle()
                    if !showSearch {
                        searchInputText = ""
                        committedSearchQuery = ""
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(showSearch ? .accentColor : .primary)
                }

                // feature 9: highlight selected text (text books only)
                if book.format != .pdf, selectedTextRange != nil {
                    Button { createHighlight() } label: {
                        Image(systemName: "highlighter")
                            .font(.title2)
                            .foregroundStyle(.yellow)
                    }
                }

                Spacer()
                Button { showAppearance = true } label: {
                    Image(systemName: "textformat")
                        .font(.title2)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Search bar (feature 10)

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search in book…", text: $searchInputText)
                .onSubmit { committedSearchQuery = searchInputText }
                .submitLabel(.search)
            if !searchInputText.isEmpty {
                Button {
                    searchInputText = ""
                    committedSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Helpers

    // feature 9: create a BookHighlight from the current text selection
    private func createHighlight() {
        guard let range = selectedTextRange else { return }
        let totalChars = vm.plainText.utf16.count
        guard range.location < totalChars else { return }
        let safeLen = min(range.length, totalChars - range.location)
        guard safeLen > 0 else { return }
        let nsText = vm.plainText as NSString
        let text = nsText.substring(with: NSRange(location: range.location, length: safeLen))
        let highlight = BookHighlight(startOffset: range.location, length: safeLen, text: text)
        library.addHighlight(highlight, to: book.id)
        vm.addHighlight(highlight)
        selectedTextRange = nil
    }

    // feature 7: persist progress immediately
    private func saveProgress() {
        library.updateProgress(for: book.id, progress: vm.progress)
        tts.stop()
    }
}

private struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left").font(.headline)
        }
    }
}
