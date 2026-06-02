import SwiftUI
import Combine
import PDFKit

class LibraryViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var importError: String?
    @Published var showingImportError = false

    init() {
        books = BookStore.load()
        migrateUUIDTitles()
    }

    // Fixes books that were imported before the title-extraction fix.
    // PDFs: re-reads metadata. Others: cannot recover original name, leaves as-is.
    private func migrateUUIDTitles() {
        var changed = false
        for i in books.indices where looksLikeUUID(books[i].title) {
            switch books[i].format {
            case .pdf:
                if let doc = PDFDocument(url: books[i].fileURL),
                   let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                   !title.isEmpty {
                    books[i].title = title
                    changed = true
                }
            default:
                break
            }
        }
        if changed { BookStore.save(books) }
    }

    private func looksLikeUUID(_ string: String) -> Bool {
        UUID(uuidString: string) != nil
    }

    func importBook(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let format = BookFormat.from(url: url) else {
                    throw ImportError.unsupportedFormat(url.pathExtension)
                }
                let originalName = url.deletingPathExtension().lastPathComponent
                let fileName = try BookStore.importFile(from: url)
                let fileURL = BookStore.documentsDirectory.appendingPathComponent(fileName)
                let parsed = try ParserFactory.parse(url: fileURL, format: format)
                // Use original filename as title if the parser couldn't extract one
                let fileNameStem = (fileName as NSString).deletingPathExtension
                let title = parsed.title.isEmpty || parsed.title == fileNameStem ? originalName : parsed.title
                var book = Book(
                    title: title,
                    author: parsed.author,
                    format: format,
                    fileName: fileName
                )
                book.wordCount = parsed.wordCount
                DispatchQueue.main.async {
                    self.books.append(book)
                    BookStore.save(self.books)
                }
            } catch {
                DispatchQueue.main.async {
                    self.importError = error.localizedDescription
                    self.showingImportError = true
                }
            }
        }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets { BookStore.delete(book: books[index]) }
        books.remove(atOffsets: offsets)
        BookStore.save(books)
    }

    func updateProgress(for bookID: UUID, progress: Double) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].progress = progress
        BookStore.save(books)
    }
}

enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    var errorDescription: String? {
        if case .unsupportedFormat(let ext) = self {
            return "Unsupported file format: .\(ext). Supported formats: .txt, .epub, .pdf, .md"
        }
        return nil
    }
}
