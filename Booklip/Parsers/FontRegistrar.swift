import CoreText
import Compression
import CryptoKit
import Foundation

// Registers embedded EPUB fonts with the system so they can be used by
// PostScript name. Needed to correctly render font-obfuscated books.
enum FontRegistrar {
    // PostScript name → (registered temp file, SHA-256 of the font bytes).
    // The digest matters: scrambled-codepoint books from the same publisher all
    // ship a font with the SAME PostScript name (e.g. "MaruBuri-Regular") but a
    // DIFFERENT per-book cmap. Deduplicating on name alone would render book B
    // with book A's font — garbled again. Same name + same bytes → reuse; same
    // name + different bytes → unregister the old one and register the new.
    private static var registered: [String: (url: URL, digest: Data)] = [:]
    // Keeps temp font files alive for the process lifetime.
    // CTFontManagerRegisterFontsForURL(.process) holds the path reference and
    // reads the file on demand — deleting it immediately causes CoreText to fail
    // with "FontParser could not open filePath". The OS cleans temp files on exit.
    private static var fontFileURLs: [URL] = []

    /// Registers every given font file and returns the PostScript name of the
    /// one to use for rendering. When `preferringCoverageOf` is a sample of the
    /// book's actual text, prefers whichever registered font has glyphs for
    /// most of it — otherwise "first in manifest order" can silently pick a
    /// decorative/Latin-only font declared before the real body font, which
    /// (for books that scramble codepoints as an anti-copy scheme, relying on
    /// the intended font's cmap to map them back) renders as garbled-but-valid
    /// -looking text rather than obviously missing glyphs. Falls back to the
    /// first successfully-registered font if none clearly cover the sample.
    static func registerFirst(_ datas: [Data], preferringCoverageOf sampleText: String? = nil) -> String? {
        var candidates: [String] = []
        for data in datas {
            if let name = register(data) { candidates.append(name) }
        }
        guard !candidates.isEmpty else { return nil }
        guard let sample = sampleText, !sample.isEmpty, candidates.count > 1 else { return candidates.first }

        let scalars = sampleScalars(from: sample)
        guard !scalars.isEmpty else { return candidates.first }

        for name in candidates {
            if coverage(of: name, scalars: scalars) >= 0.8 { return name }
        }
        return candidates.first
    }

    // MARK: - Body font resolution (glyph coverage)

    /// Resolves the font actually used for body text. Returns `preferred` when
    /// it has glyphs for (nearly) all of the sampled text; otherwise the first
    /// fallback that does.
    ///
    /// Why this exists — measured on a 7.8M-char Korean EPUB, same backward
    /// seek (59% → 22%):
    ///   Georgia (no Hangul glyphs)      173,439 ms   (spinner for ~3 minutes)
    ///   AppleSDGothicNeo-Regular             86 ms
    /// A process sample showed the time was NOT layout: it was
    /// NSTextStorage.fixFontAttribute(in:) → addAttribute → NSMutableRLEArray
    /// insert → memmove. When the base font can't render a character, TextKit 1
    /// substitutes a font PER RUN by inserting attribute runs into the storage,
    /// and each insert memmoves the whole run array — quadratic in the number
    /// of Hangul/Latin transitions, and it happens lazily inside ensureLayout /
    /// layoutIfNeeded / glyphRange(forBoundingRect:), so it looked like a layout
    /// cost. Giving TextKit a base font that already covers the script makes
    /// the fixing pass a no-op. The visible difference is small (Latin letters
    /// and digits render in the fallback instead of the chosen font); books the
    /// chosen font can render (e.g. English in Georgia) are unaffected.
    static func effectiveFontName(_ preferred: String, sample: String) -> String {
        guard !sample.isEmpty else { return preferred }
        // Sampling is O(window); hashing the sample (not the multi-MB text) keeps
        // this cheap enough to call from every update pass.
        let scalars = sampleScalars(from: sample)
        let key = "\(preferred)|\((sample as NSString).length)|\(String(String.UnicodeScalarView(scalars)).hashValue)"
        if let cached = effectiveFontCache[key] { return cached }

        var resolved = preferred
        if !scalars.isEmpty, coverage(of: preferred, scalars: scalars) < 0.9 {
            for candidate in bodyFallbackFonts where candidate != preferred {
                if coverage(of: candidate, scalars: scalars) >= 0.9 {
                    resolved = candidate
                    break
                }
            }
            if resolved != preferred {
                // LOG: print("[Font] \(preferred) lacks glyphs for this book's text — rendering body with \(resolved)")
            }
        }
        effectiveFontCache[key] = resolved
        return resolved
    }

