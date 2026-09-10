import SwiftUI
import Combine

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
            let base = NSMutableAttributedString(NSAttributedString(attr))
            base.addAttributes(styleAttrs, range: NSRange(location: 0, length: base.length))
            for h in highlights where NSMaxRange(h.range) <= base.length {
                base.addAttribute(.backgroundColor,
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

// Subclass so we can hook into layoutSubviews after super has finished.
// After super.layoutSubviews(), contentSize is final and UITextView has already
// reset contentOffset to 0 (its internal behavior on attributedText replacement).
// This is the only place guaranteed to run after both of those steps.
private final class ReaderTextView: UITextView {
    var onDidLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onDidLayout?()
    }
}

struct NativeTextView: UIViewRepresentable {
    let text: String?
    let attributedText: AttributedString?
    var blocks: [ContentBlock] = []
    let settings: ReadingSettings
    var pageEffect: PageEffect = .verticalSlide
    var embeddedFontName: String?
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
        _ = textView.layoutManager
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
            applyContent(to: textView)
            textView.backgroundColor = UIColor(settings.currentPreset.background)
            context.coordinator.lastLayoutKey = layoutKey
            context.coordinator.lastColorKey = colorKey
            context.coordinator.lastContentKey = contentKey
            context.coordinator.scheduleRestore(progress, in: textView)
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

        // Search: find all matches, highlight active one, scroll to it.
        let searchQueryChanged = context.coordinator.lastSearchQuery != searchQuery
        let searchIndexChanged = context.coordinator.lastSearchResultIndex != searchResultIndex
        if searchQueryChanged {
            context.coordinator.lastSearchQuery = searchQuery
            context.coordinator.lastSearchResultIndex = searchResultIndex
            if !searchQuery.isEmpty {
                let str = textView.textStorage.string
                context.coordinator.searchMatches = iOSAllMatches(of: searchQuery, in: str)
            } else {
                context.coordinator.searchMatches = []
            }
        } else if searchIndexChanged {
            context.coordinator.lastSearchResultIndex = searchResultIndex
        }
        if searchQueryChanged || searchIndexChanged {
            iOSApplySearchHighlight(to: textView,
                                    matches: context.coordinator.searchMatches,
                                    index: searchResultIndex,
                                    coordinator: context.coordinator)
        }
    }

    private func iOSAllMatches(of query: String, in string: String) -> [NSRange] {
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

    private func applyContent(to textView: UITextView) {
        let fontName = embeddedFontName ?? settings.fontName
        let font = UIFont(name: fontName, size: settings.fontSize)
            ?? UIFont.systemFont(ofSize: settings.fontSize)
        let color = UIColor(settings.currentPreset.text)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = settings.lineSpacing

        // EPUB with images: build a rich NSAttributedString from blocks.
        // Phase 1 (main thread, synchronous): insert text blocks and size-correct
        //   placeholder attachments — no pixel decoding, so the textView gets its
        //   content (and an accurate contentSize for restore) immediately.
        // Phase 2 (background Task): decode each image's pixels, swap the placeholder's
        //   image property, and invalidate the layout for that glyph only.
        if !blocks.isEmpty {
            // textView may not be laid out yet → fall back to the screen width
            let insets = textView.textContainerInset.left + textView.textContainerInset.right + 10
            let laidOutWidth = textView.bounds.width - insets
            let available = laidOutWidth > 50 ? laidOutWidth
                : (UIScreen.main.bounds.width - 40)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle
            ]

            // (offset-in-result, raw Data) — both Sendable, safe to cross actor boundaries.
            // NSTextAttachment is NOT Sendable so we must NOT capture it in the Task;
            // instead we retrieve it from the text storage on the MainActor side.
            var pending: [(Int, Data)] = []
            let result = NSMutableAttributedString()

            for block in blocks {
                switch block {
                case .text(let s):
                    result.append(NSAttributedString(string: s + "\n\n", attributes: attrs))
                case .image(let data):
                    let attachment = NSTextAttachment()
                    // Read pixel dimensions from the image header without decompressing
                    // pixel data.  This gives the correct aspect ratio for the placeholder
                    // so contentSize is accurate and the restore scroll is on-target.
                    if let sz = Self.quickImageSize(data) {
                        let scale = min(1, available / max(sz.width, 1))
                        attachment.bounds = CGRect(x: 0, y: 0,
                                                   width: sz.width * scale,
                                                   height: sz.height * scale)
                    } else {
                        attachment.bounds = CGRect(x: 0, y: 0, width: available, height: available * 0.75)
                    }
                    pending.append((result.length, data))
                    result.append(NSAttributedString(attachment: attachment))
                    result.append(NSAttributedString(string: "\n\n", attributes: attrs))
                }
            }

            print("[EPUB] render: \(blocks.count) blocks, \(pending.count) images (placeholder), width=\(available)")
            textView.attributedText = result
            applyHighlights(to: textView)

            // Phase 2: rebuild the full attributed string on a background thread with
            // every image decoded, then swap it in one shot on the main thread.
            // Per-glyph addAttribute / invalidateDisplay updates are unreliable on
            // iOS 16+ (the NSLayoutManager glyph cache for attachment characters is
            // not guaranteed to flush on attribute-only edits).  A single full
            // attributedText= swap is the only path that always triggers a complete
            // redraw, at the cost of a brief blank period during decoding.
            //
            // Phase 1 above already set correctly-sized placeholder attachments so
            // contentSize is accurate and attemptRestore can scroll to the right
            // position before phase 2 finishes.  Phase 2 then saves the (restored)
            // offset, swaps in the real images, and restores the offset one run-loop
            // cycle later (after UITextView resets it to 0 on attributedText set).
            guard !pending.isEmpty else { return }
            let capturedBlocks = blocks
            let capturedAttrs = attrs
            let capturedAvailable = available
            let viewCapture = self      // NativeTextView is a value type — safe to copy
            DispatchQueue.global(qos: .userInitiated).async {
                let full = NSMutableAttributedString()
                for block in capturedBlocks {
                    switch block {
                    case .text(let s):
                        full.append(NSAttributedString(string: s + "\n\n",
                                                       attributes: capturedAttrs))
                    case .image(let data):
                        let att = NSTextAttachment()
                        if let image = UIImage(data: data) {
                            att.image = image
                            let scale = min(1.0, capturedAvailable / max(image.size.width, 1))
                            att.bounds = CGRect(x: 0, y: 0,
                                                width: image.size.width * scale,
                                                height: image.size.height * scale)
                        } else {
                            att.bounds = CGRect(x: 0, y: 0,
                                                width: capturedAvailable,
                                                height: capturedAvailable * 0.75)
                        }
                        full.append(NSAttributedString(attachment: att))
                        full.append(NSAttributedString(string: "\n\n", attributes: capturedAttrs))
                    }
                }
                let final = NSAttributedString(attributedString: full)
                DispatchQueue.main.async { [weak textView] in
                    // tv.window check was removed: on iOS 26 fullScreenCover builds
                    // the view in a staging layer before attaching it to a window,
                    // so tv.window is nil even while the book is actively displayed.
                    // [weak textView] already guards against dismissed books — UIKit
                    // zeroes weak refs before dealloc, so textView is nil (and we
                    // return early) by the time the teardown actually runs.
                    guard let tv = textView else {
                        print("[EPUB P2] textView was nil — book dismissed before decode finished")
                        return
                    }
                    print("[EPUB P2] applying full attributed string, window=\(tv.window != nil)")
                    let savedOffset = tv.contentOffset
                    tv.attributedText = final
                    viewCapture.applyHighlights(to: tv)
                    // UITextView resets contentOffset to {0,0} when attributedText is
                    // replaced.  Restore the saved offset one run-loop cycle later so
                    // the internal layout pass triggered by the swap completes first.
                    DispatchQueue.main.async {
                        tv.setContentOffset(savedOffset, animated: false)
                    }
                }
            }
            return
        }

        if let attr = attributedText {
            textView.attributedText = NSAttributedString(attr)
            // font/textColor serve as fallbacks for any unstyled ranges in the attributed string.
            textView.font = font
            textView.textColor = color
        } else if let str = text {
            // Embed font, color, and paragraph style into the attributed string before
            // handing it to UITextView. A single attributedText= is a lazy operation
            // (layout is invalidated, not forced synchronously), whereas setting text= and
            // then calling storage.addAttribute(.paragraphStyle, ...) would force a
            // synchronous full-document layout pass on the main thread — freezing the UI
            // for several seconds in large books.
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if settings.lineSpacing > 0 { attrs[.paragraphStyle] = paragraphStyle }
            textView.attributedText = NSAttributedString(string: str, attributes: attrs)
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
            let storage = textView.textStorage
            lastHighlight = range
            guard storage.length > 0 else { return }
            // Clear ALL background colors from the full text, then reapply user
            // highlights and the new TTS highlight atomically. This guarantees
            // exactly one TTS-highlighted region regardless of prior state.
            let full = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.backgroundColor, range: full)
            for h in userHighlights where NSMaxRange(h.range) <= storage.length {
                let c = UIColor(HighlightColor(rawValue: h.colorName)?.color ?? .yellow)
                    .withAlphaComponent(0.4)
                storage.addAttribute(.backgroundColor, value: c, range: h.range)
            }
            if let r = range, NSMaxRange(r) <= storage.length {
                storage.addAttribute(.backgroundColor, value: color, range: r)
                scrollToSentence(r, in: textView)
                let v = min(max(Double(r.location) / Double(storage.length), 0), 1)
                lastReportedProgress = v
                DispatchQueue.main.async { [weak self] in self?.progress = v }
            }
        }

        // In vertical-slide mode: smooth-scroll to the highlighted range.
        // In paper mode: flip to the page containing the range only when
        // the range is outside the current visible area and no flip is pending.
        private func scrollToSentence(_ r: NSRange, in textView: UITextView) {
            if pageEffect == .paper {
                guard pageTargetY == nil else { return }
                let lm = textView.layoutManager
                let tc = textView.textContainer
                let glyphRange = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
                let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
                let sentenceTop = rect.minY + textView.textContainerInset.top
                let visibleTop = textView.contentOffset.y
                let visibleBottom = visibleTop + textView.bounds.height
                if sentenceTop >= visibleBottom {
                    page(textView, forward: true)
                } else if rect.maxY + textView.textContainerInset.top < visibleTop {
                    page(textView, forward: false)
                }
            } else {
                isScrollingProgrammatically = true
                textView.scrollRangeToVisible(r)
                isScrollingProgrammatically = false
            }
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
            let total = tv.textStorage.length
            guard total > 0 else { return 0 }
            let p = CGPoint(x: 0, y: max(0, tv.contentOffset.y - tv.textContainerInset.top))
            let idx = tv.layoutManager.characterIndex(for: p, in: tv.textContainer,
                                                      fractionOfDistanceBetweenInsertionPoints: nil)
            return min(max(Double(idx) / Double(total), 0), 1)
        }

        private func offsetForCharProgress(_ target: Double, in tv: UITextView) -> CGFloat {
            let total = tv.textStorage.length
            guard total > 0 else { return 0 }
            let idx = max(0, min(Int(target * Double(total)), total - 1))
            let glyphRange = tv.layoutManager.glyphRange(forCharacterRange: NSRange(location: idx, length: 1),
                                                         actualCharacterRange: nil)
            let rect = tv.layoutManager.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
            return rect.minY + tv.textContainerInset.top
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

        private func applySeek(_ target: Double, in textView: UITextView) {
            let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
            let targetY = min(max(0, textView.contentSize.height * target), maxOffset)
            guard abs(textView.contentOffset.y - targetY) > 1 else { return }
            guard textView.contentSize.height > textView.bounds.height else { return }
            isScrollingProgrammatically = true
            textView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            isScrollingProgrammatically = false
        }

        private var pendingRestoreTarget: Double?
        private var isRestorePending = false
        private var restoreRetries = 0

        // Throttle: at most one setContentOffset per 50 ms during rapid bar drag.
        // TextKit 1 must lay out all text up to the new position synchronously on
        // the main thread — without throttling, every drag event triggers a layout
        // pass that freezes large documents.
        private var seekWorkItem: DispatchWorkItem?
        private var lastSeekDate = Date.distantPast
        private var latestSeekTarget: Double = 0   // always holds the most-recent target
        private var lastSyncDate = Date.distantPast // tracks when bar drag last fired
        private let seekInterval: TimeInterval = 0.05

        private func cancelRestore() {
            pendingRestoreTarget = nil
            isRestorePending = false
            restoreRetries = 0
        }

        func scheduleRestore(_ target: Double, in textView: UITextView) {
            cancelRestore()
            pendingRestoreTarget = target
            isRestorePending = true
            lastReportedProgress = nil
        }

        // Called from ReaderTextView.layoutSubviews() after super returns.
        // contentSize may be zero on the first pass while UIKit is still settling.
        // Retry once via async (no setNeedsLayout — that forces a full re-layout of
        // the entire TextKit 1 document, which freezes the UI for large books).
        // After one retry, give up and let syncProgress handle it normally.
        func didLayout(in tv: UITextView) {
            guard let target = pendingRestoreTarget else { return }
            let maxOffset = max(0, tv.contentSize.height - tv.bounds.height)
            guard maxOffset > 0 else {
                if restoreRetries == 0 {
                    restoreRetries = 1
                    DispatchQueue.main.async { [weak self, weak tv] in
                        guard let self, let tv, self.pendingRestoreTarget != nil else { return }
                        self.didLayout(in: tv)
                    }
                } else {
                    cancelRestore()
                }
                return
            }
            cancelRestore()
            let clamped = min(max(0, tv.contentSize.height * target), maxOffset)
            isScrollingProgrammatically = true
            tv.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
            isScrollingProgrammatically = false
            lastReportedProgress = target
        }

        // Update progress only when scrolling settles — writing the binding on
        // every frame re-renders the SwiftUI tree mid-scroll and causes jitter.
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            pageTargetY = nil      // user took over; forget any queued page target
            cancelRestore()   // and cancel any in-flight position restore
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

        private func commitProgress(_ scrollView: UIScrollView) {
            guard !isScrollingProgrammatically, let tv = textView else { return }
            guard tv.bounds.width > 0, tv.textStorage.length > 0 else { return }
            // If the progress bar was moved recently, don't let the scroll-position
            // commit overwrite vm.progress — that would snap the bar back mid-drag.
            guard Date().timeIntervalSince(lastSyncDate) > 0.3 else { return }
            let value = charProgress(tv)
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
            let glyphIdx = lm.glyphIndex(for: CGPoint(x: 0, y: refContainerY), in: tc)
            let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
            let maxOffset = max(0, tv.contentSize.height - visible)
            let finalTarget = min(max(0, rect.minY + inset), maxOffset)
            guard abs(finalTarget - base) > 1 else { return }
            pageTargetY = finalTarget

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
            CATransaction.setCompletionBlock {
                self.isScrollingProgrammatically = false
                self.pageTargetY = nil
                self.commitProgress(tv)
            }
            tv.layer.add(transition, forKey: "pageTurn")
            tv.setContentOffset(CGPoint(x: 0, y: finalTarget), animated: false)
            CATransaction.commit()
        }
    }
}
#endif
