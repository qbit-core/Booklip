import SwiftUI
import Combine
import os.signpost

// spLog is an alias for the module-wide booklipSpLog (BooklipSignposts.swift).
// All files share one OSLog so Instruments shows a single merged lane.
private var spLog: OSLog { booklipSpLog }


// MARK: - Search actor
// Runs iOSAllMatches off the main thread; each new query cancels the previous Task.
private actor SearchActor {
    func allMatches(of query: String, in string: String) -> [NSRange] {
        var matches: [NSRange] = []
        let ns = string as NSString
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            guard !Task.isCancelled else { return [] }
            let found = ns.range(of: query, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound else { break }
            matches.append(found)
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return matches
    }
}
private let sharedSearchActor = SearchActor()

struct TextReaderView: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var settings: ReadingSettings
    @Binding var showBars: Bool
    @ObservedObject var tts: TTSManager
    @Binding var pageNavigationDirection: Int
    var searchQuery: String = ""
    var searchResultIndex: Int = 0
    @Binding var selectedRange: NSRange?
    @State private var autoScrolling = false
    @State private var highlightMode = false
#if os(macOS)
    @StateObject private var eventChannel = TextViewEventChannel()
#endif

    private var richBlocks: [ContentBlock] {
        vm.book.format == .epub ? vm.blocks : []
    }

    var body: some View {
#if os(macOS)
        nativeTextView(progress: vm.progress)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(eventChannel.$scrollProgress.dropFirst()) { vm.progress = $0 }
            .onReceive(eventChannel.$tapCount.dropFirst()) { _ in showBars.toggle() }
#else
        nativeTextView(progress: $vm.progress)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
    }

#if os(macOS)
    private func nativeTextView(progress: Double) -> NativeTextView {
        NativeTextView(
            text: vm.book.format == .markdown ? nil : vm.plainText,
            attributedText: vm.book.format == .markdown ? vm.attributedText : nil,
            blocks: richBlocks,
            settings: settings,
            pageEffect: settings.pageEffect,
            embeddedFontName: settings.useEmbeddedFont ? vm.embeddedFontName : nil,
            autoScrolling: autoScrolling,
            autoScrollSpeed: settings.autoScrollSpeed,
            highlightMode: highlightMode,
            highlights: vm.highlights,
            onAddHighlight: { range, color, snippet, p in
                vm.addHighlight(range: range, colorName: color, snippet: snippet, progress: p)
            },
            progress: progress,
            spokenRange: tts.spokenRange,
            searchQuery: searchQuery,
            searchResultIndex: searchResultIndex,
            eventChannel: eventChannel
        )
    }
#else
    private func nativeTextView(progress: Binding<Double>) -> NativeTextView {
        NativeTextView(
            text: vm.book.format == .markdown ? nil : vm.plainText,
            attributedText: vm.book.format == .markdown ? vm.attributedText : nil,
            blocks: richBlocks,
            settings: settings,
            pageEffect: settings.pageEffect,
            embeddedFontName: settings.useEmbeddedFont ? vm.embeddedFontName : nil,
            stableCharCount: (vm.plainText as NSString).length,
            chapters: vm.chapters,
            autoScrolling: $autoScrolling,
            autoScrollSpeed: settings.autoScrollSpeed,
            highlightMode: highlightMode,
            highlights: vm.highlights,
            onAddHighlight: { range, color, snippet, p in
                vm.addHighlight(range: range, colorName: color, snippet: snippet, progress: p)
            },
            progress: progress,
            spokenRange: tts.spokenRange,
            pageNavigationDirection: $pageNavigationDirection,
            searchQuery: searchQuery,
            searchResultIndex: searchResultIndex,
            onTap: { showBars.toggle() }
        )
    }
#endif
}

#if os(macOS)
final class TextViewEventChannel: ObservableObject {
    @Published var scrollProgress: Double = 0
    @Published var tapCount: Int = 0
}
#endif

// MARK: - macOS

#if os(macOS)
import AppKit

