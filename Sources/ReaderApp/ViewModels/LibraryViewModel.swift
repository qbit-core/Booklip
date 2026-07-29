import SwiftUI
import Combine
import PDFKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
                let fileNameStem = (fileName as NSString).deletingPathExtension
                let title = parsed.title.isEmpty || parsed.title == fileNameStem ? originalName : parsed.title
                var book = Book(
                    title: title,
                    author: parsed.author,
                    format: format,
                    fileName: fileName
                )
                book.wordCount = parsed.wordCount

                // feature 8: extract first-page thumbnail for PDFs
                if format == .pdf, let png = Self.extractPDFCover(from: fileURL) {
                    book.coverImageFileName = BookStore.saveCoverImage(png, bookID: book.id)
                }

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

    // feature 8: render first PDF page at 2× scale and return PNG data
    private static func extractPDFCover(from url: URL) -> Data? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        return image.pngData()
        #elseif os(macOS)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            NSColor.white.setFill()
            NSBezierPath.fill(NSRect(origin: .zero, size: size))
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #endif
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

    // feature 9: add a text highlight to a book
    func addHighlight(_ highlight: BookHighlight, to bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].highlights.append(highlight)
        BookStore.save(books)
    }

    func removeHighlight(id highlightID: UUID, from bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].highlights.removeAll { $0.id == highlightID }
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
