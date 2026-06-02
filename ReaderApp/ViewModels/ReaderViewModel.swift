import SwiftUI
import Combine
import PDFKit

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

    let book: Book
    private var loadTask: Task<Void, Never>?

    init(book: Book) {
        self.book = book
        self.progress = book.progress
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

    var ttsOffset: Int {
        let clampedOffset = max(0, min(Int(Double(plainText.count) * progress), plainText.count))
        let index = plainText.index(plainText.startIndex, offsetBy: clampedOffset)
        return plainText.distance(from: plainText.startIndex, to: index)
    }
}
