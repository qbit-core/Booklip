import SwiftUI
import Combine
import PDFKit

// Sendable struct — completely nonisolated, safe to use off the main actor.
private struct BookLoader: Sendable {
    let url: URL
    let format: BookFormat

    nonisolated func load() throws -> (String, AttributedString, [ContentBlock]) {
        let parsed = try ParserFactory.parse(url: url, format: format)
        var attributed = AttributedString("")
        if format == .markdown {
            attributed = (try? AttributedString(
                markdown: parsed.plainText,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString("")
        }
        print("[ReaderVM] parsed \(parsed.plainText.count) chars, \(parsed.blocks.count) blocks")
        return (parsed.plainText, attributed, parsed.blocks)
    }
}

@MainActor
class ReaderViewModel: ObservableObject {
    @Published var plainText: String = ""
    @Published var attributedText: AttributedString = AttributedString("")
    @Published var blocks: [ContentBlock] = []
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

        // Use a continuation so the background work runs at the same QoS
        // as the caller (user-interactive), avoiding priority inversion.
        do {
            if format == .pdf {
                let doc: PDFDocument? = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInteractive).async {
                        continuation.resume(returning: PDFDocument(url: fileURL))
                    }
                }
                pdfDocument = doc
            } else {
                let loader = BookLoader(url: fileURL, format: format)
                let (text, attr, parsedBlocks): (String, AttributedString, [ContentBlock]) = try await withCheckedThrowingContinuation { continuation in
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