struct NativeTextView: NSViewRepresentable {
    let text: String?
    let attributedText: AttributedString?
    var blocks: [ContentBlock] = []
    let settings: ReadingSettings
    var pageEffect: PageEffect = .verticalSlide
    var embeddedFontName: String?
    // Plain value — macOS has no auto-scroll; keeping this as @Binding would leave
    // a dangling binding reference if SwiftUI frees @State backing stores before
    // releasing its internal copy of this struct.
    var autoScrolling: Bool = false
    var autoScrollSpeed: Double = 40
    var highlightMode: Bool = false
    var highlights: [Highlight] = []
    var onAddHighlight: (NSRange, String, String, Double) -> Void = { _, _, _, _ in }
    var progress: Double
    var spokenRange: NSRange?
    var searchQuery: String = ""
    var searchResultIndex: Int = 0
    // Coordinator communicates scroll position and taps back to SwiftUI via this
    // channel. Using a weak reference in the coordinator means the coordinator can
    // never crash accessing freed SwiftUI backing stores, regardless of teardown order.
    var eventChannel: TextViewEventChannel? = nil

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.eventChannel = eventChannel
        return c
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 60)
        textView.autoresizingMask = [.width]
        let recognizer = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        recognizer.numberOfClicksRequired = 1
        textView.addGestureRecognizer(recognizer)
        context.coordinator.scrollView = scrollView
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.didLiveScroll),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        context.coordinator.installKeyMonitor()
        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.isDismantled = true
        coordinator.removeKeyMonitor()
        NotificationCenter.default.removeObserver(coordinator)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView

        let macFontName = embeddedFontName ?? settings.fontName
        let macLayoutKey = "\(macFontName)|\(settings.fontSize)|\(settings.lineSpacing)"
        let macColorKey = "\(settings.presetId)|hl\(highlights.count)"
        let contentKey: String = {
            if !blocks.isEmpty {
                let bucket = (Int(textView.bounds.width) / 50) * 50
                return "blocks-\(blocks.count)-w\(bucket)"
            }
            return text.map { "txt-\($0.count)" }
                ?? "attr-\(attributedText.map { NSAttributedString($0).length } ?? 0)"
        }()

        let macLayoutChanged = context.coordinator.lastLayoutKey != macLayoutKey
            || context.coordinator.lastContentKey != contentKey
        let macColorChanged = context.coordinator.lastColorKey != macColorKey

        if macLayoutChanged {
            autoreleasepool { applyContent(to: textView) }
            context.coordinator.lastLayoutKey = macLayoutKey
            context.coordinator.lastColorKey = macColorKey
            context.coordinator.lastContentKey = contentKey
        } else if macColorChanged {
            applyColorOnly(to: textView)
            context.coordinator.lastColorKey = macColorKey
        }

        if macLayoutChanged, let sv = context.coordinator.scrollView {
            context.coordinator.scheduleProgressRestore(progress, in: sv)
        } else {
            context.coordinator.scrollToProgress(progress)
        }

        // Search: find all matches, highlight active one, scroll to it.
        let queryChanged = context.coordinator.lastSearchQuery != searchQuery
        let indexChanged = context.coordinator.lastSearchResultIndex != searchResultIndex
        if queryChanged {
            context.coordinator.lastSearchQuery = searchQuery
            context.coordinator.lastSearchResultIndex = searchResultIndex
            if !searchQuery.isEmpty, let storage = textView.textStorage, storage.length > 0 {
                context.coordinator.searchMatches = allMatches(of: searchQuery, in: storage.string)
            } else {
                context.coordinator.searchMatches = []
            }
        } else if indexChanged {
            context.coordinator.lastSearchResultIndex = searchResultIndex
        }
        if queryChanged || indexChanged {
            applySearchHighlight(to: textView,
                                 matches: context.coordinator.searchMatches,
                                 index: searchResultIndex)
        }

        let highlight = NSColor(settings.currentPreset.text).withAlphaComponent(0.18)
        context.coordinator.updateHighlight(spokenRange, in: textView, color: highlight)
    }

    private func allMatches(of query: String, in string: String) -> [NSRange] {
        var matches: [NSRange] = []
        let ns = string as NSString
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            let found = ns.range(of: query, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound else { break }
            matches.append(found)
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return matches
    }

    private func applySearchHighlight(to textView: NSTextView, matches: [NSRange], index: Int) {
        guard let storage = textView.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        guard !matches.isEmpty else { return }
        let active = matches[index % matches.count]
        // Dim all matches, brighten the active one.
        for m in matches {
            storage.addAttribute(.backgroundColor,
                                 value: NSColor.systemYellow.withAlphaComponent(0.3), range: m)
        }
        storage.addAttribute(.backgroundColor,
                             value: NSColor.systemYellow.withAlphaComponent(0.75), range: active)
        textView.scrollRangeToVisible(active)
    }

    // Apply only color/theme changes without touching text content or glyph layout.
    // Called when presetId or highlights change but font/size/lineSpacing are unchanged,
    // so there is no need to reset attributedText or run a position restore.
    private func applyColorOnly(to textView: NSTextView) {
        let color = NSColor(settings.currentPreset.text)
        textView.textColor = color
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(.foregroundColor, value: color,
                                 range: NSRange(location: 0, length: storage.length))
            for h in highlights where NSMaxRange(h.range) <= storage.length {
                storage.addAttribute(.backgroundColor,
                                     value: NSColor(HighlightColor(rawValue: h.colorName)?.color ?? .yellow).withAlphaComponent(0.4),
                                     range: h.range)
            }
        }
        textView.backgroundColor = NSColor(settings.currentPreset.background)
    }

    private func applyContent(to textView: NSTextView) {
        let fontName = embeddedFontName ?? settings.fontName
        let font = NSFont(name: fontName, size: settings.fontSize)
            ?? NSFont.systemFont(ofSize: settings.fontSize)
        let color = NSColor(settings.currentPreset.text)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = settings.lineSpacing
        let styleAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle
        ]

        // EPUB with images: build a rich NSAttributedString from blocks
        if !blocks.isEmpty {
            // Fall back to scroll view or screen width when the text view hasn't
            // been laid out yet (bounds are zero on the very first render call).
            let available: CGFloat = {
                let w = textView.bounds.width - 50
                if w > 50 { return w }
                if let sv = textView.enclosingScrollView, sv.bounds.width > 50 {
                    return sv.bounds.width - 50
                }
                // Window width is a reliable fallback when the text view hasn't
                // been laid out yet (e.g., first render). Screen width is wrong
                // here — it's too wide for a 700pt-wide window on a large display.
                if let win = textView.window, win.frame.width > 100 {
                    return win.frame.width - 100
                }
                return 600
            }()
            let result = NSMutableAttributedString()
            for block in blocks {
                switch block {
                case .text(let s):
                    result.append(NSAttributedString(string: s + "\n\n", attributes: styleAttrs))
                case .image(let data):
                    if let image = NSImage(data: data) {
                        let scale = min(1.0, available / max(image.size.width, 1))
                        let attachment = NSTextAttachment()
                        attachment.image = image
                        attachment.bounds = NSRect(x: 0, y: 0,
                                                   width:  image.size.width  * scale,
                                                   height: image.size.height * scale)
                        result.append(NSAttributedString(attachment: attachment))
                        result.append(NSAttributedString(string: "\n\n", attributes: styleAttrs))
                    }
                }
            }
            textView.textStorage?.setAttributedString(result)
            return
        }

        // Build the final attributed string with all styles and highlights embedded
        // before calling setAttributedString — addAttributes on an existing storage
        // forces a synchronous full-document layout pass on the main thread.
        if let attr = attributedText {
            let base = NSMutableAttributedString(attributedString: NSAttributedString(attr))
            base.addAttributes(styleAttrs, range: NSRange(location: 0, length: base.length))
            for h in highlights where NSMaxRange(h.range) <= base.length {
                base.addAttribute(NSAttributedString.Key.backgroundColor,
                                  value: NSColor(HighlightColor(rawValue: h.colorName)?.color ?? .yellow).withAlphaComponent(0.4),
                                  range: h.range)
            }
            textView.textStorage?.setAttributedString(base)
        } else if let str = text {
            let base = NSMutableAttributedString(string: str, attributes: styleAttrs)
            for h in highlights where NSMaxRange(h.range) <= base.length {
                base.addAttribute(.backgroundColor,
                                  value: NSColor(HighlightColor(rawValue: h.colorName)?.color ?? .yellow).withAlphaComponent(0.4),
                                  range: h.range)
            }
            textView.textStorage?.setAttributedString(base)
        }
        textView.backgroundColor = NSColor(settings.currentPreset.background)
    }

    class Coordinator: NSObject {
        // Weak references only — coordinator can outlive the SwiftUI view hierarchy
        // (AppKit retains it via the gesture recognizer on NSTextView). Using weak
        // references means all writes become no-ops after the view is dismantled,
        // regardless of teardown order. No closures, no @Binding captures.
        weak var eventChannel: TextViewEventChannel?
        weak var scrollView: NSScrollView?
        var isScrollingProgrammatically = false
        var isDismantled = false
        private var lastHighlight: NSRange?
        var lastLayoutKey = ""
        var lastColorKey = ""
        var lastContentKey = ""
        var lastSearchQuery = ""
        var lastSearchResultIndex = 0
        var searchMatches: [NSRange] = []
        private var keyMonitor: Any?

        func installKeyMonitor() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.specialKey == .rightArrow { self.navigatePage(direction: 1);  return nil }
                if event.specialKey == .leftArrow  { self.navigatePage(direction: -1); return nil }
                return event
            }
        }

        func removeKeyMonitor() {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }

        func navigatePage(direction: Int) {
            guard let sv = scrollView else { return }
            let pageHeight = sv.contentView.bounds.height
            let contentHeight = sv.documentView?.frame.height ?? 0
            let scrollable = contentHeight - pageHeight
            guard scrollable > 0 else { return }
            let current = sv.contentView.bounds.origin.y
            let target = max(0, min(current + CGFloat(direction) * pageHeight, scrollable))
            guard abs(target - current) > 1 else { return }
            isScrollingProgrammatically = true
            sv.contentView.scroll(to: NSPoint(x: 0, y: target))
            sv.reflectScrolledClipView(sv.contentView)
            isScrollingProgrammatically = false
            let capturedScrollable = scrollable
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDismantled else { return }
                self.eventChannel?.scrollProgress = target / capturedScrollable
            }
        }

        func updateHighlight(_ range: NSRange?, in textView: NSTextView, color: NSColor) {
            if let a = range, let b = lastHighlight, NSEqualRanges(a, b) { return }
            if range == nil && lastHighlight == nil { return }
            guard let storage = textView.textStorage, storage.length > 0 else { return }
            lastHighlight = range
            // Clear ALL background colors across the full document, then apply the
            // new sentence. Removing only lastHighlight leaves stale color when the
            // storage is rebuilt (e.g. window resize) between two highlight calls.
            storage.removeAttribute(.backgroundColor,
                                    range: NSRange(location: 0, length: storage.length))
            if let r = range, NSMaxRange(r) <= storage.length {
                storage.addAttribute(.backgroundColor, value: color, range: r)
                isScrollingProgrammatically = true
                textView.scrollRangeToVisible(r)
                isScrollingProgrammatically = false
            }
        }

        // Token used to cancel stale restore attempts when content reloads.
        private var restoreToken = 0
        private var isRestoring = false

        func scheduleProgressRestore(_ target: Double, in sv: NSScrollView) {
            restoreToken &+= 1
            isRestoring = true
            let token = restoreToken
            DispatchQueue.main.async { [weak self, weak sv] in
                guard let self, let sv, self.restoreToken == token else { return }
                self.performRestore(target, in: sv, token: token, retries: 20)
            }
        }

        private func performRestore(_ target: Double, in sv: NSScrollView, token: Int, retries: Int) {
            guard restoreToken == token else { isRestoring = false; return }
            guard let textView = sv.documentView as? NSTextView,
                  textView.textStorage?.length ?? 0 > 0,
                  sv.contentView.bounds.height > 0 else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak sv] in
                        guard let self, let sv else { return }
                        self.performRestore(target, in: sv, token: token, retries: retries - 1)
                    }
                } else { isRestoring = false }
                return
            }
            // Proportional scroll — avoids ensureLayout(forCharacterRange:) which
            // synchronously lays out the full document up to the target character,
            // freezing the UI for seconds when deep into a large book.
            let contentHeight = textView.frame.height
            let visibleHeight = sv.contentView.bounds.height
            let maxY = max(0, contentHeight - visibleHeight)
            let scrollY = min(contentHeight * target, maxY)
            isScrollingProgrammatically = true
            sv.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
            sv.reflectScrolledClipView(sv.contentView)
            isScrollingProgrammatically = false

            // If offset didn't stick (layout not ready yet), retry.
            if target > 0.001, sv.contentView.bounds.origin.y < 1, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak sv] in
                    guard let self, let sv else { return }
                    self.performRestore(target, in: sv, token: token, retries: retries - 1)
                }
                return
            }
            isRestoring = false
        }

        func scrollToProgress(_ target: Double) {
            guard let sv = scrollView else { return }
            // If a content-change restore is in flight, don't fight it.
            guard !isRestoring else { return }

            let contentHeight = sv.documentView?.frame.height ?? 0
            let visibleHeight = sv.contentView.bounds.height
            let s = contentHeight - visibleHeight
            guard s > 0 else { return }

            let targetOffset = target * s
            let currentOffset = sv.contentView.bounds.origin.y
            guard abs(targetOffset - currentOffset) > 1 else { return }

            isScrollingProgrammatically = true
            autoreleasepool {
                sv.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
                sv.reflectScrolledClipView(sv.contentView)
            }
            isScrollingProgrammatically = false
        }

        @objc func didLiveScroll(_ notification: Notification) {
            guard !isDismantled, let sv = scrollView else { return }
            let contentHeight = sv.documentView?.frame.height ?? 0
            let visibleHeight = sv.contentView.bounds.height
            let scrollable = contentHeight - visibleHeight
            guard scrollable > 0 else { return }
            let offset = sv.contentView.bounds.origin.y
            eventChannel?.scrollProgress = max(0, min(offset / scrollable, 1))
        }

        @objc func handleTap(_ recognizer: NSGestureRecognizer) { eventChannel?.tapCount += 1 }
    }
}

