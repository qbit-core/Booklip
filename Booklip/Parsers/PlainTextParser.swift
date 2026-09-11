import Foundation
import os.signpost

struct PlainTextParser: BookParser, Sendable {
    nonisolated init() {}
    nonisolated static func run(url: URL) throws -> ParsedBook { try PlainTextParser().parse(url: url) }
    nonisolated func parse(url: URL) throws -> ParsedBook {
        let text = try readText(from: url)
        let title = url.deletingPathExtension().lastPathComponent
        return ParsedBook(title: title, author: "Unknown", plainText: text)
    }

    nonisolated private func readText(from url: URL) throws -> String {
        let t0 = CFAbsoluteTimeGetCurrent()
        let data = try Data(contentsOf: url)
        print(String(format: "[TIME] Open-ParseHTML(txt-load) %.0f ms  bytes=%d",
                     (CFAbsoluteTimeGetCurrent() - t0) * 1000, data.count))

        let encodings: [String.Encoding] = [
            .utf8,
            .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
            .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue))),
            .utf16,
            .windowsCP1252,
            .isoLatin1,
        ]

        let t1 = CFAbsoluteTimeGetCurrent()
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                print(String(format: "[TIME] Open-ParseHTML(txt-decode) %.0f ms  encoding=%@ utf16=%d",
                             (CFAbsoluteTimeGetCurrent() - t1) * 1000,
                             "\(encoding)" as NSString, (text as NSString).length))
                return text
            }
        }

        let fallback = String(data: data, encoding: .isoLatin1) ?? ""
        print(String(format: "[TIME] Open-ParseHTML(txt-decode) %.0f ms  encoding=isoLatin1(fallback) utf16=%d",
                     (CFAbsoluteTimeGetCurrent() - t1) * 1000, (fallback as NSString).length))
        return fallback
    }
}
