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

    var fileURL: URL {
        BookStore.documentsDirectory.appendingPathComponent(fileName)
    }

    var coverURL: URL? {
        coverFileName.map { BookStore.documentsDirectory.appendingPathComponent($0) }
    }

    // Custom Codable so that fields added in later versions (wordCount, dateAdded,
    // folderID, coverFileName, progressUpdated…) are decoded with decodeIfPresent.
    // Swift's auto-synthesised init(from:) calls decode(_:forKey:) — not
    // decodeIfPresent — even for properties that have a Swift default value, so any
    // field that is absent in old stored data causes the entire decode to throw and
    // BookStore.load() silently returns [].  Using decodeIfPresent + a default for
    // every non-essential field prevents that silent wipe on update.
    enum CodingKeys: String, CodingKey {
        case id, title, author, format, fileName, progress
        case dateAdded, wordCount, folderID, coverFileName, progressUpdated
    }

    init(title: String, author: String = "Unknown", format: BookFormat, fileName: String) {
        self.title = title
        self.author = author
        self.format = format
        self.fileName = fileName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decodeIfPresent(UUID.self,   forKey: .id)            ?? UUID()
        title         = try c.decode(String.self,          forKey: .title)
        author        = try c.decodeIfPresent(String.self, forKey: .author)        ?? "Unknown"
        format        = try c.decode(BookFormat.self,      forKey: .format)
        fileName      = try c.decode(String.self,          forKey: .fileName)
        progress      = try c.decodeIfPresent(Double.self, forKey: .progress)      ?? 0.0
        dateAdded     = try c.decodeIfPresent(Date.self,   forKey: .dateAdded)     ?? Date()
        wordCount     = try c.decodeIfPresent(Int.self,    forKey: .wordCount)     ?? 0
        folderID      = try c.decodeIfPresent(UUID.self,   forKey: .folderID)
        coverFileName = try c.decodeIfPresent(String.self, forKey: .coverFileName)
        progressUpdated = try c.decodeIfPresent(Date.self, forKey: .progressUpdated)
    }
}
