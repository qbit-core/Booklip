import SwiftUI
import Combine
import PDFKit
import NaturalLanguage

// Sendable struct — completely nonisolated, safe to use in Task.detached
private struct BookLoader: Sendable {
    let url: URL
    let format: BookFormat

    nonisolated func load() throws -> (String, AttributedString) {
        let parsed = try ParserFactory.parse(url: url, format: format)
        var attributed = AttributedString("")
        if format == .markdown {
            attributed = (try? AttributedString(
                markdown: parsed.plainText,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString("")
        }
        print("[ReaderVM] parsed \(parsed.plainText.count) chars")
        return (parsed.plainText, attributed)
    }
}

@MainActor
class ReaderViewModel: ObservableObject {
    @Published var plainText: String = ""
    @Published var attributedText: AttributedString = AttributedString("")
    @Published var pdfDocument: PDFDocument?
    @Published var progress: Double = 0.0
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var highlights: [BookHighlight] = []  // feature 9: local highlight list
    // Incremented each time text content is replaced — lets NativeTextView skip O(n)
    // string comparison and avoid forcing layout immediately after a new load.
    private(set) var contentVersion: Int = 0

    let book: Book
    private var loadTask: Task<Void, Never>?

    init(book: Book) {
        self.book = book
        self.progress = book.progress
        self.highlights = book.highlights
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

        do {
            if format == .pdf {
                pdfDocument = await Task.detached(priority: .userInitiated) {
                    PDFDocument(url: fileURL)
                }.value
            } else {
                let loader = BookLoader(url: fileURL, format: format)
                let (text, attr) = try await Task.detached(priority: .userInitiated) {
                    try loader.load()
                }.value
                plainText = text
                attributedText = attr
                contentVersion += 1
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

    // feature 9: keep local highlight list in sync for display
    func addHighlight(_ highlight: BookHighlight) {
        highlights.append(highlight)
    }

    // feature 6: TTS starts from the first complete sentence visible at the current scroll position
    var ttsOffset: Int {
        firstSentenceOffset(atProgress: progress)
    }

    private func firstSentenceOffset(atProgress prog: Double) -> Int {
        let totalChars = plainText.count
        guard totalChars > 0 else { return 0 }
        let charOffset = min(Int(Double(totalChars) * prog), totalChars - 1)
        let index = plainText.index(plainText.startIndex, offsetBy: charOffset)

        // Use NLTokenizer for accurate sentence boundaries
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = plainText
        let sentenceRange = tokenizer.tokenRange(at: index)
        return plainText.distance(from: plainText.startIndex, to: sentenceRange.lowerBound)
    }
}