    private static var effectiveFontCache: [String: String] = [:]

    // Fallbacks tried in order when the chosen font can't render the text.
    // CJK-capable fonts shipped on both iOS and macOS.
    private static let bodyFallbackFonts: [String] = [
        "AppleSDGothicNeo-Regular",   // Korean (also Latin, digits)
        "HiraginoSans-W3",            // Japanese
        "PingFangSC-Regular",         // Simplified Chinese
        "PingFangTC-Regular",         // Traditional Chinese
    ]

    /// Up to ~300 distinct non-whitespace scalars, drawn from four points in the
    /// text (start / 25% / 50% / 75%) so a Latin preface or a scrambled cover
    /// page doesn't misrepresent the body. Uses UTF-16 offsets so this is O(1)
    /// on multi-megabyte strings.
    private static func sampleScalars(from text: String) -> [Unicode.Scalar] {
        let ns = text as NSString
        let total = ns.length
        guard total > 0 else { return [] }
        let window = 1500
        var collected = ""
        for fraction in [0.0, 0.25, 0.5, 0.75] {
            let start = min(Int(Double(total) * fraction), max(0, total - 1))
            let length = min(window, total - start)
            guard length > 0 else { continue }
            var range = NSRange(location: start, length: length)
            // Don't split a surrogate pair at either edge.
            range = ns.rangeOfComposedCharacterSequences(for: range)
            collected += ns.substring(with: range)
            if total <= window { break }
        }
        // Deterministic: Set iteration order varies per instance, which made the
        // cache key (and the sampled subset) differ between calls. Sort, then
        // stride so the ≤300 picks are spread across the codepoint range rather
        // than biased toward low (Latin/punctuation) codepoints.
        let sorted = Array(Set(collected.unicodeScalars))
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .sorted { $0.value < $1.value }
        guard sorted.count > 300 else { return sorted }
        let step = Double(sorted.count) / 300.0
        return (0..<300).map { sorted[min(sorted.count - 1, Int(Double($0) * step))] }
    }

    /// Fraction (0...1) of `scalars` that `fontName` has real glyphs for.
    private static func coverage(of fontName: String, scalars: [Unicode.Scalar]) -> Double {
        guard !scalars.isEmpty else { return 0 }
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        var checked = 0
        var missing = 0
        for scalar in scalars {
            checked += 1
            let utf16 = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            let ok = utf16.withUnsafeBufferPointer { u16 in
                glyphs.withUnsafeMutableBufferPointer { g in
                    CTFontGetGlyphsForCharacters(font, u16.baseAddress!, g.baseAddress!, utf16.count)
                }
            }
            if !ok || glyphs.allSatisfy({ $0 == 0 }) { missing += 1 }
        }
        let coverage = 1.0 - Double(missing) / Double(max(1, checked))
        // LOG: print(String(format: "[Font] coverage %@ = %.0f%% (%d/%d sampled chars)",
        // LOG: fontName as NSString, coverage * 100, checked - missing, checked))
        return coverage
    }