// MARK: - iOS

#else
import UIKit
import ImageIO

// Subclass so we can hook into layout after UITextView has fully settled.
// UITextView updates its internal _UITextContainerView (which drives contentSize)
// as part of super.layoutSubviews(), but UIScrollView may only commit the new
// contentSize on a subsequent run-loop pass.  Calling onDidLayout asynchronously
// ensures we observe the final, stable contentSize rather than an intermediate
// value of 0 that appears immediately after super returns.
private final class ReaderTextView: UITextView {
    var onDidLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        // One async tick: UIScrollView commits contentSize after this frame.
        DispatchQueue.main.async { [weak self] in self?.onDidLayout?() }
    }
}

struct NativeTextView: UIViewRepresentable {
    let text: String?
    let attributedText: AttributedString?
    var blocks: [ContentBlock] = []
    let settings: ReadingSettings
    var pageEffect: PageEffect = .verticalSlide
    var embeddedFontName: String?
    // UTF-16 length of the full plain-text string, fixed after background parse.
    // Passed down so the coordinator can use a denominator that never changes.
    var stableCharCount: Int = 0
    var chapters: [Chapter] = []
    @Binding var autoScrolling: Bool
    var autoScrollSpeed: Double = 40
    var highlightMode: Bool = false
    var highlights: [Highlight] = []
    var onAddHighlight: (NSRange, String, String, Double) -> Void = { _, _, _, _ in }
    @Binding var progress: Double
    var spokenRange: NSRange?
    var pageNavigationDirection: Binding<Int>? = nil
    var searchQuery: String = ""
    var searchResultIndex: Int = 0
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, autoScrolling: $autoScrolling, onTap: onTap)
    }

    func makeUIView(context: Context) -> UITextView {
        // Force TextKit 1 (accessing layoutManager opts out of TextKit 2),
        // which scrolls very large documents more smoothly and avoids the
        // relayout jank seen when returning from the background.
        let textView = ReaderTextView(usingTextLayoutManager: false)
        // Non-contiguous layout lets TextKit 1 lay out only the region around
        // the current scroll position on demand.  Combined with the CoreText
        // pre-measured content height, setContentOffset can jump to any position
        // without forcing a full sequential layout pass — no freeze on large docs.
        textView.layoutManager.allowsNonContiguousLayout = true
        let coordinator = context.coordinator
        textView.onDidLayout = { [weak coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.didLayout(in: textView)
        }
        textView.isEditable = false
        textView.isSelectable = false      // reading view: no text selection (fixes tap-selects-text)
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 60, left: 20, bottom: 60, right: 20)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tap.delaysTouchesEnded = false
        textView.addGestureRecognizer(tap)

        // Horizontal swipes page the same way as the tap zones.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleSwipe(_:)))
            swipe.direction = direction
            swipe.delegate = context.coordinator
            textView.addGestureRecognizer(swipe)
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.pageEffect = pageEffect
        context.coordinator.autoScrollSpeed = autoScrollSpeed
        context.coordinator.setAutoScrolling(autoScrolling)
        context.coordinator.highlightMode = highlightMode
        context.coordinator.onAddHighlight = onAddHighlight
        context.coordinator.userHighlights = highlights

        // External page navigation (keyboard, hardware buttons).
        let navDir = pageNavigationDirection?.wrappedValue ?? 0
        if navDir != 0, let tv = context.coordinator.textView {
            context.coordinator.page(tv, forward: navDir > 0)
            let binding = pageNavigationDirection
            DispatchQueue.main.async { binding?.wrappedValue = 0 }
        }
        // In highlight mode allow text selection (so the user can pick a range);
        // otherwise selection stays off so taps drive paging.
        textView.isSelectable = highlightMode
        textView.isScrollEnabled = true
        // Paper mode: disable the scroll view's pan gesture so finger-dragging is
        // blocked, while isScrollEnabled stays true so UITextView lays out content.
        textView.panGestureRecognizer.isEnabled = pageEffect != .paper
        textView.alwaysBounceVertical = pageEffect != .paper

        // Two-tier change detection:
        // • layout changed (text, font, size, spacing) → applyContent + scheduleRestore
        //   applyContent now uses a single lazy attributedText= with style embedded,
        //   so no synchronous layout pass runs on the main thread.
        // • color/highlight only → applyColorOnly (attribute-only, no layout triggered)
        let fontName = embeddedFontName ?? settings.fontName
        let layoutKey = "\(fontName)|\(settings.fontSize)|\(settings.lineSpacing)"
        let colorKey = "\(settings.presetId)|hl\(highlights.count)"
        let contentKey: String = {
            if !blocks.isEmpty { return "blocks-\(blocks.count)" }
            return text.map { "txt-\($0.count)" }
                ?? "attr-\(attributedText.map { NSAttributedString($0).length } ?? 0)"
        }()

        let layoutChanged = context.coordinator.lastLayoutKey != layoutKey
            || context.coordinator.lastContentKey != contentKey
        let colorChanged = context.coordinator.lastColorKey != colorKey

        if layoutChanged {
            let _applyT0 = CFAbsoluteTimeGetCurrent()
            applyContent(to: textView, coordinator: context.coordinator)
            print(String(format: "[TIME] layoutChanged-applyContent %.0f ms  layout=%@ content=%@",
                         (CFAbsoluteTimeGetCurrent() - _applyT0) * 1000,
                         layoutKey as NSString, contentKey as NSString))
            textView.backgroundColor = UIColor(settings.currentPreset.background)
            context.coordinator.lastLayoutKey = layoutKey
            context.coordinator.lastColorKey = colorKey
            context.coordinator.lastContentKey = contentKey
            // EPUB: stableCharCount must match textStorage.length (which includes
            // U+FFFC attachment chars) so that charIdx computed in applySeek stays
            // within [0, textStorage.length).
            // For txt: textStorage is filled asynchronously in Task.detached, so
            // textStorage.length is 0 here; we use stableCharCount (NSString length
            // of vm.plainText) which equals the eventual textStorage.length exactly.
            let actualLength = !blocks.isEmpty ? textView.textStorage.length : stableCharCount
            if actualLength > 0 {
                context.coordinator.stableCharCount = actualLength
                context.coordinator.cumulativeChapterOffsets = chapters.map {
                    Int($0.progress * Double(actualLength))
                }
            }
            context.coordinator.scheduleRestore(progress, in: textView, afterLayoutChange: true)
        } else if colorChanged {
            applyColorOnly(to: textView)
            textView.backgroundColor = UIColor(settings.currentPreset.background)
            context.coordinator.lastColorKey = colorKey
            context.coordinator.syncProgress(progress, in: textView)
        } else {
            context.coordinator.syncProgress(progress, in: textView)
        }

        // TTS highlight + auto-scroll.
        // When spokenRange becomes nil (TTS stopped), reset lastReportedProgress so
        // syncProgress doesn't re-apply the TTS position on the next update.
        let highlight = UIColor(settings.currentPreset.text).withAlphaComponent(0.18)
        if spokenRange == nil, context.coordinator.lastHighlightWasSpoken {
            context.coordinator.lastReportedProgressPublic = nil
        }
        context.coordinator.lastHighlightWasSpoken = spokenRange != nil
        context.coordinator.updateHighlight(spokenRange, in: textView, color: highlight)

        // Search: find all matches on a background actor, highlight active match.
        let searchQueryChanged = context.coordinator.lastSearchQuery != searchQuery
        let searchIndexChanged = context.coordinator.lastSearchResultIndex != searchResultIndex
        if searchQueryChanged {
            context.coordinator.lastSearchQuery = searchQuery
            context.coordinator.lastSearchResultIndex = searchResultIndex
            context.coordinator.currentSearchTask?.cancel()
            if !searchQuery.isEmpty {
                let query = searchQuery
                let str = textView.textStorage.string
                let coord = context.coordinator
                let idx = searchResultIndex
                let view = self
                coord.currentSearchTask = Task { @MainActor in
                    let _searchT0 = CFAbsoluteTimeGetCurrent()
                    let matches = await sharedSearchActor.allMatches(of: query, in: str)
                    print(String(format: "[TIME] iOSAllMatches %.0f ms  matches=%d query=%d",
                                 (CFAbsoluteTimeGetCurrent() - _searchT0) * 1000, matches.count, query.count))
                    guard !Task.isCancelled else { return }
                    coord.searchMatches = matches
                    guard let tv = coord.textView else { return }
                    view.iOSApplySearchHighlight(to: tv, matches: matches,
                                                 index: idx, coordinator: coord)
                }
            } else {
                context.coordinator.searchMatches = []
                iOSApplySearchHighlight(to: textView, matches: [],
                                        index: searchResultIndex,
                                        coordinator: context.coordinator)
            }
        } else if searchIndexChanged {
            context.coordinator.lastSearchResultIndex = searchResultIndex
            iOSApplySearchHighlight(to: textView,
                                    matches: context.coordinator.searchMatches,
                                    index: searchResultIndex,
                                    coordinator: context.coordinator)
        }
    }

    private func iOSApplySearchHighlight(to textView: UITextView,
                                         matches: [NSRange],
                                         index: Int,
                                         coordinator: Coordinator) {
        let storage = textView.textStorage
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        guard !matches.isEmpty else { return }
        let active = matches[index % matches.count]
        for m in matches {
            storage.addAttribute(.backgroundColor,
                                 value: UIColor.systemYellow.withAlphaComponent(0.3), range: m)
        }
        storage.addAttribute(.backgroundColor,
                             value: UIColor.systemYellow.withAlphaComponent(0.75), range: active)
        coordinator.isScrollingProgrammatically = true
        textView.scrollRangeToVisible(active)
        coordinator.isScrollingProgrammatically = false
    }

    // Apply only color/theme changes without touching text content or glyph layout.
    // Called when presetId or highlights change but font/size/lineSpacing are unchanged,
    // so there is no need to reset attributedText or run a position restore.
    private func applyColorOnly(to textView: UITextView) {
        let color = UIColor(settings.currentPreset.text)
        textView.textColor = color
        if textView.textStorage.length > 0, !blocks.isEmpty || attributedText != nil {
            textView.textStorage.addAttribute(.foregroundColor, value: color,
                                             range: NSRange(location: 0, length: textView.textStorage.length))
        }
        applyHighlights(to: textView)
    }

    private func applyContent(to textView: UITextView, coordinator: Coordinator? = nil) {
        let fontName = embeddedFontName ?? settings.fontName
        let font = UIFont(name: fontName, size: settings.fontSize)
            ?? UIFont.systemFont(ofSize: settings.fontSize)
        let color = UIColor(settings.currentPreset.text)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = settings.lineSpacing

        // EPUB with images: build a rich NSAttributedString from blocks.
        // Phase 1 (main thread, synchronous): text blocks + correctly-sized placeholder
        //   attachments (header-only size read — no pixel decoding) so the textView
        //   gets accurate contentSize for position restore immediately.
        // Phase 2 (background): decode each image, swap only its attachment character
        //   in-place via replaceCharacters — no contentOffset reset, no blank flash.
        if !blocks.isEmpty {
            let insets = textView.textContainerInset.left + textView.textContainerInset.right + 10
            let laidOutWidth = textView.bounds.width - insets
            let available = laidOutWidth > 50 ? laidOutWidth
                : (UIScreen.main.bounds.width - 40)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle
            ]

            var pending: [(offset: Int, data: Data)] = []
            let result = NSMutableAttributedString()

            for block in blocks {
                switch block {
                case .text(let s):
                    result.append(NSAttributedString(string: s + "\n\n", attributes: attrs))
                case .image(let data):
                    let attachment = NSTextAttachment()
                    if let sz = Self.quickImageSize(data) {
                        let scale = min(1, available / max(sz.width, 1))
                        attachment.bounds = CGRect(x: 0, y: 0,
                                                   width: sz.width * scale,
                                                   height: sz.height * scale)
                    } else {
                        attachment.bounds = CGRect(x: 0, y: 0, width: available, height: available * 0.75)
                    }
                    pending.append((offset: result.length, data: data))
                    result.append(NSAttributedString(attachment: attachment))
                    result.append(NSAttributedString(string: "\n\n", attributes: attrs))
                }
            }

            let spID = OSSignpostID(log: spLog)
            os_signpost(.begin, log: spLog, name: "Phase1-attributedText", signpostID: spID,
                        "blocks=%d images=%d", blocks.count, pending.count)
            let _p1Start = CFAbsoluteTimeGetCurrent()
            // Open-FirstLayout: setAttributedString → didLayout (end fires in Coordinator.didLayout).
            let flID = OSSignpostID(log: spLog)
            OpenSignpostState.shared.firstLayoutID = flID
            OpenSignpostState.shared.firstLayoutT0 = CFAbsoluteTimeGetCurrent()
            os_signpost(.begin, log: spLog, name: "Open-FirstLayout", signpostID: flID,
                        "chars=%d attachments=%d", result.length, pending.count)
            textView.textStorage.beginEditing()
            textView.textStorage.setAttributedString(result)
            textView.textStorage.endEditing()
            os_signpost(.end, log: spLog, name: "Phase1-attributedText", signpostID: spID)
            print(String(format: "[TIME] Phase1-attributedText %.0f ms  chars=%d images=%d",
                         (CFAbsoluteTimeGetCurrent() - _p1Start) * 1000, result.length, pending.count))
            // Probe (1): after setAttributedString.
            let lm1 = textView.layoutManager
            os_log("[NCL-1] after-setAttrStr(EPUB-P1) allow=%d has=%d vo=%d chars=%d attachments=%d",
                   log: spLog, type: .info,
                   lm1.allowsNonContiguousLayout ? 1 : 0,
                   lm1.hasNonContiguousLayout ? 1 : 0,
                   UIAccessibility.isVoiceOverRunning ? 1 : 0,
                   textView.textStorage.length,
                   pending.count)
            applyHighlights(to: textView)

            guard !pending.isEmpty else { return }
            let capturedAvailable = available
            // Capture screen scale on main thread — UIScreen.main is UIKit and not
            // safe to access from a background thread.
            let capturedScreenScale = UIScreen.main.scale
            // Phase 2: downsample each image to display size on a background thread,
            // then swap only the .attachment attribute on the existing U+FFFC character.
            // downsample() uses CGImageSourceCreateThumbnailAtIndex with
            // kCGImageSourceShouldCacheImmediately:true so pixels are decompressed here
            // (background thread) rather than at first CA render (main thread).
            // The compressed Data is not retained in the attachment — only the
            // downsampled UIImage is held, giving ~6× memory saving per image.
            DispatchQueue.global(qos: .userInitiated).async { [weak textView] in
                var replacements: [(offset: Int, attachment: NSTextAttachment)] = []
                for (offset, data) in pending {
                    let att = NSTextAttachment()
                    // maxPixelSize = container width in points × screen scale.
                    // For a 400pt container on a 3× device: 1200 px cap.
                    // CGImageSource caps the longest edge, preserving aspect ratio.
                    let maxPx = capturedAvailable * capturedScreenScale
                    if let image = NativeTextView.downsample(data: data,
                                                              maxPixelSize: maxPx,
                                                              screenScale: capturedScreenScale) {
                        att.image = image
                        // image.size is already in points (scale applied above).
                        // Clamp width to available so portrait-crops don't overflow.
                        let scale = min(1.0, capturedAvailable / max(image.size.width, 1))
                        att.bounds = CGRect(x: 0, y: 0,
                                            width: image.size.width * scale,
                                            height: image.size.height * scale)
                    } else {
                        // downsample failed (corrupt/unsupported image): use placeholder size.
                        att.bounds = CGRect(x: 0, y: 0,
                                            width: capturedAvailable,
                                            height: capturedAvailable * 0.75)
                    }
                    replacements.append((offset: offset, attachment: att))
                }
                DispatchQueue.main.async { [weak textView] in
                    guard let tv = textView else {
                        os_log("[EPUB P2] textView nil — dismissed before decode finished",
                               log: spLog, type: .info)
                        return
                    }
                    let spID2 = OSSignpostID(log: spLog)
                    os_signpost(.begin, log: spLog, name: "Phase2-addAttachment", signpostID: spID2,
                                "images=%d", replacements.count)
                    let storage = tv.textStorage
                    storage.beginEditing()
                    for (offset, att) in replacements {
                        guard offset < storage.length else { continue }
                        storage.addAttribute(.attachment, value: att,
                                             range: NSRange(location: offset, length: 1))
                    }
                    storage.endEditing()
                    // addAttribute triggers NSTextStorageEditedAttributes → NSLayoutManager
                    // invalidateDisplay (redraw), but NOT invalidateGlyphs (glyph cache).
                    // For NSTextAttachment characters (U+FFFC), the glyph cache may hold a
                    // reference to the old attachment instance from Phase 1 generation.
                    // Explicitly invalidate glyphs for the union of all attachment ranges so
                    // NSLayoutManager regenerates them and picks up the new attachment objects.
                    if !replacements.isEmpty {
                        let lm = tv.layoutManager
                        var unionLoc = replacements[0].offset
                        var unionMax = unionLoc + 1
                        for (offset, _) in replacements.dropFirst() {
                            unionLoc = min(unionLoc, offset)
                            unionMax = max(unionMax, offset + 1)
                        }
                        let unionRange = NSRange(location: unionLoc, length: unionMax - unionLoc)
                        if NSMaxRange(unionRange) <= storage.length {
                            var actual = NSRange()
                            lm.invalidateGlyphs(forCharacterRange: unionRange,
                                                changeInLength: 0,
                                                actualCharacterRange: &actual)
                        }
                    }
                    os_signpost(.end, log: spLog, name: "Phase2-addAttachment", signpostID: spID2)
                    os_log("[EPUB P2] attachment-attr swap + glyphInvalidate done, images=%d window=%d",
                           log: spLog, type: .info, replacements.count, tv.window != nil ? 1 : 0)
                }
            }
            return
        }

        if let attr = attributedText {
            let spID = OSSignpostID(log: spLog)
            os_signpost(.begin, log: spLog, name: "AttributedText-set", signpostID: spID)
            textView.textStorage.beginEditing()
            textView.textStorage.setAttributedString(NSAttributedString(attr))
            textView.textStorage.endEditing()
            os_signpost(.end, log: spLog, name: "AttributedText-set", signpostID: spID)
            let lm2 = textView.layoutManager
            os_log("[NCL-1] after-setAttrStr(attr) allow=%d has=%d vo=%d chars=%d attachments=0",
                   log: spLog, type: .info,
                   lm2.allowsNonContiguousLayout ? 1 : 0,
                   lm2.hasNonContiguousLayout ? 1 : 0,
                   UIAccessibility.isVoiceOverRunning ? 1 : 0,
                   textView.textStorage.length)
            textView.font = font
            textView.textColor = color
        } else if let str = text {
            // Build the NSAttributedString on a background thread (string copy + metadata),
            // then hand only the storage mutation to the main thread.
            // beginEditing/endEditing batches the single processEditing notification,
            // keeping the main-thread work to the minimum UIKit requires.
            let capturedFont = font
            let capturedColor = color
            let capturedLS = settings.lineSpacing
            let capturedPS = paragraphStyle
            let viewCapture = self   // NativeTextView is a value type — safe to copy
            let spID = OSSignpostID(log: spLog)
            os_signpost(.begin, log: spLog, name: "PlainText-build", signpostID: spID,
                        "chars=%d", (str as NSString).length)
            let _buildStart = CFAbsoluteTimeGetCurrent()
            // Open-FirstLayout: setAttributedString → didLayout (end fires in Coordinator.didLayout).
            let flID = OSSignpostID(log: spLog)
            OpenSignpostState.shared.firstLayoutID = flID
            OpenSignpostState.shared.firstLayoutT0 = CFAbsoluteTimeGetCurrent()
            os_signpost(.begin, log: spLog, name: "Open-FirstLayout", signpostID: flID,
                        "chars=%d attachments=0", (str as NSString).length)
            // NSAttributedString is not Sendable. We ferry it across the actor boundary
            // via an @unchecked Sendable box — written once on the detached task,
            // read once on MainActor; no concurrent access occurs.
            let tvRef = textView   // non-optional UITextView parameter capture
            // Cancel any in-flight build — rapid font changes launch many tasks;
            // only the last one should apply to textStorage.
            coordinator?.currentPlainTextBuildTask?.cancel()
            let task = Task.detached(priority: .userInitiated) {
                var attrs: [NSAttributedString.Key: Any] = [.font: capturedFont,
                                                             .foregroundColor: capturedColor]
                if capturedLS > 0 { attrs[.paragraphStyle] = capturedPS }
                let built = UncheckedSendableAttrStr(NSAttributedString(string: str, attributes: attrs))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    os_signpost(.end, log: spLog, name: "PlainText-build", signpostID: spID)
                    print(String(format: "[TIME] PlainText-build %.0f ms  utf16=%d",
                                 (CFAbsoluteTimeGetCurrent() - _buildStart) * 1000, built.value.length))
                    tvRef.textStorage.beginEditing()
                    tvRef.textStorage.setAttributedString(built.value)
                    tvRef.textStorage.endEditing()
                    // Probe (1): after setAttributedString — plain text path.
                    let lm = tvRef.layoutManager
                    os_log("[NCL-1] after-setAttrStr(plain) allow=%d has=%d vo=%d chars=%d attachments=0",
                           log: spLog, type: .info,
                           lm.allowsNonContiguousLayout ? 1 : 0,
                           lm.hasNonContiguousLayout ? 1 : 0,
                           UIAccessibility.isVoiceOverRunning ? 1 : 0,
                           tvRef.textStorage.length)
                    viewCapture.applyHighlights(to: tvRef)
                }
            }
            coordinator?.currentPlainTextBuildTask = task
            return   // applyHighlights called inside the Task
        }
        applyHighlights(to: textView)
    }

    private func applyHighlights(to textView: UITextView) {
        let storage = textView.textStorage
        guard storage.length > 0, !highlights.isEmpty else { return }
        storage.beginEditing()
        for h in highlights where NSMaxRange(h.range) <= storage.length {
            let color = UIColor(HighlightColor(rawValue: h.colorName)?.color ?? .yellow).withAlphaComponent(0.4)
            storage.addAttribute(.backgroundColor, value: color, range: h.range)
        }
        storage.endEditing()
    }

    // Read pixel dimensions from the image file header without decompressing
    // pixel data.  JPEG stores dimensions in the SOF segment; PNG in the IHDR.
    // CGImageSource reads only the metadata markers, not the bitmap, so this
    // runs in microseconds even for multi-megabyte images.
    private static func quickImageSize(_ data: Data) -> CGSize? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }

    // Downsample an image to at most maxPixelSize px on the longest edge,
    // decompressing pixels immediately on the calling (background) thread.
    //
    // Benefits over UIImage(data:):
    //  • Memory: a 2000×1500 JPEG stored at display size (e.g. 800×600) uses
    //    ~1.9 MB vs ~12 MB for full resolution — 6× reduction per image.
    //  • No CA hitch: kCGImageSourceShouldCacheImmediately forces pixel
    //    decompression now (BG thread) instead of at first render (main thread).
    //  • No Data retained: NSTextAttachment holds only the UIImage; the raw
    //    compressed Data bytes are released after this call returns.
    //
    // kCGImageSourceShouldCache: false on the source prevents CGImageSource from
    // keeping a decoded copy of the full-resolution image alongside the thumbnail.
    static func downsample(data: Data, maxPixelSize: CGFloat, screenScale: CGFloat) -> UIImage? {
        let sourceOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOpts) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,  // resize even without embedded thumb
            kCGImageSourceShouldCacheImmediately: true,           // decompress pixels now, on BG thread
            kCGImageSourceCreateThumbnailWithTransform: true,     // apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize     // longest-edge cap in pixels
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary)
        else { return nil }
        // Pass the screen scale so UIImage.size reports points (not pixels).
        // After downsampling, image.size.width ≈ maxPixelSize / screenScale = containerWidth points.
        return UIImage(cgImage: cgImage, scale: screenScale, orientation: .up)
    }

    class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        @Binding var progress: Double
        @Binding var autoScrolling: Bool
        let onTap: () -> Void
        weak var textView: UITextView?
        var isScrollingProgrammatically = false
        var lastLayoutKey = ""
        var lastColorKey = ""
        var lastContentKey = ""
        private var lastReportedProgress: Double?
        var lastReportedProgressPublic: Double? {
            get { lastReportedProgress }
            set { lastReportedProgress = newValue }
        }
        private var lastHighlight: NSRange?
        var lastHighlightWasSpoken = false
        var pageEffect: PageEffect = .verticalSlide

        // ── Page-turn char-index tracking ─────────────────────────────────────
        // Each page() call gets a unique pageIndex from a monotonic counter.
        // The index is captured by the CATransaction completion closure so it
        // can look up and remove exactly its own entry — not a stale one left
        // by a rapid successive page() that fired before the animation finished.
        private var pageCharMap: [Int: Int] = [:]   // pageIndex → charIndex
        private var pageCounter: Int = 0
        private var isSeeking = false

        // ── Stable progress denominator ────────────────────────────────────────
        // Set once when the book's text is loaded; never updated thereafter.
        // textStorage.length fluctuates during EPUB phase-2 attachment swaps;
        // this value is the UTF-16 length of the full plain-text string, which
        // is invariant across all UI phases.
        var stableCharCount: Int = 0
        // Cumulative char offsets at each chapter boundary, derived from
        // Chapter.progress × stableCharCount at load time.
        // chapterCharCounts[i] = cumulativeChapterOffsets[i+1] − cumulativeChapterOffsets[i]
        var cumulativeChapterOffsets: [Int] = []

        // Auto-scroll
        var autoScrollSpeed: Double = 40            // points per second
        private var displayLink: CADisplayLink?
        private var autoScrollAccumulator: CFTimeInterval = 0

        // Highlights
        var highlightMode = false
        var onAddHighlight: (NSRange, String, String, Double) -> Void = { _, _, _, _ in }
        var userHighlights: [Highlight] = []

        // Search
        var lastSearchQuery = ""
        var lastSearchResultIndex = 0
        var searchMatches: [NSRange] = []
        var currentSearchTask: Task<Void, Never>?
        var currentPlainTextBuildTask: Task<Void, Never>?

        // Content-size cache — persisted to UserDefaults so that the second open
        // of a book skips all retries and restores position immediately.
        // Key is set by updateUIView using contentKey + layoutKey + screen width.

        init(progress: Binding<Double>, autoScrolling: Binding<Bool>, onTap: @escaping () -> Void) {
            _progress = progress
            _autoScrolling = autoScrolling
            self.onTap = onTap
        }

        deinit { displayLink?.invalidate() }

        func setAutoScrolling(_ on: Bool) {
            if on, displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(autoScrollTick(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            } else if !on {
                displayLink?.invalidate()
                displayLink = nil
            }
        }

        @objc private func autoScrollTick(_ link: CADisplayLink) {
            guard let tv = textView else { return }
            let dy = CGFloat(autoScrollSpeed) * CGFloat(link.duration)
            let maxOffset = max(0, tv.contentSize.height - tv.bounds.height)
            let newY = min(tv.contentOffset.y + dy, maxOffset)
            isScrollingProgrammatically = true
            tv.contentOffset.y = newY
            isScrollingProgrammatically = false

            // Report progress a few times per second (without triggering a fight).
            autoScrollAccumulator += link.duration
            if autoScrollAccumulator > 0.4 {
                autoScrollAccumulator = 0
                if tv.textStorage.length > 0 {
                    let v = charProgress(tv)
                    lastReportedProgress = v
                    progress = v
                }
            }
            if newY >= maxOffset { autoScrolling = false }   // reached the end
        }

        func updateHighlight(_ range: NSRange?, in textView: UITextView, color: UIColor) {
            guard !sameRange(range, lastHighlight) else { return }
            let _hlT0 = CFAbsoluteTimeGetCurrent()
            let storage = textView.textStorage
            let prev = lastHighlight          // capture before overwriting
            lastHighlight = range
            guard storage.length > 0 else { return }

            // Clear TTS background ONLY from the previous sentence range — O(prev.length).
            // The original approach cleared the full document (O(N)) then re-applied all
            // user highlights.  Here we touch only the two affected ranges:
            //   1. Remove background from prev range.
            //   2. Restore any user-highlight that overlaps prev (typically 0–1 items).
            //   3. Apply TTS color to the new range.
            // NSLayoutManager.{add,remove}TemporaryAttribute are AppKit-only and not
            // available on UIKit's NSLayoutManager, so we stay with storage attributes
            // but confine edits to O(sentence length) instead of O(document length).
            if let p = prev, NSMaxRange(p) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: p)
                for h in userHighlights {
                    let overlap = NSIntersectionRange(h.range, p)
                    guard overlap.length > 0, NSMaxRange(overlap) <= storage.length else { continue }
                    let c = UIColor(HighlightColor(rawValue: h.colorName)?.color ?? .yellow)
                        .withAlphaComponent(0.4)
                    storage.addAttribute(.backgroundColor, value: c, range: overlap)
                }
            }

            if let r = range, NSMaxRange(r) <= storage.length {
                storage.addAttribute(.backgroundColor, value: color, range: r)
                scrollToSentence(r, in: textView)
                let v = min(max(Double(r.location) / Double(storage.length), 0), 1)
                lastReportedProgress = v
                DispatchQueue.main.async { [weak self] in self?.progress = v }
            }
            let _rangeStr = range.map { "loc=\($0.location) len=\($0.length)" } ?? "nil"
            print(String(format: "[TIME] updateHighlight %.0f ms  \(_rangeStr)",
                         (CFAbsoluteTimeGetCurrent() - _hlT0) * 1000))
        }

        // In vertical-slide mode: scroll so the highlighted sentence is visible.
        // Decomposed from scrollRangeToVisible into 3 explicit steps so we can
        // instrument the ensureLayout cost separately from the offset mutation.
        // In paper mode: flip only when the sentence is off-screen.
        private func scrollToSentence(_ r: NSRange, in textView: UITextView) {
            let lm = textView.layoutManager
            let tc = textView.textContainer

            // Step 1: map character range → glyph range.
            // glyphRange(forCharacterRange:) may call ensureGlyphs internally if
            // the range hasn't been laid out yet; we make that cost explicit below.
            let glyphRange = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)

            if pageEffect == .paper {
                guard pageTargetY == nil else { return }
                // Paper mode uses already-ensured glyphs from the current page — fast.
                let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                let sentenceTop = rect.minY + textView.textContainerInset.top
                let visibleTop = textView.contentOffset.y
                let visibleBottom = visibleTop + textView.bounds.height
                if sentenceTop >= visibleBottom {
                    page(textView, forward: true)
                } else if rect.maxY + textView.textContainerInset.top < visibleTop {
                    page(textView, forward: false)
                }
                return
            }

            // Vertical-slide: Step 2 — ensureLayout for the glyph range.
            // With allowsNonContiguousLayout=true this is O(local) when the sentence
            // is near the current scroll position; O(N) only if there is a gap between
            // the last laid-out region and this range.
            let spID = OSSignpostID(log: spLog)
            let _ensureT0 = CFAbsoluteTimeGetCurrent()
            os_signpost(.begin, log: spLog, name: "scrollToSentence-ensureLayout", signpostID: spID,
                        "glyphs=%d", glyphRange.length)
            lm.ensureLayout(forGlyphRange: glyphRange)
            os_signpost(.end, log: spLog, name: "scrollToSentence-ensureLayout", signpostID: spID)
            print(String(format: "[TIME] scrollToSentence-ensureLayout %.0f ms  glyphs=%d",
                         (CFAbsoluteTimeGetCurrent() - _ensureT0) * 1000, glyphRange.length))

            // Step 3: compute rect, check visibility, set offset.
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let inset = textView.textContainerInset.top
            let sentenceTop = rect.minY + inset
            let sentenceBot = rect.maxY + inset
            let visibleTop = textView.contentOffset.y
            let visibleBot = visibleTop + textView.bounds.height
            guard sentenceBot > visibleBot || sentenceTop < visibleTop else { return }
            let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
            let targetY = min(max(0, sentenceTop), maxOffset)
            isScrollingProgrammatically = true
            textView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            isScrollingProgrammatically = false
        }

        private func sameRange(_ a: NSRange?, _ b: NSRange?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return NSEqualRanges(x, y)
            default: return false
            }
        }

        // MARK: Character-based progress
        // Pixel offset / contentSize is unreliable because TextKit only
        // estimates total height until text is laid out, so the same spot can
        // report different progress. Character position is stable.

        private func charProgress(_ tv: UITextView) -> Double {
            let total = stableCharCount > 0 ? stableCharCount : tv.textStorage.length
            guard total > 0 else { return 0 }
            let p = CGPoint(x: 0, y: max(0, tv.contentOffset.y - tv.textContainerInset.top))
            let idx = tv.layoutManager.characterIndex(for: p, in: tv.textContainer,
                                                      fractionOfDistanceBetweenInsertionPoints: nil)
            return min(max(Double(idx) / Double(total), 0), 1)
        }

        // Scroll the text to match an externally-set progress value — initial
        // restore and seeking via the progress bar. Skips values we ourselves
        // reported so it never fights the user's scrolling.
        // Uses proportional pixel offset throughout — no TextKit layout forced.
        func syncProgress(_ target: Double, in textView: UITextView) {
            guard textView.bounds.width > 0, textView.textStorage.length > 0 else { return }
            if let lr = lastReportedProgress, abs(lr - target) < 0.0015 { return }
            if isRestorePending {
                pendingRestoreTarget = target
                return
            }

            // Record that bar is actively driving position — commitProgress checks
            // this to avoid overwriting vm.progress during an active drag.
            lastSyncDate = Date()
            latestSeekTarget = target

            let elapsed = Date().timeIntervalSince(lastSeekDate)
            seekWorkItem?.cancel()

            if elapsed >= seekInterval {
                lastSeekDate = Date()
                applySeek(target, in: textView)
            } else {
                let remaining = seekInterval - elapsed
                // Work item reads latestSeekTarget, not captured target, so it
                // always applies the most-recent bar position even if several
                // drag events fire before the work item executes.
                let work = DispatchWorkItem { [weak self, weak textView] in
                    guard let self, let tv = textView else { return }
                    self.lastSeekDate = Date()
                    self.applySeek(self.latestSeekTarget, in: tv)
                }
                seekWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
            }
        }

        private var lastAppliedSeekTarget: Double = -1

        private func applySeek(_ target: Double, in textView: UITextView) {
            // Skip if we already seeked to this exact target — prevents duplicate
            // NCL-3 entries when SwiftUI re-renders with the same progress value.
            guard target != lastAppliedSeekTarget else { return }
            lastAppliedSeekTarget = target

            // Always use TextKit's own contentSize as the coordinate space.
            // Using a CoreText-measured height (which may differ from TextKit's estimate)
            // causes blank screen: ensureLayout(forBoundingRect:) operates in TextKit's
            // coordinate space, so a rawY past TextKit's extent lays out no glyphs.
            //
            // WHY NOT glyphIndexForCharacter + ensureLayout(forGlyphRange:):
            //   glyphIndexForCharacter(at: N) must process chars 0..N sequentially to
            //   build the character→glyph map.  For N ≈ 3.4M this is O(N) — multi-second
            //   freeze regardless of NCL.
            //
            // ensureLayout(forBoundingRect:) is O(local) in NCL mode: TextKit uses its
            // per-paragraph height estimates to jump to the target strip and lay out only
            // that strip.  The target Y must be in TextKit's own coordinate space.
            let tkH = textView.contentSize.height
            guard tkH > textView.bounds.height else { return }
            let maxOffset = tkH - textView.bounds.height
            let rawY = tkH * target
            let lm = textView.layoutManager
            let tc = textView.textContainer
            let inset = textView.textContainerInset.top
            let viewH = max(textView.bounds.height, 100)
            let ensureRect = CGRect(x: 0,
                                    y: max(0, rawY - inset - viewH * 0.5),
                                    width: tc.size.width,
                                    height: viewH * 2)
            lm.ensureLayout(forBoundingRect: ensureRect, in: tc)
            let targetY = min(max(0, rawY), maxOffset)

            guard abs(textView.contentOffset.y - targetY) > 1 else { return }
            isSeeking = true
            isScrollingProgrammatically = true
            textView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            isScrollingProgrammatically = false
            // Probe (3): TOC jump / scrub seek complete.
            os_log("[NCL-3] applySeek-done allow=%d has=%d vo=%d target=%.3f offsetY=%.0f",
                   log: spLog, type: .info,
                   textView.layoutManager.allowsNonContiguousLayout ? 1 : 0,
                   textView.layoutManager.hasNonContiguousLayout ? 1 : 0,
                   UIAccessibility.isVoiceOverRunning ? 1 : 0,
                   target, targetY)
            // Defer isSeeking reset so commitProgress triggered by the offset change
            // (scrollViewDidEndScrollingAnimation or similar) does not overwrite progress.
            DispatchQueue.main.async { [weak self] in self?.isSeeking = false }
        }

        private var pendingRestoreTarget: Double?
        private var isRestorePending = false
        private var restoreRetries = 0

        // Throttle: at most one setContentOffset per seekInterval during bar drag.
        // With allowsNonContiguousLayout=true each seek is O(local), but throttling
        // still avoids redundant layout passes during fast finger movements.
        private var seekWorkItem: DispatchWorkItem?
        private var lastSeekDate = Date.distantPast
        private var latestSeekTarget: Double = 0   // always holds the most-recent target
        private var lastSyncDate = Date.distantPast // tracks when bar drag last fired
        private let seekInterval: TimeInterval = 0.08

        private func cancelRestore() {
            pendingRestoreTarget = nil
            isRestorePending = false
            restoreRetries = 0
        }

        func scheduleRestore(_ target: Double, in textView: UITextView, afterLayoutChange: Bool = false) {
            cancelRestore()
            pendingRestoreTarget = target
            isRestorePending = true
            lastReportedProgress = nil
            lastAppliedSeekTarget = -1   // reset so the restored position always fires
            // afterLayoutChange parameter kept for call-site clarity; applySeek now
            // uses proportional + ensureLayout(forBoundingRect:) for all seeks.
        }

        // Called one run-loop tick after ReaderTextView.layoutSubviews() — at this
        // point UIKit has set the final bounds, so we can measure and seek safely.
        func didLayout(in tv: UITextView) {
            guard let target = pendingRestoreTarget else { return }
            guard tv.bounds.width > 0, tv.textStorage.length > 0 else { return }

            // Use TextKit's own contentSize height as the seek coordinate space.
            // After the first layoutSubviews, TextKit has estimated the full document
            // height from the laid-out visible region; this is the correct coordinate
            // space for ensureLayout(forBoundingRect:) and setContentOffset.
            // Using a CoreText-measured height (which uses different metrics and may be
            // much larger) would place rawY past TextKit's glyph extent → blank screen.
            let tkH = tv.contentSize.height
            if tkH > tv.bounds.height {
                cancelRestore()
                let maxOffset = tkH - tv.bounds.height
                let clamped   = min(max(0, tkH * target), maxOffset)
                isScrollingProgrammatically = true
                tv.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
                isScrollingProgrammatically = false
                lastReportedProgress = target
                // Probe (2): didLayout restore complete.
                let lmD = tv.layoutManager
                os_log("[NCL-2] didLayout-done allow=%d has=%d vo=%d offsetY=%.0f",
                       log: spLog, type: .info,
                       lmD.allowsNonContiguousLayout ? 1 : 0,
                       lmD.hasNonContiguousLayout ? 1 : 0,
                       UIAccessibility.isVoiceOverRunning ? 1 : 0,
                       tv.contentOffset.y)
                // Close Open-FirstLayout and Open-EndToEnd — both paired from applyContent/performLoad.
                let flID = OpenSignpostState.shared.firstLayoutID
                os_signpost(.end, log: spLog, name: "Open-FirstLayout", signpostID: flID,
                            "offsetY=%.0f", tv.contentOffset.y)
                print(String(format: "[TIME] Open-FirstLayout %.0f ms  offsetY=%.0f",
                             (CFAbsoluteTimeGetCurrent() - OpenSignpostState.shared.firstLayoutT0) * 1000, tv.contentOffset.y))
                let e2eID = OpenSignpostState.shared.endToEndID
                os_signpost(.end, log: booklipSpLog, name: "Open-EndToEnd", signpostID: e2eID,
                            "offsetY=%.0f has=%d", tv.contentOffset.y,
                            lmD.hasNonContiguousLayout ? 1 : 0)
                print(String(format: "[TIME] Open-EndToEnd %.0f ms  offsetY=%.0f has=%d",
                             (CFAbsoluteTimeGetCurrent() - OpenSignpostState.shared.endToEndT0) * 1000, tv.contentOffset.y,
                             lmD.hasNonContiguousLayout ? 1 : 0))
                return
            }

            // Fallback: TextKit hasn't estimated height yet — retry.
            guard restoreRetries < 12 else { cancelRestore(); return }
            restoreRetries += 1
            let delay = 0.1 * Double(restoreRetries)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak tv] in
                guard let self, let tv, self.pendingRestoreTarget != nil else { return }
                self.didLayout(in: tv)
            }
        }

        // Update progress only when scrolling settles — writing the binding on
        // every frame re-renders the SwiftUI tree mid-scroll and causes jitter.
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            pageTargetY = nil      // user took over; forget any queued page target
            cancelRestore()   // and cancel any in-flight position restore
            if let tv = textView {
                os_log("[NCL] (b) first scroll — allowsNonContiguousLayout=%d hasNonContiguousLayout=%d",
                       log: spLog, type: .debug,
                       tv.layoutManager.allowsNonContiguousLayout ? 1 : 0,
                       tv.layoutManager.hasNonContiguousLayout ? 1 : 0)
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { commitProgress(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            commitProgress(scrollView)
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            commitProgress(scrollView)
        }

        // Fires when an animated setContentOffset (a page turn) finishes.
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isScrollingProgrammatically = false
            pageTargetY = nil
            commitProgress(scrollView)
        }

        private func commitProgress(_ scrollView: UIScrollView, pageCharIndex: Int? = nil) {
            guard !isScrollingProgrammatically, !isSeeking, let tv = textView else { return }
            guard tv.bounds.width > 0, tv.textStorage.length > 0 else { return }
            guard Date().timeIntervalSince(lastSyncDate) > 0.3 else { return }

            // Use the stable denominator confirmed at parse time; fall back to live
            // textStorage.length only when it has not been set yet (very first layout
            // tick before updateUIView delivers stableCharCount).
            let total = stableCharCount > 0 ? stableCharCount : tv.textStorage.length
            let value: Double
            if let charIdx = pageCharIndex {
                // Page-turn path: charIdx came from characterIndexForGlyph(at:) in
                // page() while the glyph was already ensured — zero TextKit queries here.
                value = total > 0 ? min(max(Double(charIdx) / Double(total), 0), 1) : 0
            } else {
                // Drag / decelerate path: characterIndex(for:point) fires only after
                // the finger lifts; visible glyphs are already laid out → O(local).
                value = charProgress(tv)
            }
            lastReportedProgress = value
            DispatchQueue.main.async { [weak self] in self?.progress = value }
        }

        // Fire immediately alongside UITextView's own recognizers — no waiting for their failure.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }

        // Page navigation is handled by SwiftUI tap zones in ReaderView.
        // This handler only toggles the bars (or lets highlight mode work).
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            onTap()
        }

        // Swipe left = next page, swipe right = previous page (standard book convention).
        @objc func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
            guard let tv = textView, tv.bounds.width > 0, !highlightMode else { return }
            switch gesture.direction {
            case .left:  page(tv, forward: true)
            case .right: page(tv, forward: false)
            default:     break
            }
        }

        // Probe (4): fires whenever the text selection changes (user selects text).
        func textViewDidChangeSelection(_ textView: UITextView) {
            let sel = textView.selectedRange
            guard sel.length > 0 else { return }
            let _selT0 = CFAbsoluteTimeGetCurrent()
            os_log("[NCL-4] textViewDidChangeSelection allow=%d has=%d vo=%d selLen=%d",
                   log: spLog, type: .info,
                   textView.layoutManager.allowsNonContiguousLayout ? 1 : 0,
                   textView.layoutManager.hasNonContiguousLayout ? 1 : 0,
                   UIAccessibility.isVoiceOverRunning ? 1 : 0,
                   sel.length)
            print(String(format: "[TIME] textSelection loc=%d len=%d",
                         sel.location, sel.length))
            _ = _selT0  // selection itself is instant; log location for context
        }

        // Add a "Highlight" submenu to the selection edit menu.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let actions = HighlightColor.allCases.map { hc in
                UIAction(title: hc.rawValue.capitalized) { [weak self] _ in
                    guard let self, let tv = self.textView else { return }
                    let ns = tv.textStorage.string as NSString
                    let safe = NSRange(location: range.location,
                                       length: min(range.length, ns.length - range.location))
                    let snippet = String(ns.substring(with: safe).prefix(80))
                    let prog = tv.textStorage.length > 0
                        ? Double(safe.location) / Double(tv.textStorage.length) : 0
                    self.onAddHighlight(safe, hc.rawValue, snippet, prog)
                    tv.selectedRange = NSRange(location: safe.location, length: 0)
                }
            }
            let highlightMenu = UIMenu(title: "Highlight",
                                       image: UIImage(systemName: "highlighter"),
                                       children: actions)
            return UIMenu(children: suggestedActions + [highlightMenu])
        }

        private var pageTargetY: CGFloat?   // intended offset while a turn animates

        func page(_ tv: UITextView, forward: Bool) {
            let _pageT0 = CFAbsoluteTimeGetCurrent()
            cancelRestore()   // user is navigating — don't let restore reset it
            let inset = tv.textContainerInset.top
            let visible = tv.bounds.height
            guard visible > 0 else { return }
            let overlap: CGFloat = 80
            let lm = tv.layoutManager
            let tc = tv.textContainer

            // Page by CHARACTER, not raw pixels: pick the glyph near the bottom
            // of the current view (for forward) and scroll so it sits at the top.
            // That glyph is already laid out, so the offset can't be clamped and
            // we never force a big relayout that would shift the pixel↔char map.
            let base = pageTargetY ?? tv.contentOffset.y
            let refContentY = forward ? base + (visible - overlap) : base - (visible - overlap)
            let refContainerY = max(0, refContentY - inset)
            // Lay out the region around the reference point (extends only from the
            // current layout frontier downward — content above is untouched), so
            // glyphIndex returns the real glyph instead of a clamped one near the
            // frontier (which would repeat the page).
            let ensureRect = CGRect(x: 0, y: refContainerY, width: tc.size.width, height: visible + overlap)
            lm.ensureLayout(forBoundingRect: ensureRect, in: tc)
            // glyphRange(forBoundingRect:in:) returns the range of glyphs that
            // overlap ensureRect — its .location is the FIRST glyph at refContainerY,
            // i.e. the top of the next page.  This is preferable to
            // glyphIndex(for:CGPoint:in:) because the dependency on ensureLayout is
            // explicit: we ask for glyphs IN the rect we just ensured, not the
            // "nearest" glyph to an arbitrary point which could snap outside it.
            let glyphRange = lm.glyphRange(forBoundingRect: ensureRect, in: tc)
            let glyphIdx = glyphRange.location
            // characterIndexForGlyph is O(1): glyph→char map built by ensureLayout.
            // Store under a unique page index so the CATransaction completion closure
            // can consume exactly its own entry even if another page() fires before
            // the animation completes.
            let capturedPageIndex = pageCounter
            pageCounter &+= 1
            pageCharMap[capturedPageIndex] = lm.characterIndexForGlyph(at: glyphIdx)
            let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
            let maxOffset = max(0, tv.contentSize.height - visible)
            let finalTarget = min(max(0, rect.minY + inset), maxOffset)
            guard abs(finalTarget - base) > 1 else { return }
            pageTargetY = finalTarget
            print(String(format: "[TIME] page %.0f ms  forward=%d targetY=%.0f",
                         (CFAbsoluteTimeGetCurrent() - _pageT0) * 1000, forward ? 1 : 0, finalTarget))

            // Set the offset INSTANTLY (never animated) so a growing contentSize
            // from lazy TextKit layout can't cancel the scroll. The motion is
            // supplied by a CATransition on the layer.
            let transition = CATransition()
            transition.duration = 0.35
            transition.type = .push
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            switch pageEffect {
            case .verticalSlide:
                transition.subtype = forward ? .fromTop : .fromBottom
            case .paper:
                transition.subtype = forward ? .fromRight : .fromLeft
            }
            isScrollingProgrammatically = true
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, capturedPageIndex] in
                guard let self else { return }
                self.isScrollingProgrammatically = false
                self.pageTargetY = nil
                // removeValue(forKey:) is the consume-and-delete: if another page()
                // fired during the animation, it will have stored a different key and
                // this closure only removes its own entry — preventing cross-talk.
                let charIdx = self.pageCharMap.removeValue(forKey: capturedPageIndex)
                self.commitProgress(tv, pageCharIndex: charIdx)
            }
            tv.layer.add(transition, forKey: "pageTurn")
            tv.setContentOffset(CGPoint(x: 0, y: finalTarget), animated: false)
            CATransaction.commit()
        }
    }
}
#endif
