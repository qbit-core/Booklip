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
    @State private var searchResultIndex = 0
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
                    showBars: $showBars,
                    pageNavigationDirection: $pageNavigationDirection,
                    searchQuery: committedSearchQuery,
                    pageEffect: settings.pageEffect
                )
            } else {
                TextReaderView(
                    vm: vm,
                    settings: settings,
                    showBars: $showBars,
                    tts: tts,
                    pageNavigationDirection: $pageNavigationDirection,
                    searchQuery: committedSearchQuery,
                    searchResultIndex: searchResultIndex,
                    selectedRange: $selectedTextRange
                )
            }

            // Left/right tap zones for page navigation — SwiftUI overlay avoids
            // UIKit gesture-recognizer conflicts (especially in paper mode where
            // the scroll view's pan recognizer is disabled).
            if !showBars && !vm.isLoading && book.format != .pdf {
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { pageNavigationDirection = -1 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showBars = true }
                        .frame(maxWidth: 80, maxHeight: .infinity)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { pageNavigationDirection = 1 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .allowsHitTesting(true)
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
                // Tapping the content area while bars are visible hides them
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showBars = false }
                        .ignoresSafeArea()
                )
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
        .onKeyPress(.tab)        { pageNavigationDirection = 1;  return .handled }
        .onKeyPress(.rightArrow) { pageNavigationDirection = 1;  return .handled }
        .onKeyPress(.leftArrow)  { pageNavigationDirection = -1; return .handled }
        .onKeyPress(.pageDown)   { pageNavigationDirection = 1;  return .handled }
        .onKeyPress(.pageUp)     { pageNavigationDirection = -1; return .handled }
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
            // Invisible placeholder keeps the title centered
            Color.clear.frame(width: 32, height: 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            ReadingProgressBar(progress: $vm.progress)
            Text("\(Int(vm.progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
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
                        .foregroundStyle(showSearch ? Color.accentColor : Color.primary)
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
                .onSubmit {
                    if committedSearchQuery == searchInputText && !searchInputText.isEmpty {
                        searchResultIndex += 1   // same query → advance to next match
                    } else {
                        committedSearchQuery = searchInputText
                        searchResultIndex = 0
                    }
                }
                .submitLabel(.search)
            if !searchInputText.isEmpty {
                Button {
                    searchResultIndex = max(0, searchResultIndex - 1)
                } label: {
                    Image(systemName: "chevron.up").foregroundStyle(.primary)
                }
                .disabled(committedSearchQuery.isEmpty)
                Button {
                    searchResultIndex += 1
                } label: {
                    Image(systemName: "chevron.down").foregroundStyle(.primary)
                }
                .disabled(committedSearchQuery.isEmpty)
                Button {
                    searchInputText = ""
                    committedSearchQuery = ""
                    searchResultIndex = 0
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
        let nsRange = NSRange(location: range.location, length: safeLen)
        let nsText = vm.plainText as NSString
        let snippet = String(nsText.substring(with: nsRange).prefix(80))
        let progress = totalChars > 0 ? Double(range.location) / Double(totalChars) : 0
        vm.addHighlight(range: nsRange, colorName: "yellow", snippet: snippet, progress: progress)
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