    static func register(_ data: Data) -> String? {
        // CTFontManager only understands raw SFNT (TrueType/OpenType) data.
        // Many EPUB export tools embed fonts as WOFF (a zlib-compressed SFNT
        // container) since it's the web-standard format — CoreText silently
        // fails to parse it, which previously meant these books fell back to
        // the reading-settings font. Some Korean web-novel platforms combine
        // this with a scrambled-codepoint anti-copy scheme in the HTML, where
        // the embedded font's cmap is the ONLY thing that maps the scrambled
        // text back to correct glyphs — so a silent WOFF failure shows up as
        // garbled-but-valid-looking Hangul, not obviously "missing" text.
        var fontData = data
        if isWOFF(data) {
            guard let converted = sfntData(fromWOFF: data) else {
                // LOG: print("[Font] WOFF→SFNT conversion failed (corrupt or unsupported table compression)")
                return nil
            }
            fontData = converted
        } else if isWOFF2(data) {
            // WOFF2 compresses tables with Brotli, which has no built-in Apple
            // decoder — would need to vendor a Brotli implementation to support it.
            // LOG: print("[Font] WOFF2 embedded font unsupported (Brotli compression) — skipping")
            return nil
        }

        // Create font descriptors from data to obtain the PostScript name.
        // CTFontManagerCreateFontDescriptorsFromData is the modern replacement
        // for creating font references from in-memory data.
        let descriptors = CTFontManagerCreateFontDescriptorsFromData(fontData as CFData)
            as? [CTFontDescriptor]
        guard let descriptor = descriptors?.first,
              let psName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        else {
            // LOG: print("[Font] CTFontManagerCreateFontDescriptorsFromData failed, bytes=\(fontData.count)")
            return nil
        }

        let digest = Data(SHA256.hash(data: fontData))
        if let existing = registered[psName] {
            if existing.digest == digest { return psName }
            // Same PostScript name, different font — another book's scrambled
            // font. Drop the old registration so this one can take the name.
            var unregError: Unmanaged<CFError>?
            let removed = CTFontManagerUnregisterFontsForURL(existing.url as CFURL, .process, &unregError)
            // LOG: print("[Font] replacing \(psName) (different bytes); unregister ok=\(removed)")
            registered[psName] = nil
            // Keep the old temp file on disk — attributed strings from the previous
            // book may still hold a reference to it.
        }

        // Write to a temp file and register via CTFontManagerRegisterFontsForURL.
        // Important: do NOT delete the file after registration — CoreText keeps the
        // URL reference and reads the file lazily, so removing it immediately causes
        // a "FontParser could not open filePath" failure.  The temp directory is
        // cleared automatically when the process exits.
        let ext = isOpenType(fontData) ? "otf" : "ttf"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        guard (try? fontData.write(to: tmp)) != nil else { return nil }

        var cfError: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(tmp as CFURL, .process, &cfError)

        if ok {
            registered[psName] = (tmp, digest)
            fontFileURLs.append(tmp)   // keep the file alive
            // LOG: print("[Font] registered \(psName) bytes=\(fontData.count)")
            return psName
        }
        // Take ownership of the returned CFError exactly once. (A previous version
        // called takeRetainedValue() inside an `if let` and then takeUnretainedValue()
        // on the same Unmanaged in the failure log — a use-after-free whenever the
        // code wasn't alreadyRegistered, e.g. duplicated-name 305.)
        let error: CFError? = cfError?.takeRetainedValue()
        // Already registered by the system or a previous call → still usable.
        if let error, CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue {
            // LOG: print("[Font] \(psName) already registered (system or earlier) — reusing by name")
            registered[psName] = (tmp, digest)
            fontFileURLs.append(tmp)   // keep it; the URL may still be referenced
            return psName
        }
        // LOG: print("[Font] registration failed for \(psName): \(error.map { "\($0)" } ?? "?")")
        try? FileManager.default.removeItem(at: tmp)   // registration failed — clean up
        return nil
    }

    // OpenType/CFF fonts begin with the "OTTO" signature; everything else is TrueType.
    private static func isOpenType(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.prefix(4) == Data([0x4F, 0x54, 0x54, 0x4F])
    }

    private static func isWOFF(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.prefix(4) == Data([0x77, 0x4F, 0x46, 0x46])   // "wOFF"
    }

    private static func isWOFF2(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.prefix(4) == Data([0x77, 0x4F, 0x46, 0x32])   // "wOF2"
    }

