import Foundation
import ZIPFoundation
import CryptoKit
import os.signpost

struct EPUBParser: BookParser, Sendable {

    nonisolated init() {}
    nonisolated static func run(url: URL) throws -> ParsedBook { try EPUBParser().parse(url: url) }

    // MARK: - Precompiled regexes
    // NSRegularExpression is immutable after init and safe to match from
    // multiple threads concurrently. Compiling these once (instead of inside
    // stripHTML, called per HTML chunk per chapter) removes most of the
    // per-call overhead that made a 300+ chapter EPUB take ~38s to parse.
    private static let reScript = try! NSRegularExpression(
        pattern: #"<script[^>]*>[\s\S]*?</script>"#, options: .caseInsensitive)
    private static let reStyle = try! NSRegularExpression(
        pattern: #"<style[^>]*>[\s\S]*?</style>"#, options: .caseInsensitive)
    private static let reBlock = try! NSRegularExpression(
        pattern: #"</?(p|div|br|h[1-6]|li|tr)[^>]*>"#, options: .caseInsensitive)
    private static let reTags = try! NSRegularExpression(pattern: #"<[^>]+>"#)
    private static let reBlankLines = try! NSRegularExpression(pattern: #"\n{3,}"#)
    private static let reNumEntity = try! NSRegularExpression(
        pattern: #"&#(x[0-9a-fA-F]+|\d+);"#, options: .caseInsensitive)
    private static let reImgTag = try! NSRegularExpression(
        pattern: #"<(?:img|image)\b[^>]*?(?:src|xlink:href)\s*=\s*["']([^"']+)["'][^>]*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let reHeading = try! NSRegularExpression(
        pattern: #"<h[1-3][^>]*>([\s\S]*?)</h[1-3]>"#, options: .caseInsensitive)

    nonisolated func parse(url: URL) throws -> ParsedBook {
        // Open-Unzip: archive open + OPF metadata read.
        let unzipID = OSSignpostID(log: booklipSpLog)
        os_signpost(.begin, log: booklipSpLog, name: "Open-Unzip", signpostID: unzipID,
                    "file=%{public}s", url.lastPathComponent)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            os_signpost(.end, log: booklipSpLog, name: "Open-Unzip", signpostID: unzipID,
                        "status=failed")
            throw EPUBError.cannotOpenArchive
        }

        // Archive[path] / archive.first{} do a LINEAR SCAN of the central directory,
        // and each step re-reads that entry's central-directory + local-file-header
        // structs from disk (see ZIPFoundation's makeIterator — fseeko/fread per
        // entry). Calling that once per spine chapter (~1397×) against a multi-
        // thousand-entry archive was effectively O(N×M) disk I/O — likely the
        // single biggest contributor to the ~32s parse, ahead of even the stripHTML
        // cost. Build the path→Entry map with ONE full scan up front; every
        // subsequent readEntry/readData call becomes an in-memory O(1) lookup.
        let _indexT0 = CFAbsoluteTimeGetCurrent()
        let entryIndex: [String: Entry] = Dictionary(archive.map { ($0.path, $0) },
                                                      uniquingKeysWith: { first, _ in first })
        print(String(format: "[TIME] Open-BuildEntryIndex %.0f ms  entries=%d",
                     (CFAbsoluteTimeGetCurrent() - _indexT0) * 1000, entryIndex.count))

        let containerXML = try readEntry("META-INF/container.xml", in: archive, index: entryIndex)
        let opfPath = try extractOPFPath(from: containerXML)
        let opfXML = try readEntry(opfPath, in: archive, index: entryIndex)
        os_signpost(.end, log: booklipSpLog, name: "Open-Unzip", signpostID: unzipID,
                    "status=ok opfPath=%{public}s", opfPath)

        let opfBase = (opfPath as NSString).deletingLastPathComponent
        let opf = try parseOPF(opfXML, base: opfBase)
        let spineHrefs = opf.hrefs
        print("[EPUB] spine=\(spineHrefs.count) fonts=\(opf.fontHrefs.count)")

        // Extract (and de-obfuscate) embedded fonts.
        let fonts = extractFonts(opf.fontHrefs, cssHrefs: opf.cssHrefs, base: opfBase,
                                 uid: opf.uniqueIdentifier, archive: archive, index: entryIndex)

        // Extract cover image.
        var cover: Data?
        if let coverHref = opf.coverHref {
            cover = try? readData(resolvePath(coverHref, relativeTo: opfBase), in: archive, index: entryIndex)
        }

        var fullText = ""
        var blocks: [ContentBlock] = []
        var chapterMarks: [(title: String, offset: Int)] = []
        var hrefToOffset: [String: Int] = [:]   // spine href (no fragment) → start offset
        var imageBlockCount = 0

        let parseID = OSSignpostID(log: booklipSpLog)
        os_signpost(.begin, log: booklipSpLog, name: "Open-ParseHTML", signpostID: parseID,
                    "spine=%d", spineHrefs.count)

        // Phase 1 (serial): ZIPFoundation's Archive is not safe for concurrent
        // reads, so all HTML must be pulled off the zip on this thread. Cheap
        // relative to stripHTML — just I/O plus one heading-regex match/chapter.
        struct RawSegment {
            enum Kind { case text(String); case imageSrc(String) }
            let kind: Kind
            var stripped: String = ""
        }
        struct ChapterRaw {
            let hrefKey: String
            let chapterDir: String
            let titleHint: String?
            var segments: [RawSegment]
        }
        let _phase1T0 = CFAbsoluteTimeGetCurrent()
        let readID = OSSignpostID(log: booklipSpLog)
        os_signpost(.begin, log: booklipSpLog, name: "Open-ReadHTML", signpostID: readID,
                    "spine=%d", spineHrefs.count)
        var chapterRaws: [ChapterRaw] = []
        chapterRaws.reserveCapacity(spineHrefs.count)
        for (i, href) in spineHrefs.enumerated() {
            let entryPath = opfBase.isEmpty ? href : "\(opfBase)/\(href)"
            let chapterDir = (entryPath as NSString).deletingLastPathComponent
            guard let html = try? readEntry(entryPath, in: archive, index: entryIndex) else { continue }
            let titleHint = firstHeading(in: html)
                ?? (href as NSString).lastPathComponent
                    .replacingOccurrences(of: ".xhtml", with: "")
                    .replacingOccurrences(of: ".html", with: "")
            var segs: [RawSegment] = []
            for segment in segments(of: html) {
                switch segment {
                case .html(let chunk):   segs.append(RawSegment(kind: .text(chunk)))
                case .imageSrc(let src): segs.append(RawSegment(kind: .imageSrc(src)))
                }
            }
            chapterRaws.append(ChapterRaw(
                hrefKey: (href as NSString).lastPathComponent,
                chapterDir: chapterDir,
                titleHint: titleHint.isEmpty ? nil : titleHint,
                segments: segs))
            _ = i
        }
        os_signpost(.end, log: booklipSpLog, name: "Open-ReadHTML", signpostID: readID)
        print(String(format: "[TIME] Open-ReadHTML(Phase1) %.0f ms  chapters=%d",
                     (CFAbsoluteTimeGetCurrent() - _phase1T0) * 1000, chapterRaws.count))

        // Phase 2 (concurrent): stripHTML is a pure function over its String
        // argument — no shared mutable state — so every chunk across every
        // chapter can run across all cores at once. This is the part that was
        // ~38s serial; precompiled regexes + concurrentPerform address both
        // the compilation overhead and the single-core bottleneck.
        let _phase2T0 = CFAbsoluteTimeGetCurrent()
        struct TextWork { let ci: Int; let si: Int; let text: String }
        var works: [TextWork] = []
        for (ci, ch) in chapterRaws.enumerated() {
            for (si, seg) in ch.segments.enumerated() {
                if case .text(let t) = seg.kind { works.append(TextWork(ci: ci, si: si, text: t)) }
            }
        }
        let stripID = OSSignpostID(log: booklipSpLog)
        os_signpost(.begin, log: booklipSpLog, name: "Open-StripHTML", signpostID: stripID,
                    "chunks=%d", works.count)
        var strippedResults = [String](repeating: "", count: works.count)
        if !works.isEmpty {
            strippedResults.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: works.count) { i in
                    buf[i] = stripHTML(works[i].text)
                }
            }
        }
        os_signpost(.end, log: booklipSpLog, name: "Open-StripHTML", signpostID: stripID)
        for (i, work) in works.enumerated() {
            chapterRaws[work.ci].segments[work.si].stripped = strippedResults[i]
        }
        print(String(format: "[TIME] Open-StripHTML(Phase2) %.0f ms  chunks=%d",
                     (CFAbsoluteTimeGetCurrent() - _phase2T0) * 1000, works.count))

        // Phase 3 (serial): image reads need the archive again; text assembly
        // must preserve spine + in-chapter segment order for offsets to be correct.
        //
        // FIX (O(N²) — the actual ~32s source): `(fullText as NSString).length`
        // was recomputed on EVERY chapter iteration, which re-bridges/re-measures
        // the WHOLE accumulated string so far — O(current length) per call, and
        // since fullText grows to the full document size, summed across ~1397
        // chapters that's O(N²) in the final text length. Replaced with a
        // `runningOffset` counter updated incrementally (O(segment length) per
        // append, O(N) total). Likewise `fullText += x` (repeated concatenation)
        // is replaced with a `[String]` buffer + one `joined()` at the end, so
        // there's no repeated re-copying of the growing string.
        //
        // Character accounting: only `.text` segments consume characters in
        // fullText's offset space (`stripped.utf16.count + 2` for the "\n\n"
        // separator) — Phase 1/3 never insert any placeholder for `.imageSrc`
        // segments (images only ever become `.image(data)` blocks, no text is
        // appended for them), so `runningOffset` is left untouched for images.
        let _phase3T0 = CFAbsoluteTimeGetCurrent()
        let assembleID = OSSignpostID(log: booklipSpLog)
        os_signpost(.begin, log: booklipSpLog, name: "Open-AssembleText", signpostID: assembleID,
                    "chapters=%d", chapterRaws.count)
        var runningOffset = 0
        var parts: [String] = []
        parts.reserveCapacity(works.count * 2)
        for (i, ch) in chapterRaws.enumerated() {
            let startOffset = runningOffset
            hrefToOffset[ch.hrefKey] = startOffset
            let chapterTitle = ch.titleHint ?? "Chapter \(i + 1)"
            chapterMarks.append((chapterTitle, startOffset))

            for seg in ch.segments {
                switch seg.kind {
                case .text:
                    if !seg.stripped.isEmpty {
                        blocks.append(.text(seg.stripped))
                        parts.append(seg.stripped)
                        parts.append("\n\n")
                        runningOffset += seg.stripped.utf16.count + 2
                    }
                case .imageSrc(let src):
                    let imgPath = resolvePath(src, relativeTo: ch.chapterDir)
                    if let data = try? readData(imgPath, in: archive, index: entryIndex), !data.isEmpty {
                        blocks.append(.image(data))
                        imageBlockCount += 1
                    }
                    // No characters added — images never appear in fullText's
                    // offset space, only as their own .image block.
                }
            }
        }
        fullText = parts.joined()
        os_signpost(.end, log: booklipSpLog, name: "Open-AssembleText", signpostID: assembleID,
                    "chars=%d", runningOffset)
        print(String(format: "[TIME] Open-AssembleText(Phase3) %.0f ms  chars=%d images=%d",
                     (CFAbsoluteTimeGetCurrent() - _phase3T0) * 1000, runningOffset, imageBlockCount))

        os_signpost(.end, log: booklipSpLog, name: "Open-ParseHTML", signpostID: parseID,
                    "chars=%d blocks=%d images=%d",
                    runningOffset, blocks.count, imageBlockCount)

        let totalLen = max(1, runningOffset)

        // Prefer a real TOC (NCX/nav) for proper titles + nesting; map each
        // entry's target file to the spine offset we recorded. Fall back to
        // per-spine headings.
        var chapters: [Chapter] = []
        if let tocEntries = parseTOC(opf: opf, base: opfBase, archive: archive, index: entryIndex), !tocEntries.isEmpty {
            chapters = tocEntries.compactMap { entry in
                let file = (entry.href.components(separatedBy: "#").first ?? entry.href as String)
                let key = (file as NSString).lastPathComponent
                guard let offset = hrefToOffset[key] else { return nil }
                return Chapter(title: entry.title,
                               progress: Double(offset) / Double(totalLen),
                               level: entry.level)
            }
        }
        if chapters.isEmpty {
            chapters = chapterMarks.map {
                Chapter(title: $0.title, progress: Double($0.offset) / Double(totalLen))
            }
        }

        return ParsedBook(title: opf.title, author: opf.author,
                          plainText: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
                          blocks: blocks,
                          embeddedFonts: fonts,
                          coverImage: cover,
                          chapters: chapters)
    }

    struct TOCEntry { var title: String; var href: String; var level: Int }

    // Parse the NCX (EPUB2) or nav document (EPUB3) into a flat, ordered,
    // level-tagged list of TOC entries.
    nonisolated private func parseTOC(opf: OPFInfo, base: String, archive: Archive, index: [String: Entry]) -> [TOCEntry]? {
        // EPUB2 NCX
        if let ncx = opf.ncxHref,
           let xml = try? readEntry(resolvePath(ncx, relativeTo: base), in: archive, index: index),
           let data = xml.data(using: .utf8) {
            let delegate = NCXDelegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            if !delegate.entries.isEmpty { return delegate.entries }
        }
        // EPUB3 nav document (regex over the toc nav's anchors)
        if let nav = opf.navHref,
           let html = try? readEntry(resolvePath(nav, relativeTo: base), in: archive, index: index) {
            return parseNavHTML(html)
        }
        return nil
    }

    // Extracts <a href="...">label</a> entries inside the nav, using <ol>
    // nesting depth as the level.
    nonisolated private func parseNavHTML(_ html: String) -> [TOCEntry] {
        let ns = html as NSString
        var entries: [TOCEntry] = []
        var level = 0
        let token = try? NSRegularExpression(
            pattern: #"<ol\b|</ol>|<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#,
            options: .caseInsensitive)
        token?.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let frag = ns.substring(with: m.range).lowercased()
            if frag.hasPrefix("<ol") { level += 1 }
            else if frag.hasPrefix("</ol") { level = max(0, level - 1) }
            else if m.numberOfRanges >= 3 {
                let href = ns.substring(with: m.range(at: 1))
                let label = stripHTML(ns.substring(with: m.range(at: 2)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty {
                    entries.append(TOCEntry(title: label, href: href, level: max(0, level - 1)))
                }
            }
        }
        return entries
    }

    // First heading (h1–h3) text in a chapter's HTML, used as its TOC title.
    nonisolated private func firstHeading(in html: String) -> String? {
        let ns = html as NSString
        guard let m = Self.reHeading.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        let heading = stripHTML(ns.substring(with: m.range(at: 1)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return heading.isEmpty ? nil : String(heading.prefix(80))
    }

    // MARK: - Embedded fonts (+ EPUB font de-obfuscation)

    nonisolated private func extractFonts(_ hrefs: [String], cssHrefs: [String], base: String,
                                          uid: String?, archive: Archive, index: [String: Entry]) -> [Data] {
        // Font discovery, in priority order (deduplicated by archive path):
        //   1. @font-face src:url(...) in the book's stylesheets — this is what
        //      the book ACTUALLY renders with, so it wins.
        //   2. Manifest items with a font media-type / extension.
        //   3. Any archive entry with a font extension (last resort).
        // Trusting the manifest alone is not enough: some publishers (e.g. Korean
        // light-novel houses using a scrambled-codepoint anti-copy font) ship an
        // OPF that lists a font file that does NOT exist in the archive
        // (`Fonts/KoPubWorldDotumMedium.ttf`), while the real font
        // (`Fonts/unique_font.ttf`) is referenced only from style.css. With no
        // font registered the scrambled text fell back to the system font and
        // rendered as garbled-but-valid-looking Hangul.
        var paths: [String] = []
        var seen: Set<String> = []
        func add(_ path: String) {
            let key = path.lowercased()
            guard !key.isEmpty, !seen.contains(key), index[path] != nil
                    || index.keys.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame })
            else { return }
            seen.insert(key)
            paths.append(path)
        }

        for css in cssHrefs {
            let cssPath = resolvePath(css, relativeTo: base)
            guard let text = try? readEntry(cssPath, in: archive, index: index), !text.isEmpty else { continue }
            let cssDir = (cssPath as NSString).deletingLastPathComponent
            for url in fontFaceURLs(in: text) {
                add(resolvePath(url, relativeTo: cssDir))
            }
        }
        for href in hrefs { add(resolvePath(href, relativeTo: base)) }
        for path in index.keys.sorted() where Self.isFontPath(path) { add(path) }

        print("[EPUB] font candidates=\(paths)")
        guard !paths.isEmpty else { return [] }

        // Which font paths are obfuscated, and by which algorithm?
        let obfuscation = parseEncryption(in: archive, index: index)   // path → algorithm

        var fonts: [Data] = []
        for path in paths {
            guard var data = try? readData(path, in: archive, index: index), !data.isEmpty else { continue }

            // Match the encryption entry by suffix (encryption.xml URIs may be root-relative).
            if let algo = obfuscation.first(where: { path.hasSuffix($0.key) || $0.key.hasSuffix(path) })?.value,
               let uid {
                data = deobfuscate(data, uid: uid, algorithm: algo)
            }
            fonts.append(data)
        }
        return fonts
    }

    nonisolated private static func isFontPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".ttf") || lower.hasSuffix(".otf") || lower.hasSuffix(".ttc")
            || lower.hasSuffix(".woff") || lower.hasSuffix(".woff2")
    }

    // Every url(...) inside an @font-face { ... } block, in document order.
    nonisolated private func fontFaceURLs(in css: String) -> [String] {
        let ns = css as NSString
        var urls: [String] = []
        let blockPattern = #"@font-face\s*\{([^}]*)\}"#
        let urlPattern = #"url\(\s*["']?([^"')]+)["']?\s*\)"#
        guard let blockRe = try? NSRegularExpression(pattern: blockPattern, options: .caseInsensitive),
              let urlRe = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive)
        else { return [] }
        blockRe.enumerateMatches(in: css, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 2 else { return }
            let body = ns.substring(with: m.range(at: 1))
            let bodyNS = body as NSString
            urlRe.enumerateMatches(in: body, range: NSRange(location: 0, length: bodyNS.length)) { u, _, _ in
                guard let u, u.numberOfRanges >= 2 else { return }
                let raw = bodyNS.substring(with: u.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip data: URIs and absolute http(s) references — not archive entries.
                guard !raw.lowercased().hasPrefix("data:"), !raw.lowercased().hasPrefix("http") else { return }
                urls.append(raw)
            }
        }
        return urls
    }

    // Returns map of cipher-reference path → algorithm URI.
    nonisolated private func parseEncryption(in archive: Archive, index: [String: Entry]) -> [String: String] {
        guard let xml = try? readEntry("META-INF/encryption.xml", in: archive, index: index), !xml.isEmpty else { return [:] }
        let ns = xml as NSString
        var result: [String: String] = [:]
        // Pair each <EncryptionMethod Algorithm="..."> with the following <CipherReference URI="...">
        let pattern = #"Algorithm\s*=\s*["']([^"']+)["'][\s\S]*?URI\s*=\s*["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            regex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges >= 3 else { return }
                let algo = ns.substring(with: m.range(at: 1))
                let uri  = (ns.substring(with: m.range(at: 2)).removingPercentEncoding ?? ns.substring(with: m.range(at: 2)))
                result[uri] = algo
            }
        }
        return result
    }

    nonisolated private func deobfuscate(_ data: Data, uid: String, algorithm: String) -> Data {
        let key: [UInt8]
        let prefixLength: Int
        if algorithm.contains("idpf") {
            // IDPF: SHA-1 of the UID with all whitespace removed.
            let cleaned = uid.components(separatedBy: .whitespacesAndNewlines).joined()
            key = sha1(Array(cleaned.utf8))
            prefixLength = 1040
        } else if algorithm.contains("adobe") {
            // Adobe: 16 bytes from the UID's UUID hex digits.
            let hex = uid.replacingOccurrences(of: "urn:uuid:", with: "")
                         .replacingOccurrences(of: "-", with: "")
            var bytes: [UInt8] = []
            var idx = hex.startIndex
            while idx < hex.endIndex, let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) {
                if let b = UInt8(hex[idx..<next], radix: 16) { bytes.append(b) }
                idx = next
            }
            key = bytes
            prefixLength = 1024
        } else {
            return data
        }
        guard !key.isEmpty else { return data }

        var bytes = [UInt8](data)
        let n = min(prefixLength, bytes.count)
        for i in 0..<n { bytes[i] ^= key[i % key.count] }
        return Data(bytes)
    }

