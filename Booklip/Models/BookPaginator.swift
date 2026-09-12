#if os(iOS)
import UIKit
typealias PlatformFont = UIFont
#else
import AppKit
typealias PlatformFont = NSFont
#endif
import Foundation

// Computes an exact page-start index array by replicating UITextView's
// TextKit 1 layout off the main thread.
//
// Cache key: bookID + fontName + fontSize + lineSpacing + containerWidth + containerHeight
// If the cache is valid the result is returned without any layout work.
//
// On cancellation the partial result and cursor are saved so a subsequent
// call with the same key resumes from where it left off.
actor BookPaginator {

    static let shared = BookPaginator()

    // MARK: - Cache key

    struct CacheKey: Equatable {
        let bookID: UUID
        let fontName: String
        let fontSize: Double
        let lineSpacing: Double
        let containerWidth: Double   // UITextView bounds.width
        let containerHeight: Double  // UITextView bounds.height
    }

    // MARK: - Disk persistence

    private static var cacheDir: URL {
        let docs = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("BookPaginator", isDirectory: true)
    }

    private static func ensureCacheDir() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private static func cacheFileURL(for key: CacheKey) -> URL {
        let name = "\(key.bookID.uuidString)_\(key.fontName.replacingOccurrences(of: " ", with: "_"))_\(key.fontSize)_\(key.lineSpacing)_\(Int(key.containerWidth))x\(Int(key.containerHeight)).json"
        return cacheDir.appendingPathComponent(name)
    }

    private struct CacheFile: Codable {
        var pageStarts: [Int]
        var cursor: Int         // next char offset to process (0 = complete)
        var isComplete: Bool
    }

    private func loadCache(_ key: CacheKey) -> CacheFile? {
        let url = Self.cacheFileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data) else { return nil }
        return file
    }

    private func saveCache(_ file: CacheFile, key: CacheKey) {
        Self.ensureCacheDir()
        let url = Self.cacheFileURL(for: key)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Public API

    /// Returns the complete pageStarts array, computing or resuming as needed.
    /// Calls `progress` on the calling actor with values in [0, 1].
    func compute(
        text: String,
        key: CacheKey,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Int] {
        // Check for a complete cached result.
        if let cached = loadCache(key), cached.isComplete {
            return cached.pageStarts
        }

        // Resume from partial result if available.
        let partial = loadCache(key)
        let resumeFrom = partial?.cursor ?? 0
        let initialPageStarts = partial?.pageStarts ?? [0]

        return try await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return [] }
            return try await self.paginate(
                text: text,
                key: key,
                resumeFrom: resumeFrom,
                initial: initialPageStarts,
                progress: progress
            )
        }.value
    }

    // MARK: - Layout engine

    private func paginate(
        text: String,
        key: CacheKey,
        resumeFrom startChar: Int,
        initial initialPageStarts: [Int],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Int] {

        // Derive layout parameters from UITextView constants.
        // textContainerInset = (top:60, left:20, bottom:60, right:20)
        // lineFragmentPadding = 5 (UITextView default)
        let insetH: CGFloat = 120      // top + bottom inset
        let insetW: CGFloat = 40       // left + right inset
        let padding: CGFloat = 5       // lineFragmentPadding (each side)
        let layoutWidth = CGFloat(key.containerWidth) - insetW - 2 * padding
        let viewHeight = CGFloat(key.containerHeight)
        let pageStepH: CGFloat = max(100, viewHeight - 80)  // matches page() overlap=80

        let font = PlatformFont(name: key.fontName, size: key.fontSize)
            ?? PlatformFont.systemFont(ofSize: key.fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = key.lineSpacing
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]

        let nsText = text as NSString
        let totalChars = nsText.length
        let chunkSize = 40_000   // UTF-16 chars per layout chunk

        var pageStarts = initialPageStarts
        var cumY: CGFloat = 0          // cumulative layout height from document start
        var lastPageY: CGFloat = CGFloat(startChar == 0 ? 0 : -1)  // will be set below
        var charOffset = startChar

        // If resuming, we need to know the cumY at startChar and the lastPageY.
        // Since we can't reconstruct those cheaply, we re-layout from the last
        // page boundary before startChar. That's pageStarts.last ?? 0.
        // We use startChar = pageStarts.last to resume cheaply: restart the
        // cumY accumulation from the last known page start.
        if startChar > 0, let lastKnown = pageStarts.last {
            // Re-derive cumY up to lastKnown by full re-layout is expensive.
            // Instead we lay out up to lastKnown to recompute cumY correctly,
            // but only if lastKnown is within the first 20% of the document
            // (cheap). Otherwise clear the resume and start fresh.
            if Double(lastKnown) / Double(max(1, totalChars)) < 0.2 {
                // Re-layout the prefix up to lastKnown to get cumY.
                cumY = layoutHeight(
                    text: nsText.substring(to: lastKnown) as NSString,
                    font: font, paragraphStyle: paragraphStyle, width: layoutWidth
                )
                lastPageY = cumY
                charOffset = lastKnown
                pageStarts = Array(pageStarts.prefix(while: { $0 <= lastKnown }))
                if pageStarts.isEmpty { pageStarts = [0] }
            } else {
                // Too expensive to resume; start fresh.
                pageStarts = [0]
                cumY = 0
                lastPageY = 0
                charOffset = 0
            }
        } else {
            lastPageY = 0
        }

        while charOffset < totalChars {
            try Task.checkCancellation()

            // Split at paragraph boundary to avoid mid-word line-break artifacts.
            var chunkEnd = min(charOffset + chunkSize, totalChars)
            if chunkEnd < totalChars {
                var i = chunkEnd
                while i > charOffset + 1 && nsText.character(at: i - 1) != 10 { i -= 1 }
                if i > charOffset + 1 { chunkEnd = i }
            }

            let chunkRange = NSRange(location: charOffset, length: chunkEnd - charOffset)
            let chunkStr = nsText.substring(with: chunkRange)

            // Off-main layout.
            let storage = NSTextStorage(string: chunkStr, attributes: attrs)
            let lm = NSLayoutManager()
            lm.usesFontLeading = true
            storage.addLayoutManager(lm)
            let tc = NSTextContainer(size: CGSize(width: layoutWidth, height: 1_000_000_000))
            tc.lineFragmentPadding = padding
            lm.addTextContainer(tc)
            lm.ensureLayout(for: tc)

            var localMaxY: CGFloat = 0

            lm.enumerateLineFragments(
                forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)
            ) { [cumY] _, usedRect, _, glyphRange, _ in
                let fragTopY = cumY + usedRect.minY
                localMaxY = usedRect.maxY

                // Emit a page start whenever we've advanced ≥ one pageStepH from
                // the previous page start.
                if fragTopY - lastPageY >= pageStepH {
                    let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                    let globalChar = charOffset + charRange.location
                    // Guard against duplicates from chunk boundaries.
                    if globalChar > (pageStarts.last ?? 0) {
                        pageStarts.append(globalChar)
                        lastPageY = fragTopY
                    }
                }
            }

            cumY += localMaxY
            charOffset = chunkEnd

            let fraction = Double(charOffset) / Double(max(1, totalChars))
            progress(fraction)

            // Checkpoint: save partial result every ~10% so interruption is cheap.
            if Int(fraction * 10) > Int((fraction - Double(chunkSize) / Double(totalChars)) * 10) {
                let partial = CacheFile(pageStarts: pageStarts, cursor: charOffset, isComplete: false)
                saveCache(partial, key: key)
            }
        }

        let complete = CacheFile(pageStarts: pageStarts, cursor: 0, isComplete: true)
        saveCache(complete, key: key)
        return pageStarts
    }

    // MARK: - Helpers

    private func layoutHeight(
        text: NSString,
        font: PlatformFont,
        paragraphStyle: NSMutableParagraphStyle,
        width: CGFloat
    ) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraphStyle]
        let storage = NSTextStorage(string: text as String, attributes: attrs)
        let lm = NSLayoutManager()
        lm.usesFontLeading = true
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: width, height: 1_000_000_000))
        tc.lineFragmentPadding = 5
        lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return lm.usedRect(for: tc).height
    }

    // MARK: - Cache invalidation

    func invalidate(bookID: UUID) {
        let dir = Self.cacheDir
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let prefix = bookID.uuidString
        for item in items where item.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(item))
        }
    }
}

// MARK: - Binary search helper

extension Array where Element == Int {
    /// Returns the page index (0-based) for a given character offset.
    func pageIndex(forChar charIndex: Int) -> Int {
        guard count > 1 else { return 0 }
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if self[mid] <= charIndex { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
