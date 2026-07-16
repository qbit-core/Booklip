import Foundation
import ZIPFoundation

struct EPUBParser: BookParser, Sendable {
    nonisolated init() {}
    nonisolated static func run(url: URL) throws -> ParsedBook { try EPUBParser().parse(url: url) }
    nonisolated func parse(url: URL) throws -> ParsedBook {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBError.cannotOpenArchive
        }

        let containerXML = try readEntry("META-INF/container.xml", in: archive)
        let opfPath = try extractOPFPath(from: containerXML)
        let opfXML = try readEntry(opfPath, in: archive)

        let opfBase = (opfPath as NSString).deletingLastPathComponent
        let (title, author, spineHrefs) = try parseOPF(opfXML, base: opfBase)

        var fullText = ""
        for href in spineHrefs {
            let entryPath = opfBase.isEmpty ? href : "\(opfBase)/\(href)"
            if let html = try? readEntry(entryPath, in: archive) {
                fullText += stripHTML(html) + "\n\n"
            }
        }

        return ParsedBook(title: title, author: author, plainText: fullText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Helpers

    nonisolated private func readEntry(_ path: String, in archive: Archive) throws -> String {
        guard let entry = archive[path] else { throw EPUBError.missingEntry(path) }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    nonisolated private func extractOPFPath(from xml: String) throws -> String {
        let pattern = #"full-path="([^"]+)""#
        guard let match = xml.range(of: pattern, options: .regularExpression),
              let inner = xml[match].range(of: #""([^"]+)""#, options: .regularExpression)
        else { throw EPUBError.malformedContainer }
        return String(xml[inner]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    nonisolated private func parseOPF(_ xml: String, base: String) throws -> (title: String, author: String, hrefs: [String]) {
        let title  = extractTag("dc:title", from: xml) ?? extractTag("title", from: xml) ?? "Unknown"
        let author = extractTag("dc:creator", from: xml) ?? "Unknown"

        // Build id→href manifest map
        var manifest: [String: String] = [:]
        let manifestPattern = #"<item[^>]+id="([^"]*)"[^>]+href="([^"]*)"[^>]*/>"#
        for match in allMatches(of: manifestPattern, in: xml) {
            let groups = captureGroups(of: manifestPattern, in: match)
            if groups.count >= 2 { manifest[groups[0]] = groups[1] }
        }

        // Extract spine order
        var hrefs: [String] = []
        let spinePattern = #"<itemref[^>]+idref="([^"]*)"[^>]*/>"#
        for match in allMatches(of: spinePattern, in: xml) {
            let groups = captureGroups(of: spinePattern, in: match)
            if let id = groups.first, let href = manifest[id] {
                hrefs.append(href)
            }
        }

        return (title, author, hrefs)
    }

    nonisolated private func extractTag(_ tag: String, from xml: String) -> String? {
        let pattern = "<\(tag)[^>]*>([^<]*)<"
        guard let range = xml.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(xml[range])
        guard let valueRange = matched.range(of: ">([^<]*)<", options: .regularExpression) else { return nil }
        return String(matched[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "><"))
    }

    nonisolated private func allMatches(of pattern: String, in string: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).compactMap {
            Range($0.range, in: string).map { String(string[$0]) }
        }
    }

    nonisolated private func captureGroups(of pattern: String, in string: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string))
        else { return [] }
        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: string).map { String(string[$0]) }
        }
    }

    nonisolated private func stripHTML(_ html: String) -> String {
        var text = html
        // Remove script/style blocks
        for tag in ["script", "style"] {
            let pattern = "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>"
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Block elements → newlines
        let blockPattern = #"</?(p|div|br|h[1-6]|li|tr)[^>]*>"#
        text = text.replacingOccurrences(of: blockPattern, with: "\n", options: .regularExpression)
        // Strip remaining tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode common HTML entities
        let entities: [(String, String)] = [("&amp;","&"),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&apos;","'"),("&#160;"," "),("&nbsp;"," ")]
        for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
        // Collapse excess blank lines
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum EPUBError: LocalizedError {
    case cannotOpenArchive
    case missingEntry(String)
    case malformedContainer

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive:   return "Cannot open EPUB archive."
        case .missingEntry(let p): return "Missing entry: \(p)"
        case .malformedContainer:  return "Malformed container.xml"
        }
    }
}
