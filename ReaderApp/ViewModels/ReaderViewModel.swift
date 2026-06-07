import SwiftUI
import Combine
import PDFKit

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
        print("[ReaderVM] parsed \(parsed.plainText.count) chars, \(parsed.blocks.count) blocks, \(parsed.embeddedFonts.count) fonts, \(parsed.chapters.count) chapters")
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
    @Published var pdfDocument: PDFDocument?
    @Published var progress: Double = 0.0
    @Published var isLoading = true
    @Published var errorMessage: String?

    let book: Book
    private var loadTask: Task<Void, Never>?

    init(book: Book) {
        self.book = book
        self.progress = book.progress
        self.bookmarks = BookStore.loadBookmarks(book.id)
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

        let fileURL = book.fileURL
        let format = book.format
        print("[ReaderVM] load format=\(format) exists=\(FileManager.default.fileExists(atPath: fileURL.path))")

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
                let (text, attr, parsedBlocks, fonts, parsedChapters): (String, AttributedString, [ContentBlock], [Data], [Chapter]) = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInteractive).async {
                        do {
                            continuation.resume(returning: try loader.load())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                plainText = text
                attributedText = attr
                blocks = parsedBlocks
                embeddedFontName = FontRegistrar.registerFirst(fonts)
                chapters = parsedChapters
            }
        } catch {
            errorMessage = error.localizedDescription
            print("[ReaderVM] error: \(error)")
        }

        isLoading = false
        print("[ReaderVM] done isLoading=false text.count=\(plainText.count)")
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
