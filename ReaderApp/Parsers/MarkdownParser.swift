import Foundation

struct MarkdownParser: BookParser, Sendable {
    nonisolated init() {}
    nonisolated static func run(url: URL) throws -> ParsedBook { try MarkdownParser().parse(url: url) }
    nonisolated func parse(url: URL) throws -> ParsedBook {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let title = extractTitle(from: raw) ?? url.deletingPathExtension().lastPathComponent
        // Keep raw markdown — ReaderViewModel will render it via AttributedString
        return ParsedBook(title: title, author: "Unknown", plainText: raw)
    }

    nonisolated private func extractTitle(from text: String) -> String? {
        let firstLine = text.components(separatedBy: "\n").first ?? ""
        if firstLine.hasPrefix("# ") { return String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return nil
    }
}
