import Foundation

enum BookFormat: String, Codable, CaseIterable {
    case txt, epub, pdf, markdown

    var displayName: String {
        switch self {
        case .txt: return "Text"
        case .epub: return "ePub"
        case .pdf: return "PDF"
        case .markdown: return "Markdown"
        }
    }

    static func from(url: URL) -> BookFormat? {
        switch url.pathExtension.lowercased() {
        case "txt": return .txt
        case "epub": return .epub
        case "pdf": return .pdf
        case "md", "markdown": return .markdown
        default: return nil
        }
    }
}

struct Book: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var author: String = "Unknown"
    var format: BookFormat
    var fileName: String
    var progress: Double = 0.0
    var dateAdded: Date = Date()
    var wordCount: Int = 0

    var fileURL: URL {
        BookStore.documentsDirectory.appendingPathComponent(fileName)
    }
}
