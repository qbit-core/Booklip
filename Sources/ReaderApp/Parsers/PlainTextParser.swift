import Foundation

struct PlainTextParser: BookParser, Sendable {
    nonisolated init() {}
    nonisolated static func run(url: URL) throws -> ParsedBook { try PlainTextParser().parse(url: url) }
    nonisolated func parse(url: URL) throws -> ParsedBook {
        let text = try readText(from: url)
        let title = url.deletingPathExtension().lastPathComponent
        return ParsedBook(title: title, author: "Unknown", plainText: text)
    }

    nonisolated private func readText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        print("[PlainTextParser] read \(data.count) bytes from \(url.lastPathComponent)")

        let encodings: [String.Encoding] = [
            .utf8,
            .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
            .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue))),
            .utf16,
            .windowsCP1252,
            .isoLatin1,
        ]

        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                print("[PlainTextParser] decoded with encoding \(encoding)")
                return text
            }
        }

        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