    nonisolated private func sha1(_ bytes: [UInt8]) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: Data(bytes)))
    }

    // MARK: - Helpers

    nonisolated private func readEntry(_ path: String, in archive: Archive, index: [String: Entry]) throws -> String {
        let data = try readData(path, in: archive, index: index)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    nonisolated private func readData(_ path: String, in archive: Archive, index: [String: Entry]) throws -> Data {
        // O(1) via the pre-built path→Entry index — archive[path] / archive.first{}
        // do a linear scan of the central directory where EACH step re-reads that
        // entry's central-directory + local-file-header structs from disk (see
        // ZIPFoundation's Archive.makeIterator), so calling it once per spine
        // chapter against a multi-thousand-entry archive was effectively O(N×M)
        // disk I/O — the dominant cost in the original ~32s parse.
        // Case-insensitive fallback stays a linear scan (over the index's keys,
        // no disk I/O) — rare path, only hit when the exact key isn't found.
        let entry = index[path] ?? index.first { $0.key.caseInsensitiveCompare(path) == .orderedSame }?.value
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
        let ns = html as NSString
        var result: [HTMLSegment] = []
        var cursor = 0
        Self.reImgTag.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
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

    struct OPFInfo {
        var title: String
        var author: String
        var hrefs: [String]
        var fontHrefs: [String]
        var cssHrefs: [String]
        var uniqueIdentifier: String?
        var coverHref: String?
        var ncxHref: String?
        var navHref: String?
    }

    nonisolated private func parseOPF(_ xml: String, base: String) throws -> OPFInfo {
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
        // Resolve cover: EPUB3 marker → EPUB2 meta id → first image as fallback.
        var coverHref = delegate.coverImageHref
        if coverHref == nil, let id = delegate.metaCoverID { coverHref = delegate.manifest[id] }
        if coverHref == nil {
            coverHref = delegate.imageHrefs.first { $0.lowercased().contains("cover") }
                ?? delegate.imageHrefs.first
        }

        return OPFInfo(
            title:  delegate.title.isEmpty  ? "Unknown" : delegate.title,
            author: delegate.creator.isEmpty ? "Unknown" : delegate.creator,
            hrefs: hrefs,
            fontHrefs: delegate.fontHrefs,
            cssHrefs: delegate.cssHrefs,
            uniqueIdentifier: delegate.uniqueIdentifier,
            coverHref: coverHref,
            ncxHref: delegate.ncxHref,
            navHref: delegate.navHref
        )
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

    // Pure function of its argument — no shared state — safe to call from any
    // thread, including concurrently via DispatchQueue.concurrentPerform.
    // Uses NSMutableString + NSRegularExpression.replaceMatches(in:) instead of
    // String.replacingOccurrences(of:options:.regularExpression) — the latter
    // compiles a fresh NSRegularExpression internally on every call, which
    // dominated cost when invoked per HTML chunk across every chapter.
    nonisolated private func stripHTML(_ html: String) -> String {
        let ms = NSMutableString(string: html)
        func full() -> NSRange { NSRange(location: 0, length: ms.length) }
        // Remove script/style blocks
        Self.reScript.replaceMatches(in: ms, options: [], range: full(), withTemplate: "")
        Self.reStyle.replaceMatches(in: ms, options: [], range: full(), withTemplate: "")
        // Block elements → newlines
        Self.reBlock.replaceMatches(in: ms, options: [], range: full(), withTemplate: "\n")
        // Strip remaining tags
        Self.reTags.replaceMatches(in: ms, options: [], range: full(), withTemplate: "")
        // Decode HTML entities (named + numeric/hex)
        decodeEntities(ms)
        // Collapse excess blank lines
        Self.reBlankLines.replaceMatches(in: ms, options: [], range: full(), withTemplate: "\n\n")
        return (ms as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Named entities are substring replacements (&amp; MUST run first — a
    // source containing the literal text "&amp;lt;" means the author wants to
    // display "&lt;" as text, not "<"; decoding &lt; before &amp; would wrongly
    // collapse it to "<" instead of the intended literal "&lt;"). Numeric and
    // hex entities (&#13; &#x0D; etc.) are decoded in one regex pass — matches
    // are computed once against a snapshot of the string, then applied in
    // reverse so earlier ranges stay valid as later ones are replaced in place.
    // A decoded &#13; / &#x0D; (CR) is dropped rather than inserted, since EPUB
    // line breaks are represented by the block-element → "\n" pass above.
    nonisolated private func decodeEntities(_ ms: NSMutableString) {
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"),
            ("&#160;", "\u{00A0}"), ("&nbsp;", "\u{00A0}")
        ]
        for (entity, rep) in named {
            ms.replaceOccurrences(of: entity, with: rep, options: .literal,
                                  range: NSRange(location: 0, length: ms.length))
        }
        let matches = Self.reNumEntity.matches(in: ms as String, range: NSRange(location: 0, length: ms.length))
        for m in matches.reversed() {
            guard m.numberOfRanges >= 2 else { continue }
            let inner = (ms as NSString).substring(with: m.range(at: 1))   // e.g. "13" or "x0D"
            let codePoint: UInt32?
            if inner.first == "x" || inner.first == "X" {
                codePoint = UInt32(inner.dropFirst(), radix: 16)
            } else {
                codePoint = UInt32(inner)
            }
            var replacement = ""
            if let cp = codePoint, cp != 0x0D, cp != 0x00, let scalar = Unicode.Scalar(cp) {
                replacement = String(scalar)
            }
            ms.replaceCharacters(in: m.range, with: replacement)
        }
    }
}

// XMLParser delegate for the OPF package document — robust to attribute
// order and namespace prefixes (dc:title, opf:item, etc.).
// `nonisolated` opts the whole type out of the project's default main-actor
// isolation so it can run inside the nonisolated background parser.
nonisolated private final class OPFDelegate: NSObject, XMLParserDelegate {
    var title = ""
    var creator = ""
    var manifest: [String: String] = [:]    // id → href
    var manifestOrder: [String] = []         // manifest ids in document order
    var fontHrefs: [String] = []             // hrefs of embedded font items
    var cssHrefs: [String] = []              // hrefs of stylesheets (for @font-face discovery)
    var uniqueIDRef: String?                 // package@unique-identifier (an id)
    var identifiers: [String: String] = [:]  // id → dc:identifier value
    var spine: [String] = []                 // idrefs in reading order
    var coverImageHref: String?              // EPUB3 properties="cover-image"
    var metaCoverID: String?                 // EPUB2 <meta name="cover" content="id">
    var imageHrefs: [String] = []            // all image manifest items (fallback)
    var ncxHref: String?                     // EPUB2 toc.ncx
    var navHref: String?                     // EPUB3 nav document

    private var capturing: String?           // "title" / "creator" / "identifier"
    private var capturingIDKey: String?      // id attr of the identifier being captured
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let local = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        switch local {
        case "package":
            uniqueIDRef = attributeDict["unique-identifier"]
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = href
                manifestOrder.append(id)
                let media = attributeDict["media-type"]?.lowercased() ?? ""
                let lower = href.lowercased()
                if media.contains("font") || lower.hasSuffix(".ttf") || lower.hasSuffix(".otf")
                    || lower.hasSuffix(".ttc") || lower.hasSuffix(".woff") || lower.hasSuffix(".woff2") {
                    fontHrefs.append(href)
                }
                if media == "text/css" || lower.hasSuffix(".css") { cssHrefs.append(href) }
                let isImage = media.hasPrefix("image/") || lower.hasSuffix(".jpg")
                    || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".gif")
                if isImage { imageHrefs.append(href) }
                let props = attributeDict["properties"] ?? ""
                // EPUB3 cover marker
                if props.contains("cover-image") { coverImageHref = href }
                // TOC documents
                if media.contains("dtbncx") || lower.hasSuffix(".ncx") { ncxHref = href }
                if props.contains("nav") { navHref = href }
            }
        case "itemref":
            if let idref = attributeDict["idref"] { spine.append(idref) }
        case "meta":
            // EPUB2 cover reference: <meta name="cover" content="cover-id"/>
            if attributeDict["name"]?.lowercased() == "cover" {
                metaCoverID = attributeDict["content"]
            }
        case "title", "creator":
            capturing = local; buffer = ""
        case "identifier":
            capturing = local; capturingIDKey = attributeDict["id"]; buffer = ""
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
        if local == "identifier", !value.isEmpty {
            identifiers[capturingIDKey ?? "_\(identifiers.count)"] = value
        }
        if local == capturing { capturing = nil; capturingIDKey = nil; buffer = "" }
    }

    // The package's unique identifier string (used as the font de-obfuscation key).
    var uniqueIdentifier: String? {
        if let ref = uniqueIDRef, let v = identifiers[ref] { return v }
        return identifiers.values.first
    }
}

// Parses an NCX navMap into ordered, level-tagged TOC entries.
nonisolated private final class NCXDelegate: NSObject, XMLParserDelegate {
    var entries: [EPUBParser.TOCEntry] = []
    private var depth = 0
    private var capturingLabel = false
    private var labelBuffer = ""
    private var pendingTitle: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let local = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        switch local {
        case "navpoint":
            depth += 1
        case "text":
            capturingLabel = true
            labelBuffer = ""
        case "content":
            if let src = attributeDict["src"], let title = pendingTitle {
                entries.append(.init(title: title, href: src, level: max(0, depth - 1)))
                pendingTitle = nil
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingLabel { labelBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        switch local {
        case "text":
            capturingLabel = false
            let t = labelBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if pendingTitle == nil, !t.isEmpty { pendingTitle = t }
        case "navpoint":
            depth = max(0, depth - 1)
        default:
            break
        }
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
