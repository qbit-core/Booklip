import Foundation
import PDFKit

struct PDFParser: BookParser, Sendable {
    nonisolated init() {}
    nonisolated static func run(url: URL) throws -> ParsedBook { try PDFParser().parse(url: url) }
    nonisolated func parse(url: URL) throws -> ParsedBook {
        guard let doc = PDFDocument(url: url) else {
            throw PDFParserError.cannotLoad
        }
        var text = ""
        for i in 0..<doc.pageCount {
            text += doc.page(at: i)?.string ?? ""
            text += "\n\n"
        }
        let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let author = (doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String) ?? "Unknown"
        return ParsedBook(title: title, author: author, plainText: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum PDFParserError: LocalizedError {
    case cannotLoad
    var errorDescription: String? { "Cannot load PDF document." }
}
