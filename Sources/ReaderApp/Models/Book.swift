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

enum SortOption: String, CaseIterable, Identifiable {
    case dateAdded = "Date Added"
    case title     = "Title"
    case author    = "Author"
    case progress  = "Progress"
    case format    = "Format"
    var id: String { rawValue }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case list        = "List"
    case smallGrid   = "Small"
    case mediumGrid  = "Medium"
    case largeGrid   = "Large"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .list:       return "list.bullet"
        case .smallGrid:  return "square.grid.4x3.fill"
        case .mediumGrid: return "square.grid.3x3.fill"
        case .largeGrid:  return "square.grid.2x2.fill"
        }
    }

    /// Minimum cell width for the adaptive grid (nil = single-column list).
    var minCellWidth: CGFloat? {
        switch self {
        case .list:       return nil
        case .smallGrid:  return 100
        case .mediumGrid: return 150
        case .largeGrid:  return 210
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
    var folderID: UUID? = nil
    var coverFileName: String? = nil
    var progressUpdated: Date? = nil   // when progress was last changed (for iCloud sync)
    var contentSnippet: String = ""    // first ~10 KB of plain text, for library content search

    var fileURL: URL {
        BookStore.documentsDirectory.appendingPathComponent(fileName)
    }

    var coverURL: URL? {
        coverFileName.map { BookStore.documentsDirectory.appendingPathComponent($0) }
    }
}
