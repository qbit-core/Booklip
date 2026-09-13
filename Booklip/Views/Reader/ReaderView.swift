import SwiftUI
import PDFKit

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
    // feature 9: highlight mode — when on, the text view allows selection and
    // the selection edit menu offers "Highlight" (4 colors)
    @State private var highlightMode = false
    // Table of contents / bookmarks / highlights sheet
    @State private var showContents = false
    // feature 7: save progress when app backgrounds
    @Environment(\.scenePhase) private var scenePhase
    // Reading session timer — records elapsed seconds for ReadingStats
    @State private var sessionStart: Date? = nil
    @State private var autoScrolling = false

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
                    highlightMode: $highlightMode,
                    autoScrolling: $autoScrolling
                )
            }

            // Left/right tap zones for page navigation — SwiftUI overlay avoids
            // UIKit gesture-recognizer conflicts (especially in paper mode where
            // the scroll view's pan recognizer is disabled).
            // Paper mode only. These SwiftUI overlays sit above the UIKit view and
            // swallow every touch, so in vertical-slide mode they blocked finger
            // scrolling entirely; there the text view's own tap recognizer handles
            // edge-tap paging and bar toggling (see TextReaderView.onTap). Also off
            // in highlight mode so selection touches reach the text view.
            if !showBars && !highlightMode && !vm.isLoading && settings.pageEffect == .paper {
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
                // Paper mode: right→left swipe = next page, left→right = previous.
                // The overlay swallows touches, so the swipe must be recognized here
                // (the text view's own swipe recognizers never see it).
                .gesture(pageSwipe)
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
                // Tapping the content area while bars are visible hides them.
                // Paper mode only: in vertical-slide mode this full-screen catcher
                // blocked scrolling while the bars were up; the UIKit tap recognizer
                // hides the bars instead. Also off in highlight mode.
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showBars = false }
                        .gesture(pageSwipe)   // paper mode: swipe pages even with bars up
                        .ignoresSafeArea()
                        .allowsHitTesting(!highlightMode && settings.pageEffect == .paper)
                )
            }

            // A large jump (initial position restore, or a big TOC/search/progress-
            // bar seek) used to block the main thread for seconds on very large
            // books; the cause is fixed (FontRegistrar.effectiveFontName). This
            // overlay stays as a safety net so any residual stall reads as
            // "working" rather than "frozen".
            if vm.isPositioning {
                Color.black.opacity(0.15).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("이동 중…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .allowsHitTesting(true)
            }
        }
        .hideNavigationBar()
        // feature 3: apply color scheme globally so bars & system UI also adapt
        .preferredColorScheme(settings.preferredColorScheme)
        .task { vm.load() }
        .onAppear { sessionStart = Date() }
        .onDisappear {
            saveProgress()
            tts.stop()
            autoScrolling = false   // also lets the text view's display link stop
        }
        // feature 7: save when app goes to background or becomes inactive
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { saveProgress() }
            if phase == .active { sessionStart = Date() }
        }
        .sheet(isPresented: $showAppearance) { AppearancePanel(settings: settings) }
        .sheet(isPresented: $showTTS) { TTSPanel(tts: tts, vm: vm) }
        .sheet(isPresented: $showContents) {
            ContentsPanel(vm: vm) { target in vm.progress = min(max(target, 0), 1) }
        }
        // feature 1: Tab / arrow keys navigate pages (hardware keyboard on iPad/macOS)
        // Not focusable while the UITextView owns first responder for selection:
        // the SwiftUI focus system fighting UIKit's responder chain produced a
        // burst of "AttributeGraph: cycle detected" on every selection change.
        // Keyboard paging is disabled in highlight mode anyway.
        .focusable(!highlightMode)
        .onKeyPress(.tab)        { pageNavigationDirection = 1;  return .handled }
        .onKeyPress(.rightArrow) { pageNavigationDirection = 1;  return .handled }
        .onKeyPress(.leftArrow)  { pageNavigationDirection = -1; return .handled }
        .onKeyPress(.pageDown)   { pageNavigationDirection = 1;  return .handled }
        .onKeyPress(.pageUp)     { pageNavigationDirection = -1; return .handled }
    }

    // Horizontal swipe → page turn (paper mode). Right→left = next, left→right =
    // previous; a mostly-vertical drag is ignored so it can't misfire as a page.
    private var pageSwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5 else { return }
                pageNavigationDirection = dx < 0 ? 1 : -1
            }
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
            // Bookmark button — top-right corner
            Button { vm.toggleBookmark() } label: {
                Image(systemName: vm.isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.headline)
                    .foregroundStyle(vm.isCurrentPositionBookmarked ? Color.accentColor : Color.primary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            ReadingProgressBar(progress: $vm.progress, marks: vm.bookmarks.map(\.progress))
            VStack(spacing: 1) {
                if let pagProg = vm.paginationProgress {
                    Text("페이지 계산 중 \(Int(pagProg * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(pageLabel)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.primary)
                }
                Text("\(Int(vm.progress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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

                // Auto-scroll toggle (text books only)
                if book.format != .pdf {
                    Button { autoScrolling.toggle() } label: {
                        Image(systemName: "scroll")
                            .font(.title2)
                            .foregroundStyle(autoScrolling ? Color.accentColor : Color.primary)
                    }
                }

                // feature 9: highlight mode toggle (text books only). While on,
                // select text and pick a color from the "Highlight" edit menu.
                if book.format != .pdf {
                    Button { highlightMode.toggle() } label: {
                        Image(systemName: "highlighter")
                            .font(.title2)
                            .foregroundStyle(highlightMode ? Color.yellow : Color.primary)
                    }
                }

                // Contents / bookmarks / highlights
                Button { showContents = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.title2)
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

    // Page X / Y label shown below the progress bar.
    private var pageLabel: String {
        if book.format == .pdf, let pageCount = vm.pdfDocument?.pageCount, pageCount > 0 {
            let current = Int(vm.progress * Double(pageCount - 1)) + 1
            return "Page \(current) / \(pageCount)"
        }
        let charCount = vm.plainText.utf16.count
        guard charCount > 0 else { return "" }

        // Counter-based page number (most accurate — updated by page turns and seeks).
        if vm.currentPage > 0, vm.estimatedTotalPages > 0 {
            return "Page \(vm.currentPage) / \(vm.estimatedTotalPages)"
        }

        // BookPaginator index (exact, available after background computation).
        let starts = vm.pageStarts
        if starts.count > 1 {
            let charIndex = Int(vm.progress * Double(charCount))
            let current = starts.pageIndex(forChar: charIndex) + 1
            return "Page \(min(current, starts.count)) / \(starts.count)"
        }

        // Seed formula while neither counter nor paginator is ready.
        // Uses floor(textAreaH / lineHeight) so pageStep <= textAreaH.
        let fontSize   = max(8.0, settings.fontSize)
        let lineHeight = fontSize + max(0.0, settings.lineSpacing)
        let textW = vm.textAreaSize.width  > 0 ? vm.textAreaSize.width  : 350.0
        let textH = vm.textAreaSize.height > 0 ? vm.textAreaSize.height : 700.0
        let charsPerLine  = max(1.0, floor(textW / fontSize))
        let linesPerPage  = max(1.0, floor(textH / lineHeight))
        let charsPerPage  = max(1, Int(charsPerLine * linesPerPage))
        let total   = max(1, charCount / charsPerPage)
        let current = Int(vm.progress * Double(total)) + 1
        return "Page \(min(current, total)) / \(total)"
    }

    // feature 7: persist progress and record reading time
    private func saveProgress() {
        // Save exact UTF-16 character index so restore can set progress without
        // floating-point round-trip error. nil when unknown (PDF, or the text is
        // not loaded yet — e.g. the scene went inactive mid-parse) so a stale
        // stored index isn't clobbered with 0; a real 0 (start of book) is saved.
        let charCount = vm.plainText.utf16.count
        let charIndex: Int? = (book.format != .pdf && charCount > 0)
            ? Int(vm.progress * Double(charCount))
            : nil
        library.updateProgress(for: book.id, progress: vm.progress, charIndex: charIndex)
        if let start = sessionStart {
            ReadingStats.record(seconds: Date().timeIntervalSince(start))
            sessionStart = nil
        }
        // NOTE: TTS is deliberately NOT stopped here. saveProgress also runs on
        // scenePhase .inactive (lock screen, Control Center, call banner), and
        // stopping there killed background listening and the sleep timer.
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
