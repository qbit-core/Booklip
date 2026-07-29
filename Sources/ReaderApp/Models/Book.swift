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

// Stored text highlight (feature 9)
struct BookHighlight: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var startOffset: Int
    var length: Int
    var text: String
    var createdAt: Date = Date()
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
    var coverImageFileName: String? = nil   // feature 8: PDF first-page thumbnail
    var highlights: [BookHighlight] = []    // feature 9: user highlights

    var fileURL: URL {
        BookStore.documentsDirectory.appendingPathComponent(fileName)
    }

    var isFinished: Bool { progress >= 0.99 }
}
