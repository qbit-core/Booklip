import SwiftUI
import Combine
import PDFKit
import os.signpost

// Sendable struct — completely nonisolated, safe to use off the main actor.
private struct BookLoader: Sendable {
    let url: URL
    let format: BookFormat

    nonisolated func load() throws -> (String, AttributedString, [ContentBlock], [Data], [Chapter]) {
        let parsed = try ParserFactory.parse(url: url, format: format)
        var attributed = AttributedString("")
        if format == .markdown {
            attributed = (try? AttributedString(
                markdown: parsed.plainText,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString("")
        }
        print("[ReaderVM] parsed \((parsed.plainText as NSString).length) utf16, \(parsed.blocks.count) blocks, \(parsed.embeddedFonts.count) fonts, \(parsed.chapters.count) chapters")
        return (parsed.plainText, attributed, parsed.blocks, parsed.embeddedFonts, parsed.chapters)
    }
}

@MainActor
class ReaderViewModel: ObservableObject {
    @Published var plainText: String = ""
    @Published var attributedText: AttributedString = AttributedString("")
    @Published var blocks: [ContentBlock] = []
    @Published var embeddedFontName: String?   // PostScript name of the book's embedded font, if any
    @Published var chapters: [Chapter] = []
    @Published var bookmarks: [Bookmark] = []
    @Published var highlights: [Highlight] = []
    @Published var pdfDocument: PDFDocument?
    @Published var progress: Double = 0.0
    @Published var isLoading = true
    @Published var errorMessage: String?

    /// Exact page-start character offsets, computed by BookPaginator. Empty until ready.
    @Published var pageStarts: [Int] = []
    /// 0…1 while paginating, nil when idle (not yet started or complete).
    @Published var paginationProgress: Double? = nil
    /// Actual rendered text area (textContainer minus padding), set by the coordinator.
    @Published var textAreaSize: CGSize = .zero
    /// Counter-based current page (1-based). Updated by page turns and seeks.
    @Published var currentPage: Int = 0
    /// Total pages estimate. Locked in after 10 calibration samples.
    @Published var estimatedTotalPages: Int = 0

    func advancePage() {
        guard estimatedTotalPages > 0 else { return }
        currentPage = min(currentPage + 1, estimatedTotalPages)
    }

    func retreatPage() {
        currentPage = max(currentPage - 1, 1)
    }

    /// Called after a seek or on initial open to rebase the counter.
    func rebasePage(atCharIdx charIdx: Int, totalChars: Int) {
        guard estimatedTotalPages > 0, totalChars > 0 else { return }
        let cpp = max(1, totalChars / estimatedTotalPages)
        currentPage = max(1, min(charIdx / cpp + 1, estimatedTotalPages))
    }

    /// Seeds total-pages estimate from a charsPerPage value (formula or profile).
    func seedTotalPages(charsPerPage: Int) {
        let charCount = (plainText as NSString).length
        guard charCount > 0, charsPerPage > 0 else { return }
        let total = max(1, charCount / charsPerPage)
        if estimatedTotalPages == 0 || abs(total - estimatedTotalPages) > estimatedTotalPages / 10 {
            estimatedTotalPages = total
        }
        // Initialise currentPage from charIndex if not yet set.
        if currentPage == 0, book.charIndex > 0 {
            currentPage = max(1, min(book.charIndex / charsPerPage + 1, total))
        } else if currentPage == 0 {
            currentPage = 1
        }
    }

    /// Called when 10 calibration samples produce a stable median charsPerPage.
    func lockCharsPerPage(_ cpp: Int, profileKey: String) {
        PaginationProfile.save(charsPerPage: cpp, key: profileKey)
        let charCount = (plainText as NSString).length
        guard charCount > 0, cpp > 0 else { return }
        let total = max(1, charCount / cpp)
        // BUG (fixed): progress must be computed under the OLD estimatedTotalPages
        // (i.e. the OLD charsPerPage/seed) before it's overwritten below — computing
        // it after reassignment made numerator and denominator both derive from the
        // NEW cpp, collapsing `progress * total` back to exactly `currentPage`, i.e.
        // a complete no-op: currentPage never actually rebased to the new cpp.
        let oldTotal = estimatedTotalPages
        let progress = oldTotal > 0 ? Double(currentPage) / Double(oldTotal) : 0
        estimatedTotalPages = total
        currentPage = max(1, min(Int(progress * Double(total)) + 1, total))
        print(String(format: "[PAGE-CAL] locked charsPerPage=%d totalPages=%d currentPage=%d",
                     cpp, total, currentPage))
    }

    let book: Book
    private var loadTask: Task<Void, Never>?
    private var paginationTask: Task<Void, Never>?

    /// Called by the coordinator once the UITextView's bounds are stable.
    func startPagination(containerWidth: CGFloat, containerHeight: CGFloat, settings: ReadingSettings) {
        guard book.format != .pdf else { return }
        let text = plainText
        guard !text.isEmpty else { return }
        let fontName = settings.useEmbeddedFont ? (embeddedFontName ?? settings.fontName) : settings.fontName
        let key = BookPaginator.CacheKey(
            bookID: book.id,
            fontName: fontName,
            fontSize: settings.fontSize,
            lineSpacing: settings.lineSpacing,
            containerWidth: Double(containerWidth),
            containerHeight: Double(containerHeight)
        )
        paginationTask?.cancel()
        paginationTask = Task {
            await MainActor.run { paginationProgress = 0 }
            do {
                let result = try await BookPaginator.shared.compute(text: text, key: key) { fraction in
                    Task { @MainActor in self.paginationProgress = fraction }
                }
                await MainActor.run {
                    self.pageStarts = result
                    self.paginationProgress = nil
                }
            } catch {
                await MainActor.run { self.paginationProgress = nil }
            }
        }
    }

    init(book: Book) {
        self.book = book
        self.progress = book.progress
        self.bookmarks = BookStore.loadBookmarks(book.id)
        self.highlights = BookStore.loadHighlights(book.id)
    }

    // MARK: - Highlights

    func addHighlight(range: NSRange, colorName: String, snippet: String, progress: Double) {
        let h = Highlight(bookID: book.id, location: range.location, length: range.length,
                          colorName: colorName, snippet: snippet, progress: progress)
        highlights.append(h)
        highlights.sort { $0.progress < $1.progress }
        BookStore.saveHighlights(highlights, for: book.id)
    }

    func deleteHighlight(_ h: Highlight) {
        highlights.removeAll { $0.id == h.id }
        BookStore.saveHighlights(highlights, for: book.id)
    }

    // MARK: - Navigation / bookmarks

    func jump(to targetProgress: Double) {
        progress = min(max(targetProgress, 0), 1)
    }

    private func snippet(atProgress p: Double) -> String {
        let ns = plainText as NSString
        guard ns.length > 0 else { return "" }
        let loc = min(max(Int(Double(ns.length) * p), 0), ns.length - 1)
        let end = min(loc + 60, ns.length)
        return ns.substring(with: NSRange(location: loc, length: end - loc))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func addBookmark() {
        let mark = Bookmark(bookID: book.id, progress: progress, snippet: snippet(atProgress: progress))
        bookmarks.append(mark)
        bookmarks.sort { $0.progress < $1.progress }
        BookStore.saveBookmarks(bookmarks, for: book.id)
    }

    func deleteBookmark(_ mark: Bookmark) {
        bookmarks.removeAll { $0.id == mark.id }
        BookStore.saveBookmarks(bookmarks, for: book.id)
    }

    var isCurrentPositionBookmarked: Bool {
        bookmarks.contains { abs($0.progress - progress) < 0.005 }
    }

    func load() {
        guard loadTask == nil else { return }
        loadTask = Task { await performLoad() }
    }

    private func performLoad() async {
        isLoading = true
        errorMessage = nil

        // Open-EndToEnd: file selected → didLayout complete (end fires in Coordinator.didLayout).
        let e2eID = OSSignpostID(log: booklipSpLog)
        OpenSignpostState.shared.endToEndID = e2eID
        os_signpost(.begin, log: booklipSpLog, name: "Open-EndToEnd", signpostID: e2eID,
                    "format=%{public}s", book.format.rawValue)
        let _e2eStart = CFAbsoluteTimeGetCurrent()
        OpenSignpostState.shared.endToEndT0 = _e2eStart

        let fileURL = book.fileURL
        let format = book.format
        print("[TIME] Open-EndToEnd BEGIN format=\(format)")

        // Use a continuation so the background work runs at the same QoS
        // as the caller (user-interactive), avoiding priority inversion.
        do {
            if format == .pdf {
                let result: (PDFDocument?, String) = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInteractive).async {
                        let doc = PDFDocument(url: fileURL)
                        // Extract text so TTS works for PDFs too.
                        var text = ""
                        if let doc {
                            for i in 0..<doc.pageCount { text += (doc.page(at: i)?.string ?? "") + "\n" }
                        }
                        continuation.resume(returning: (doc, text))
                    }
                }
                pdfDocument = result.0
                plainText = result.1
            } else {
                let loader = BookLoader(url: fileURL, format: format)
                let vmLoadID = OSSignpostID(log: booklipSpLog)
                os_signpost(.begin, log: booklipSpLog, name: "Open-VMLoad", signpostID: vmLoadID,
                            "url=%{public}s", fileURL.lastPathComponent)
                let _vmStart = CFAbsoluteTimeGetCurrent()
                let (text, attr, parsedBlocks, fonts, parsedChapters): (String, AttributedString, [ContentBlock], [Data], [Chapter]) = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInteractive).async {
                        do {
                            continuation.resume(returning: try loader.load())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                os_signpost(.end, log: booklipSpLog, name: "Open-VMLoad", signpostID: vmLoadID,
                            "chars=%d blocks=%d", (text as NSString).length, parsedBlocks.count)
                print(String(format: "[TIME] Open-VMLoad %.0f ms  utf16=%d blocks=%d",
                             (CFAbsoluteTimeGetCurrent() - _vmStart) * 1000, (text as NSString).length, parsedBlocks.count))
                plainText = text
                attributedText = attr
                blocks = parsedBlocks
                embeddedFontName = FontRegistrar.registerFirst(fonts)
                chapters = parsedChapters
                // Restore progress from exact charIndex (integer) to avoid
                // float round-trip error from book.progress (Double).
                if book.charIndex > 0 {
                    let charCount = (text as NSString).length
                    if charCount > 0 {
                        progress = Double(book.charIndex) / Double(charCount)
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            print("[ReaderVM] error: \(error)")
        }

        isLoading = false
        print("[ReaderVM] done isLoading=false utf16=\((plainText as NSString).length)")
    }

    func updateProgress(_ value: Double) {
        progress = min(max(value, 0), 1)
    }

    // UTF-16 offset (matches NSString/AVSpeechSynthesizer ranges) at current progress.
    var ttsOffset: Int {
        let length = (plainText as NSString).length
        return max(0, min(Int(Double(length) * progress), length))
    }
}