    // MARK: - WOFF1 → SFNT reconstruction
    //
    // WOFF wraps the original TTF/OTF's table directory + zlib-compressed table
    // data. Reconstructing the SFNT: rebuild the 12-byte offset table (using the
    // original "flavor" as the sfnt version), then a 16-byte-per-table directory,
    // then the decompressed table bytes themselves (4-byte aligned).
    // Spec: https://www.w3.org/TR/WOFF/
    private static func sfntData(fromWOFF data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 44 else { return nil }

        func u32(_ off: Int) -> UInt32 {
            (UInt32(bytes[off]) << 24) | (UInt32(bytes[off + 1]) << 16)
                | (UInt32(bytes[off + 2]) << 8) | UInt32(bytes[off + 3])
        }
        func u16(_ off: Int) -> UInt16 {
            (UInt16(bytes[off]) << 8) | UInt16(bytes[off + 1])
        }

        let flavor = u32(4)
        let numTables = Int(u16(12))
        guard numTables > 0 else { return nil }

        struct Entry { let tag: UInt32; let offset: Int; let compLength: Int; let origLength: Int; let checksum: UInt32 }
        var entries: [Entry] = []
        var pos = 44
        for _ in 0..<numTables {
            guard pos + 20 <= bytes.count else { return nil }
            entries.append(Entry(tag: u32(pos), offset: Int(u32(pos + 4)),
                                 compLength: Int(u32(pos + 8)), origLength: Int(u32(pos + 12)),
                                 checksum: u32(pos + 16)))
            pos += 20
        }

        var tables: [(tag: UInt32, data: [UInt8], checksum: UInt32)] = []
        for e in entries {
            guard e.offset >= 0, e.compLength >= 0,
                  e.offset + e.compLength <= bytes.count else { return nil }
            let compBytes = Array(bytes[e.offset..<(e.offset + e.compLength)])
            let tableBytes: [UInt8]
            if e.compLength == e.origLength {
                tableBytes = compBytes   // stored uncompressed
            } else {
                guard let inflated = zlibInflate(compBytes, expectedSize: e.origLength) else { return nil }
                tableBytes = inflated
            }
            tables.append((e.tag, tableBytes, e.checksum))
        }

        // sfnt offset table: version, numTables, searchRange, entrySelector, rangeShift.
        var entrySelector: UInt16 = 0
        while (1 << (entrySelector + 1)) <= numTables { entrySelector += 1 }
        let searchRange = (1 << entrySelector) * 16
        let rangeShift = numTables * 16 - searchRange

        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        func appendU32(_ v: UInt32) {
            out.append(UInt8((v >> 24) & 0xFF)); out.append(UInt8((v >> 16) & 0xFF))
            out.append(UInt8((v >> 8) & 0xFF));  out.append(UInt8(v & 0xFF))
        }
        func appendU16(_ v: Int) {
            out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF))
        }

        appendU32(flavor)
        appendU16(numTables)
        appendU16(searchRange)
        appendU16(Int(entrySelector))
        appendU16(rangeShift)

        let dirStart = out.count
        out.append(contentsOf: [UInt8](repeating: 0, count: numTables * 16))

        var dataStarts: [Int] = []
        for t in tables {
            while out.count % 4 != 0 { out.append(0) }
            dataStarts.append(out.count)
            out.append(contentsOf: t.data)
        }

        for (i, t) in tables.enumerated() {
            var dirPos = dirStart + i * 16
            func writeU32(_ v: UInt32) {
                out[dirPos] = UInt8((v >> 24) & 0xFF); out[dirPos + 1] = UInt8((v >> 16) & 0xFF)
                out[dirPos + 2] = UInt8((v >> 8) & 0xFF); out[dirPos + 3] = UInt8(v & 0xFF)
                dirPos += 4
            }
            writeU32(t.tag)
            writeU32(t.checksum)
            writeU32(UInt32(dataStarts[i]))
            writeU32(UInt32(t.data.count))
        }

        return Data(out)
    }

    // WOFF table data is standard zlib (RFC1950: 2-byte header + deflate stream +
    // 4-byte Adler32 trailer). Apple's Compression framework's COMPRESSION_ZLIB
    // decodes raw deflate only, so the header/trailer are stripped before decoding.
    private static func zlibInflate(_ input: [UInt8], expectedSize: Int) -> [UInt8]? {
        guard expectedSize > 0 else { return [] }
        guard input.count > 6 else { return nil }
        let deflateBytes = Array(input[2..<(input.count - 4)])
        var output = [UInt8](repeating: 0, count: expectedSize)
        let decodedSize = output.withUnsafeMutableBytes { dst -> Int in
            deflateBytes.withUnsafeBytes { src -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress,
                      let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, expectedSize, srcBase, deflateBytes.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decodedSize == expectedSize else { return nil }
        return output
    }
}
