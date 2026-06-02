import Foundation

protocol BookParser: Sendable {
    nonisolated func parse(url: URL) throws -> ParsedBook
}

struct ParsedBook: Sendable {
    var title: String
    var author: String
    var plainText: String
    var wordCount: Int { plainText.split(separator: " ").count }
}

// Direct static dispatch — no instantiation, no init() isolation issues.
enum ParserFactory {
    nonisolated static func parse(url: URL, format: BookFormat) throws -> ParsedBook {
        switch format {
        case .txt:      return try PlainTextParser.run(url: url)
        case .epub:     return try EPUBParser.run(url: url)
        case .pdf:      return try PDFParser.run(url: url)
        case .markdown: return try MarkdownParser.run(url: url)
        }
    }
}
