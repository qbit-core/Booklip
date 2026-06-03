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
        print("[EPUB] opfPath=\(opfPath) base=\(opfBase) spine=\(spineHrefs.count) first=\(spineHrefs.prefix(3))")

        var fullText = ""
        var blocks: [ContentBlock] = []

        for href in spineHrefs {
            let entryPath = opfBase.isEmpty ? href : "\(opfBase)/\(href)"
            let chapterDir = (entryPath as NSString).deletingLastPathComponent
            guard let html = try? readEntry(entryPath, in: archive) else { continue }

            // Split the chapter HTML around <img> tags, preserving order.
            for segment in segments(of: html) {
                switch segment {
                case .html(let chunk):
                    let text = stripHTML(chunk)
                    if !text.isEmpty {
                        blocks.append(.text(text))
                        fullText += text + "\n\n"
                    }
                case .imageSrc(let src):
                    let imgPath = resolvePath(src, relativeTo: chapterDir)
                    if let data = try? readData(imgPath, in: archive), !data.isEmpty {
                        blocks.append(.image(data))
                    }
                }
            }
        }

        return ParsedBook(title: title, author: author,
                          plainText: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
                          blocks: blocks)
    }

    // MARK: - Helpers

    nonisolated private func readEntry(_ path: String, in archive: Archive) throws -> String {
        let data = try readData(path, in: archive)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    nonisolated private func readData(_ path: String, in archive: Archive) throws -> Data {
        // ZIP entries are case-sensitive; try the exact path then a case-insensitive match.
        let entry = archive[path] ?? archive.first {
            $0.path.caseInsensitiveCompare(path) == .orderedSame
        }
        guard let entry else { throw EPUBError.missingEntry(path) }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        return data
    }

    // MARK: - HTML segmentation (text vs. <img>)

    enum HTMLSegment {
        case html(String)
        case imageSrc(String)
    }

    nonisolated private func segments(of html: String) -> [HTMLSegment] {
        // Matches <img ... src="..."> and <image ... xlink:href="..."> (SVG cover pages)
        let pattern = #"<(?:img|image)\b[^>]*?(?:src|xlink:href)\s*=\s*["']([^"']+)["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return [.html(html)]
        }
        let ns = html as NSString
        var result: [HTMLSegment] = []
        var cursor = 0
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            if match.range.location > cursor {
                result.append(.html(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            if match.numberOfRanges > 1 {
                let src = ns.substring(with: match.range(at: 1))
                result.append(.imageSrc(src))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result.append(.html(ns.substring(from: cursor)))
        }
        return result.isEmpty ? [.html(html)] : result
    }

    // Resolve an href (possibly with ../) relative to the chapter's directory inside the zip.
    nonisolated private func resolvePath(_ src: String, relativeTo dir: String) -> String {
        // Strip any URL fragment/query
        var s = src
        if let hashIdx = s.firstIndex(of: "#") { s = String(s[..<hashIdx]) }
        // Percent-decode (image filenames sometimes encoded)
        s = s.removingPercentEncoding ?? s
        if s.hasPrefix("/") { return String(s.dropFirst()) }

        var components = dir.isEmpty ? [] : dir.components(separatedBy: "/")
        for part in s.components(separatedBy: "/") {
            switch part {
            case "", ".": continue
            case "..":    if !components.isEmpty { components.removeLast() }
            default:      components.append(part)
            }
        }
        return components.joined(separator: "/")
    }

    nonisolated private func extractOPFPath(from xml: String) throws -> String {
        let pattern = #"full-path="([^"]+)""#
        guard let match = xml.range(of: pattern, options: .regularExpression),
              let inner = xml[match].range(of: #""([^"]+)""#, options: .regularExpression)
        else { throw EPUBError.malformedContainer }
        return String(xml[inner]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    nonisolated private func parseOPF(_ xml: String, base: String) throws -> (title: String, author: String, hrefs: [String]) {
        guard let data = xml.data(using: .utf8) else { throw EPUBError.malformedContainer }
        let delegate = OPFDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        // Map spine idrefs → manifest hrefs (in reading order).
        var hrefs = delegate.spine.compactMap { delegate.manifest[$0] }
        // Fallback: if no spine, use all (x)html manifest items in document order.
        if hrefs.isEmpty {
            hrefs = delegate.manifestOrder.compactMap { id in
                guard let href = delegate.manifest[id] else { return nil }
                let lower = href.lowercased()
                return (lower.hasSuffix(".html") || lower.hasSuffix(".xhtml") || lower.hasSuffix(".htm")) ? href : nil
            }
        }
        let title  = delegate.title.isEmpty  ? "Unknown" : delegate.title
        let author = delegate.creator.isEmpty ? "Unknown" : delegate.creator
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

// XMLParser delegate for the OPF package document — robust to attribute
// order and namespace prefixes (dc:title, opf:item, etc.).
private final class OPFDelegate: NSObject, XMLParserDelegate {
    var title = ""
    var creator = ""
    var manifest: [String: String] = [:]   // id → href
    var manifestOrder: [String] = []        // manifest ids in document order
    var spine: [String] = []                // idrefs in reading order

    private var capturing: String?          // "title" or "creator"
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let local = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        switch local {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = href
                manifestOrder.append(id)
            }
        case "itemref":
            if let idref = attributeDict["idref"] { spine.append(idref) }
        case "title", "creator":
            capturing = local
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if local == "title", title.isEmpty, !value.isEmpty { title = value }
        if local == "creator", creator.isEmpty, !value.isEmpty { creator = value }
        if local == capturing { capturing = nil; buffer = "" }
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
