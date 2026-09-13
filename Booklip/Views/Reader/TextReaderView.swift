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

/// How many matches on either side of the active one get painted. A common
/// token in a multi-MB book yields tens of thousands of matches; painting all
/// of them (and clearing the WHOLE storage first) froze the reader for seconds
/// on every search and every next/prev tap. Only a window around the active
/// match is ever visible anyway.
private let searchPaintWindow = 150

/// Repaints search-match backgrounds incrementally: clears only the ranges
/// painted last time (repainting user highlights underneath), then paints a
/// window of matches around the active one, all inside one editing batch.
/// Returns the active match so the caller can scroll to it. Shared by the
/// iOS and macOS text views.
private func repaintSearchMatches(in storage: NSTextStorage,
                                  matches: [NSRange], index: Int,
                                  painted: inout [NSRange],
                                  dim: Any, bright: Any,
                                  reapplyUserHighlights: (NSTextStorage, NSRange) -> Void) -> NSRange? {
    storage.beginEditing()
    for r in painted where NSMaxRange(r) <= storage.length {
        storage.removeAttribute(.backgroundColor, range: r)
        reapplyUserHighlights(storage, r)
    }
    painted.removeAll()
    guard !matches.isEmpty else { storage.endEditing(); return nil }
    let activeIdx = ((index % matches.count) + matches.count) % matches.count
    let lo = max(0, activeIdx - searchPaintWindow)
    let hi = min(matches.count - 1, activeIdx + searchPaintWindow)
    painted.reserveCapacity(hi - lo + 1)
    for i in lo...hi {
        let m = matches[i]
        guard NSMaxRange(m) <= storage.length else { continue }
        storage.addAttribute(.backgroundColor, value: i == activeIdx ? bright : dim, range: m)
        painted.append(m)
    }
    storage.endEditing()
    return matches[activeIdx]
}

struct TextReaderView: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var settings: ReadingSettings
    @Binding var showBars: Bool
    @ObservedObject var tts: TTSManager
    @Binding var pageNavigationDirection: Int
    var searchQuery: String = ""
    var searchResultIndex: Int = 0
    @Binding var highlightMode: Bool
    @Binding var autoScrolling: Bool
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
            .onReceive(eventChannel.$highlightRequest.dropFirst()) { req in
                guard let req else { return }
                vm.addHighlight(range: req.range, colorName: req.colorName,
                                snippet: req.snippet, progress: req.progress)
            }
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
            vm: vm,
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
            onTap: { xFraction in
                // Bars up → any tap hides them.
                if showBars { showBars = false; return }
                // Vertical-slide mode has no SwiftUI tap zones (they would block
                // scrolling), so edge taps page here and the middle shows the bars.
                if settings.pageEffect == .verticalSlide, !highlightMode {
                    if xFraction < 0.3 { pageNavigationDirection = -1 }
                    else if xFraction > 0.7 { pageNavigationDirection = 1 }
                    else { showBars = true }
                } else {
                    showBars = true
                }
            }
        )
    }
#endif
}

#if os(macOS)
final class TextViewEventChannel: ObservableObject {
    @Published var scrollProgress: Double = 0
    @Published var tapCount: Int = 0
    // "Highlight" chosen from the NSTextView context menu. Routed through the
    // channel (weakly held by the coordinator) rather than a closure so the
    // coordinator never captures the view model.
    struct HighlightRequest { let range: NSRange; let colorName: String; let snippet: String; let progress: Double }
    @Published var highlightRequest: HighlightRequest? = nil
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
        textView.delegate = context.coordinator   // context menu → "Highlight" submenu
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
        context.coordinator.userHighlights = highlights

        let macFontName = FontRegistrar.effectiveFontName(embeddedFontName ?? settings.fontName, sample: text ?? "")
        let macLayoutKey = "\(macFontName)|\(settings.fontSize)|\(settings.lineSpacing)"
        let macColorKey = "\(settings.presetId)|hl\(highlights.count)"
        let contentKey: String = {
            if !blocks.isEmpty {
                let bucket = (Int(textView.bounds.width) / 50) * 50
                return "blocks-\(blocks.count)-w\(bucket)"
            }
            // utf16.count is O(1) (breadcrumbs) after the first call; String.count
            // is an uncached O(N) grapheme walk that ran on every update pass.
            return text.map { "txt-\($0.utf16.count)" }
                ?? "attr-\(attributedText.map { $0.characters.count } ?? 0)"
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
                                 index: searchResultIndex,
                                 coordinator: context.coordinator)
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

    private func applySearchHighlight(to textView: NSTextView, matches: [NSRange], index: Int,
                                      coordinator: Coordinator) {
        guard let storage = textView.textStorage else { return }
        let active = repaintSearchMatches(
            in: storage, matches: matches, index: index,
            painted: &coordinator.paintedSearchRanges,
            dim: NSColor.systemYellow.withAlphaComponent(0.3),
            bright: NSColor.systemYellow.withAlphaComponent(0.75)
        ) { storage, range in coordinator.reapplyUserHighlights(in: storage, over: range) }
        guard let active else { return }
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
        let fontName = FontRegistrar.effectiveFontName(embeddedFontName ?? settings.fontName, sample: text ?? "")
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

    class Coordinator: NSObject, NSTextViewDelegate {
        // Weak references only — coordinator can outlive the SwiftUI view hierarchy
        // (AppKit retains it via the gesture recognizer on NSTextView). Using weak
        // references means all writes become no-ops after the view is dismantled,
        // regardless of teardown order. No closures, no @Binding captures.
        weak var eventChannel: TextViewEventChannel?
        weak var scrollView: NSScrollView?

        // Context menu on a selection gets a "Highlight" submenu (4 colors). This
        // is the macOS path for creating highlights; iOS uses the edit menu.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let sel = view.selectedRange()
            guard sel.length > 0 else { return menu }
            let sub = NSMenu(title: "Highlight")
            for hc in HighlightColor.allCases {
                let item = NSMenuItem(title: hc.rawValue.capitalized,
                                      action: #selector(highlightMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = hc.rawValue
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.insertItem(NSMenuItem.separator(), at: 0)
            menu.insertItem(parent, at: 0)
            return menu
        }

        @objc private func highlightMenuAction(_ sender: NSMenuItem) {
            guard let colorName = sender.representedObject as? String,
                  let tv = scrollView?.documentView as? NSTextView,
                  let storage = tv.textStorage else { return }
            let sel = tv.selectedRange()
            guard sel.length > 0, sel.location < storage.length else { return }
            let safe = NSRange(location: sel.location, length: min(sel.length, storage.length - sel.location))
            let snippet = String((storage.string as NSString).substring(with: safe).prefix(80))
            let prog = Double(safe.location) / Double(max(1, storage.length))
            eventChannel?.highlightRequest = .init(range: safe, colorName: colorName,
                                                   snippet: snippet, progress: prog)
            tv.setSelectedRange(NSRange(location: safe.location, length: 0))
        }
        var isScrollingProgrammatically = false
        var isDismantled = false
        private var lastHighlight: NSRange?
        var lastLayoutKey = ""
        var lastColorKey = ""
        var lastContentKey = ""
        var lastSearchQuery = ""
        var lastSearchResultIndex = 0
        var searchMatches: [NSRange] = []
        var paintedSearchRanges: [NSRange] = []   // what the last repaint painted
        var userHighlights: [Highlight] = []
        private var keyMonitor: Any?

        // `.backgroundColor` is a single shared channel — user highlights, the TTS
        // sentence and search matches all paint into it. Anything that clears it over
        // a range must repaint the user's own highlights underneath, or saved
        // highlights vanish until the storage is rebuilt.
        func reapplyUserHighlights(in storage: NSTextStorage, over cleared: NSRange) {
            for h in userHighlights {
                let overlap = NSIntersectionRange(h.range, cleared)
                guard overlap.length > 0, NSMaxRange(overlap) <= storage.length else { continue }
                let color = NSColor(HighlightColor(rawValue: h.colorName)?.color ?? .yellow)
                    .withAlphaComponent(0.4)
                storage.addAttribute(.backgroundColor, value: color, range: overlap)
            }
        }

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
            let full = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.backgroundColor, range: full)
            reapplyUserHighlights(in: storage, over: full)
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
    let vm: ReaderViewModel
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
    /// Called with the tap's horizontal position as a 0...1 fraction of the view width.
    let onTap: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, autoScrolling: $autoScrolling, onTap: onTap)
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        // CADisplayLink(target: self) retains the coordinator, so deinit can never
        // run while auto-scroll is on — dismissing the reader mid-auto-scroll leaked
        // the coordinator (and via its closures the view model with the whole book)
        // and left a display link firing every frame for the process lifetime.
        coordinator.setAutoScrolling(false)
        coordinator.currentSearchTask?.cancel()
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
        context.coordinator.vm = vm
        context.coordinator.settings = settings

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
        let fontName = FontRegistrar.effectiveFontName(embeddedFontName ?? settings.fontName, sample: text ?? "")
        let layoutKey = "\(fontName)|\(settings.fontSize)|\(settings.lineSpacing)"
        let colorKey = "\(settings.presetId)|hl\(highlights.count)"
        let contentKey: String = {
            if !blocks.isEmpty { return "blocks-\(blocks.count)" }
            // stableCharCount is the already-known UTF-16 length; String.count was
            // an uncached O(N) grapheme walk on every update pass (tens of ms on a
            // multi-MB book, hit on every scroll settle / TTS sentence / pagination tick).
            return text.map { _ in "txt-\(stableCharCount)" }
                ?? "attr-\(attributedText.map { $0.characters.count } ?? 0)"
        }()

        let layoutChanged = context.coordinator.lastLayoutKey != layoutKey
            || context.coordinator.lastContentKey != contentKey
        let colorChanged = context.coordinator.lastColorKey != colorKey

        if layoutChanged {
            // scheduleRestore must be called BEFORE applyContent (specifically before
            // setAttributedString). For EPUB/markdown the setAttributedString call is
            // synchronous and immediately triggers layoutSubviews → onDidLayout (one
            // async tick later). If pendingRestoreTarget is nil at that point, didLayout
            // returns early and no further layout event re-fires it — the view stays at
            // the top regardless of book.progress. Setting pendingRestoreTarget first
            // ensures didLayout sees it when it fires from the layout triggered by
            // setAttributedString. For plain-text the task is async so the order matters
            // less, but consistency is correct in both cases.
            context.coordinator.scheduleRestore(progress, in: textView)
            context.coordinator.lastLayoutKey = layoutKey
            context.coordinator.lastColorKey = colorKey
            context.coordinator.lastContentKey = contentKey
            let _applyT0 = CFAbsoluteTimeGetCurrent()
            applyContent(to: textView, coordinator: context.coordinator)
            print(String(format: "[TIME] layoutChanged-applyContent %.0f ms  layout=%@ content=%@",
                         (CFAbsoluteTimeGetCurrent() - _applyT0) * 1000,
                         layoutKey as NSString, contentKey as NSString))
            textView.backgroundColor = UIColor(settings.currentPreset.background)
            // EPUB: stableCharCount must match textStorage.length (which includes
            // U+FFFC attachment chars) so that charIdx computed in applySeek stays
            // within [0, textStorage.length).
            // For txt: textStorage is filled asynchronously in Task.detached, so
            // textStorage.length is 0 here; we use stableCharCount (NSString length
            // of vm.plainText) which equals the eventual textStorage.length exactly.
            let actualLength = !blocks.isEmpty ? textView.textStorage.length : stableCharCount
            if actualLength > 0 {
                context.coordinator.stableCharCount = actualLength
            }
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
        let _t0 = CFAbsoluteTimeGetCurrent()
        let active = repaintSearchMatches(
            in: storage, matches: matches, index: index,
            painted: &coordinator.paintedSearchRanges,
            dim: UIColor.systemYellow.withAlphaComponent(0.3),
            bright: UIColor.systemYellow.withAlphaComponent(0.75)
        ) { storage, range in coordinator.reapplyUserHighlights(in: storage, over: range) }
        print(String(format: "[TIME] searchRepaint %.0f ms  painted=%d of %d",
                     (CFAbsoluteTimeGetCurrent() - _t0) * 1000,
                     coordinator.paintedSearchRanges.count, matches.count))
        guard let active else { return }
        coordinator.isScrollingProgrammatically = true
        textView.scrollRangeToVisible(active)
        coordinator.isScrollingProgrammatically = false
        // A search jump bypasses landingLoop, so rebase the page counter here or
        // the "Page X / Y" label keeps the pre-search page.
        let total = stableCharCount > 0 ? stableCharCount : storage.length
        let vmRef = vm
        Task { @MainActor in vmRef.rebasePage(atCharIdx: active.location, totalChars: total) }
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
        let fontName = FontRegistrar.effectiveFontName(embeddedFontName ?? settings.fontName, sample: text ?? "")
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
        let onTap: (CGFloat) -> Void
        weak var textView: UITextView?
        var isScrollingProgrammatically = false
        var lastLayoutKey = ""
        var lastColorKey = ""
        var lastContentKey = ""
        var lastPaginationKey = ""
        weak var vm: ReaderViewModel?
        weak var settings: ReadingSettings?
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
        // Tracks consecutive page-turn char deltas for [PAGE] calibration.
        private var lastPageCharIdx: Int? = nil
        private var pageCharDeltas: [Int] = []
        // Guards PAGE-CAL so it locks at most once per session — without this,
        // pageCharDeltas refills after removeAll() and re-locks (and re-saves the
        // profile / re-rebases currentPage) every further 10 page turns.
        private var hasLockedCharsPerPage = false
        private var postSeekExclude = false   // drop next sample after a seek
        // landingLoop's exact-position probe (ensureLayout(forCharacterRange:) +
        // lineFragmentRect) is disabled for the session if it ever proves slow.
        private var charProbeDisabled = false
        private var currentProfileKey = ""

        // ── Stable progress denominator ────────────────────────────────────────
        // Set once when the book's text is loaded; never updated thereafter.
        // textStorage.length fluctuates during EPUB phase-2 attachment swaps;
        // this value is the UTF-16 length of the full plain-text string, which
        // is invariant across all UI phases.
        var stableCharCount: Int = 0

        // Auto-scroll
        var autoScrollSpeed: Double = 40            // points per second
        private var displayLink: CADisplayLink?
        private var autoScrollAccumulator: CFTimeInterval = 0

        // Highlights
        var highlightMode = false
        var onAddHighlight: (NSRange, String, String, Double) -> Void = { _, _, _, _ in }
        var userHighlights: [Highlight] = []

        // `.backgroundColor` is a single shared channel — user highlights, the TTS
        // sentence and search matches all paint into it. Anything that clears it over
        // a range must repaint the user's own highlights underneath, or saved
        // highlights vanish until the storage is rebuilt.
        func reapplyUserHighlights(in storage: NSTextStorage, over cleared: NSRange) {
            for h in userHighlights {
                let overlap = NSIntersectionRange(h.range, cleared)
                guard overlap.length > 0, NSMaxRange(overlap) <= storage.length else { continue }
                let color = UIColor(HighlightColor(rawValue: h.colorName)?.color ?? .yellow)
                    .withAlphaComponent(0.4)
                storage.addAttribute(.backgroundColor, value: color, range: overlap)
            }
        }

        // Search
        var lastSearchQuery = ""
        var lastSearchResultIndex = 0
        var searchMatches: [NSRange] = []
        var paintedSearchRanges: [NSRange] = []   // what the last repaint painted
        var currentSearchTask: Task<Void, Never>?
        var currentPlainTextBuildTask: Task<Void, Never>?

        // Content-size cache — persisted to UserDefaults so that the second open
        // of a book skips all retries and restores position immediately.
        // Key is set by updateUIView using contentKey + layoutKey + screen width.

        init(progress: Binding<Double>, autoScrolling: Binding<Bool>, onTap: @escaping (CGFloat) -> Void) {
            _progress = progress
            _autoScrolling = autoScrolling
            self.onTap = onTap
        }

        deinit { displayLink?.invalidate() }

        func triggerPaginationIfNeeded(tv: UITextView) {
            guard let vm, let settings, tv.bounds.width > 0, tv.bounds.height > 0 else { return }
            let insets = tv.textContainerInset
            let padding = tv.textContainer.lineFragmentPadding
            let textAreaW = tv.bounds.width  - insets.left - insets.right - 2 * padding
            let textAreaH = tv.bounds.height - insets.top  - insets.bottom
            vm.textAreaSize = CGSize(width: textAreaW, height: textAreaH)

            // [PAGE-STEP] log — fire once per layout key change.
            // Must be the font that actually renders (see FontRegistrar.effectiveFontName),
            // or the charsPerPage profile is stored under the wrong font name and a
            // different book rendered in that font inherits the wrong calibration.
            let fontName = FontRegistrar.effectiveFontName(
                settings.useEmbeddedFont ? (vm.embeddedFontName ?? settings.fontName) : settings.fontName,
                sample: vm.plainText)
            let layoutKey = "\(vm.book.id)|\(fontName)|\(settings.fontSize)|\(settings.lineSpacing)|\(Int(tv.bounds.width))x\(Int(tv.bounds.height))"
            if layoutKey != lastPaginationKey {
                let fontSize   = max(1.0, settings.fontSize)
                let lineHeight = fontSize + max(0.0, settings.lineSpacing)
                let linesPerPage = floor(textAreaH / lineHeight)
                let pageStep   = linesPerPage * lineHeight
                let charsPerLine = floor(textAreaW / fontSize)
                let seedCPP    = max(1, Int(charsPerLine * linesPerPage))
                assert(pageStep <= textAreaH + 0.5,
                       "[PAGE-STEP] pageStep \(pageStep) > textAreaH \(textAreaH)")
                print(String(format: "[PAGE-SIZE] bounds=%.0fx%.0f  textArea=%.0fx%.0f  insets=(%.0f,%.0f,%.0f,%.0f)  padding=%.0f",
                             tv.bounds.width, tv.bounds.height, textAreaW, textAreaH,
                             insets.top, insets.left, insets.bottom, insets.right, padding))
                print(String(format: "[PAGE-STEP] lineHeight=%.1f linesPerPage=%.0f pageStep=%.1f textAreaH=%.0f  seedCPP=%d",
                             lineHeight, linesPerPage, pageStep, textAreaH, seedCPP))

                // Seed total pages from cached profile or formula.
                let profileKey = PaginationProfile.key(
                    fontName: fontName, fontSize: settings.fontSize,
                    lineSpacing: settings.lineSpacing,
                    textAreaW: Double(textAreaW), textAreaH: Double(textAreaH))
                currentProfileKey = profileKey
                let cpp = PaginationProfile.load(key: profileKey)?.charsPerPage ?? seedCPP
                vm.seedTotalPages(charsPerPage: cpp)

                lastPaginationKey = layoutKey
                vm.startPagination(containerWidth: tv.bounds.width,
                                   containerHeight: tv.bounds.height,
                                   settings: settings)
            }
        }

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
                reapplyUserHighlights(in: storage, over: p)
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
            let lm = tv.layoutManager
            let tc = tv.textContainer
            let inset = tv.textContainerInset.top
            // With allowsNonContiguousLayout=true, characterIndex(for:point:in:) snaps
            // to the boundary of the nearest laid-out region when called on an unlaid
            // point — returning char ~0 for a mid-document scroll position, which is
            // 1/10 (or worse) of the real value.  glyphRange(forBoundingRect:) stays
            // within already-laid-out glyphs (the visible region is always laid out),
            // then characterIndexForGlyph is O(1) on the pre-built glyph→char map.
            let visibleRect = CGRect(
                x: 0,
                y: max(0, tv.contentOffset.y - inset),
                width: tc.size.width,
                height: tv.bounds.height
            )
            let gr = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
            guard gr.location != NSNotFound, gr.length > 0 else { return 0 }
            let idx = lm.characterIndexForGlyph(at: gr.location)
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
                applySeek(target, in: textView, trigger: "end-immediate")
            } else {
                // Throttle: apply seek on the next tick so rapid sequential calls
                // (e.g. TTS or TOC jumps) coalesce into the most-recent target.
                let remaining = seekInterval - elapsed
                let work = DispatchWorkItem { [weak self, weak textView] in
                    guard let self, let tv = textView else { return }
                    self.lastSeekDate = Date()
                    self.applySeek(self.latestSeekTarget, in: tv, trigger: "end-throttled")
                }
                seekWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
            }
        }

        private var lastAppliedSeekTarget: Double = -1

        // Shared NCL-safe landing loop used by BOTH didLayout's restore and
        // applySeek. Iteratively moves `tv`'s contentOffset toward the Y that
        // lands on `targetCharIdx`, using SECANT interpolation from the actual
        // (Δy, Δchar) of the last two real samples for local density — not a
        // fixed cpp/pageStep ratio, which measured up to ~9x off between the
        // already-laid-out (~0.35-0.47 chars/pt) and not-yet-laid-out
        // (~3-4.4 chars/pt) regions.
        //
        // ROOT CAUSE of the multi-second/minute stalls this loop was blamed for
        // (2026-09-12, process sample): NOT layout. It was NSTextStorage
        // fixFontAttribute(in:) inserting per-run substitute fonts (memmove of the
        // whole run array per insert — quadratic) because the base font (Georgia)
        // had no Hangul glyphs. It runs lazily inside ensureLayout/layoutIfNeeded/
        // glyphRange(forBoundingRect:), so every timing below pointed at layout.
        // Fixed at the source by FontRegistrar.effectiveFontName (base font that
        // covers the text): same 59%→22% seek went 173,439ms → 62ms, cold restore
        // 2,284ms → 103ms. The notes below remain accurate about API semantics.
        //
        // Each attempt calls ensureLayout(forBoundingRect:) before setContentOffset —
        // measured on-device to be REQUIRED, not optional: without it, jumping into
        // a not-yet-laid-out region gets silently rejected by UIScrollView (snaps
        // back to contentOffset=0) even though the glyphRange measurement below
        // still reports a plausible landedProgress (it's keyed off our own `y`, not
        // the actual — rejected — contentOffset), masking the failure. Removing
        // ensureLayout also did NOT reduce the cost: it just moved into
        // layoutIfNeeded() instead, same order of magnitude (measured: 3042ms for
        // a single jump to ~51% of a 7.8M-char document on cold restore). ensureMs
        // and stepMs are logged separately so this split stays visible.
        //
        // Safety guards below apply regardless of root cause of a hang:
        // - 350ms wall-clock budget, measured from the END of attempt 0: attempt 0
        //   carries the unavoidable cold-layout cost (~3s on a 7.8M-char book), so
        //   counting it made the loop bail after a single attempt on every cold
        //   restore/seek — no correction at all, landing thousands of chars off.
        //   The budget exists to bound the CORRECTION attempts, not the first hop.
        //   Exceeded → snap to the best sample seen, stop. (Can only stop BETWEEN
        //   attempts — cannot interrupt a call already in flight.)
        // - dy clamp: +50,000pt forward / -20,000pt backward — backward seeks into
        //   not-yet-laid-out regions have been the expensive/hang-prone direction.
        // - density validity: only 0.01...50 chars/pt accepted; negative or
        //   non-finite density (a degenerate sample) is rejected, falling back to
        //   the live textStorage.length/contentSize.height bootstrap instead.
        // Logs "[tag] attempt=N landed=X diff=Y density=Z dy=W ensureMs=U stepMs=V
        // elapsed=Nms" per try.
        private func landingLoop(
            tv: UITextView, startY: CGFloat, targetCharIdx: Int, totalChars: Int,
            tag: String, maxAttempts: Int = 8, wallClockBudgetMs: Double = 350,
            onLanded: ((Int, Double) -> Void)? = nil
        ) -> (y: CGFloat, charIdx: Int, progress: Double) {
            let lm = tv.layoutManager
            let tc = tv.textContainer
            let inset = tv.textContainerInset.top
            let viewH = max(tv.bounds.height, 100)
            // LIVE, not captured once: contentSize grows as ensureLayout / the
            // exact probe lay out further text (TextKit under-estimates unlaid
            // regions). A maxOffset captured before the loop clamped correctedY
            // to the OLD end of the document, made `correctedY == y`, and ended
            // the loop silently short of the target (observed: an 80% seek ending
            // at 61%, a 80% restore ending at 77% ≈ 16 pages off).
            func currentMaxOffset() -> CGFloat {
                let insets = tv.textContainerInset
                let used = lm.usedRect(for: tc).height + insets.top + insets.bottom
                return max(0, max(tv.contentSize.height, used) - tv.bounds.height)
            }

            let t0 = CFAbsoluteTimeGetCurrent()
            var budgetStart = t0   // reset to the end of attempt 0 inside the loop
            var y = min(max(0, startY), currentMaxOffset())
            var landedCharIdx = 0
            var landedProgress = 0.0
            // Best-seen tracking: secant can overshoot on a density swing before it
            // converges — if the loop ends somewhere worse, snap back to this.
            var bestY = y
            var bestCharIdx = 0
            var bestAbsDiff = Int.max
            var prevY: CGFloat?
            var prevCharIdx: Int?

            for attempt in 0..<maxAttempts {
                // REVERTED: removing ensureLayout(forBoundingRect:) here did NOT
                // eliminate the multi-second cost — it just moved it into
                // layoutIfNeeded() (measured: stepMs=3042 with ensureLayout absent,
                // same order of magnitude as ensureLayout alone previously). Worse,
                // it reintroduced a real regression: setContentOffset into a region
                // TextKit hasn't actually laid out yet gets silently rejected by
                // UIScrollView, which snaps back to contentOffset=(0,0) — while our
                // own `y` variable (used to build visRect for the glyphRange
                // measurement) still reported a plausible landedProgress, masking
                // the mismatch (confirmed on device: landed=0.51 but the final
                // offsetY was 0). ensureLayout is what makes TextKit accept the
                // offset in the first place; it isn't optional. Timed separately
                // from setContentOffset+layoutIfNeeded below so the split is visible.
                let ensureRect = CGRect(x: 0, y: max(0, y - inset - viewH * 0.5),
                                        width: tc.size.width, height: viewH * 2)
                let _tEnsure = CFAbsoluteTimeGetCurrent()
                lm.ensureLayout(forBoundingRect: ensureRect, in: tc)
                let ensureMs = (CFAbsoluteTimeGetCurrent() - _tEnsure) * 1000

                let _tStep0 = CFAbsoluteTimeGetCurrent()
                isScrollingProgrammatically = true
                tv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                isScrollingProgrammatically = false
                tv.layoutIfNeeded()
                let stepMs = (CFAbsoluteTimeGetCurrent() - _tStep0) * 1000
                // Defensive check for the exact regression found on device: UIScrollView
                // can silently reject an offset into not-yet-laid-out content and snap
                // back (commonly to 0) rather than throwing or failing ensureLayout —
                // the glyphRange measurement below still succeeds (it's keyed off our
                // own `y`, not the actual contentOffset), so without this check a
                // rejected jump looks identical to a successful one in the logs.
                if abs(tv.contentOffset.y - y) > 5 {
                    print(String(format: "[\(tag)] WARNING setContentOffset rejected: requested=%.0f actual=%.0f",
                                 Double(y), Double(tv.contentOffset.y)))
                }

                let visRect = CGRect(x: 0, y: max(0, y - inset), width: tc.size.width, height: viewH)
                let gr = lm.glyphRange(forBoundingRect: visRect, in: tc)
                if gr.location != NSNotFound, gr.length > 0, totalChars > 0 {
                    landedCharIdx = lm.characterIndexForGlyph(at: gr.location)
                    landedProgress = min(max(Double(landedCharIdx) / Double(totalChars), 0), 1)
                }
                let charDiff = targetCharIdx - landedCharIdx
                if abs(charDiff) < bestAbsDiff {
                    bestAbsDiff = abs(charDiff)
                    bestY = y
                    bestCharIdx = landedCharIdx
                }

                // [3] density validity guard: reject negative/non-finite/out-of-range
                // samples (0.01...50 chars/pt) rather than extrapolating off them.
                var density = 0.0
                if let py = prevY, let pc = prevCharIdx, abs(y - py) > 0.5, pc != landedCharIdx {
                    let raw = Double(landedCharIdx - pc) / Double(y - py)
                    if raw.isFinite, raw >= 0.01, raw <= 50 { density = raw }
                }

                let dyRaw: CGFloat
                if density != 0 {
                    dyRaw = CGFloat(Double(charDiff) / density)
                } else {
                    // Bootstrap: no valid local density yet — use CURRENT
                    // textStorage.length / tv.contentSize.height (refreshed by the
                    // ensureLayout calls) rather than a stale whole-document ratio.
                    let liveH = Double(tv.contentSize.height)
                    let bootstrapDensity = liveH > 0 ? Double(tv.textStorage.length) / liveH : 0
                    dyRaw = bootstrapDensity > 0 ? CGFloat(Double(charDiff) / bootstrapDensity) : 0
                }
                // [3] asymmetric dy clamp — backward (negative dy) is the historically
                // expensive/hang-prone direction (seeking into not-yet-laid-out text).
                let secantDy = dyRaw >= 0 ? min(50_000, dyRaw) : max(-20_000, dyRaw)

                // [4] Exact correction: ask TextKit where the target character's line
                // actually is, instead of extrapolating in pixel space. The secant
                // step oscillated without converging (observed: 8 attempts ending
                // 3,806 chars off on a cold restore) because local density differs
                // ~10x between already-laid-out text (~0.42 chars/pt) and TextKit's
                // estimate for not-yet-laid-out text (~4.5 chars/pt); any two
                // samples straddling that boundary give a garbage slope. The probe
                // is O(local) with non-contiguous layout; it's timed and disabled for
                // the session if it ever proves slow, falling back to the secant.
                var dy = secantDy
                var probeMs = 0.0
                if !charProbeDisabled, abs(charDiff) > 300, tv.textStorage.length > 0 {
                    let _tProbe = CFAbsoluteTimeGetCurrent()
                    let safeIdx = min(max(0, targetCharIdx), tv.textStorage.length - 1)
                    let charRange = NSRange(location: safeIdx, length: 1)
                    lm.ensureLayout(forCharacterRange: charRange)
                    let gRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
                    var probeY: CGFloat?
                    if gRange.location != NSNotFound, gRange.location < lm.numberOfGlyphs {
                        let line = lm.lineFragmentRect(forGlyphAt: gRange.location, effectiveRange: nil,
                                                       withoutAdditionalLayout: true)
                        if line.minY.isFinite, line.height > 0 { probeY = line.minY + inset }
                    }
                    probeMs = (CFAbsoluteTimeGetCurrent() - _tProbe) * 1000
                    if probeMs > 400 {
                        charProbeDisabled = true
                        print("[\(tag)] exact probe took \(Int(probeMs))ms — disabling for this session")
                    }
                    if let probeY { dy = probeY - y }
                }

                let now = CFAbsoluteTimeGetCurrent()
                let elapsedMs = (now - t0) * 1000
                // Budget clock starts when attempt 0 finishes (see doc comment).
                if attempt == 0 { budgetStart = now }
                let budgetMs = (now - budgetStart) * 1000
                print(String(format: "[\(tag)] attempt=%d landed=%.4f diff=%d density=%.4f dy=%.1f secantDy=%.1f probe=%.0fms ensureMs=%.0f stepMs=%.0f elapsed=%.0fms budget=%.0fms",
                             attempt, landedProgress, charDiff, density, Double(dy), Double(secantDy), probeMs, ensureMs, stepMs, elapsedMs, budgetMs))

                // [3] 350ms wall-clock budget for correction attempts (attempt 1+):
                // stop immediately, snap to best below.
                if attempt > 0, budgetMs > wallClockBudgetMs {
                    print("[\(tag)] budget exceeded (\(Int(budgetMs))ms after attempt 0) — stopping, snapping to best")
                    break
                }
                guard abs(charDiff) > 300, attempt < maxAttempts - 1 else { break }

                // Let UITextView sync contentSize with the layout the probe just
                // established before clamping.
                tv.layoutIfNeeded()
                let correctedY = min(max(0, y + dy), currentMaxOffset())
                prevY = y
                prevCharIdx = landedCharIdx
                guard abs(correctedY - y) > 0.5 else {
                    print(String(format: "[\(tag)] correction clamped at maxOffset=%.0f (wanted %.0f) — stopping",
                                 Double(currentMaxOffset()), Double(y + dy)))
                    break
                }
                y = correctedY
            }

            if bestCharIdx != landedCharIdx, bestAbsDiff < abs(targetCharIdx - landedCharIdx) {
                y = bestY
                landedCharIdx = bestCharIdx
                landedProgress = totalChars > 0 ? min(max(Double(bestCharIdx) / Double(totalChars), 0), 1) : 0
                isScrollingProgrammatically = true
                tv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                isScrollingProgrammatically = false
                print(String(format: "[\(tag)] reverted to best charIdx=%d y=%.0f", bestCharIdx, Double(y)))
            }
            print(String(format: "[\(tag)] TOTAL elapsed=%.0fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))

            // Report the FINAL landing. This used to fire after attempt 0, whose
            // proportional guess can be far off (e.g. 0.2% for a 5% target), so the
            // page label was rebased to the wrong page after every seek.
            onLanded?(landedCharIdx, landedProgress)
            return (y, landedCharIdx, landedProgress)
        }

        private func applySeek(_ target: Double, in textView: UITextView, trigger: StaticString = "unknown") {
            guard target != lastAppliedSeekTarget else { return }
            lastAppliedSeekTarget = target
            print(String(format: "[SEEK] trigger=%@ target=%.4f currentOffsetY=%.0f",
                         "\(trigger)" as NSString, target, textView.contentOffset.y))

            // Proportional pixel estimate — the landing loop's setContentOffset+
            // ensureLayout+layoutIfNeeded+glyphRange(forBoundingRect:) steps
            // establish whatever layout is needed for wherever we actually land.
            let tkH = textView.contentSize.height
            guard tkH > textView.bounds.height else { return }
            let maxOffset = tkH - textView.bounds.height
            let rawY = tkH * target
            let targetY = min(max(0, rawY), maxOffset)

            guard abs(textView.contentOffset.y - targetY) > 1 else { return }
            isSeeking = true
            let total = stableCharCount > 0 ? stableCharCount : textView.textStorage.length
            let targetCharIdx = Int(target * Double(max(1, total)))

            // A big jump used to block the main thread for seconds-to-minutes; that
            // was font-attribute fixing, now fixed at the source (see landingLoop's
            // doc comment). The spinner stays as a safety net for any residual
            // stall. TWO nested dispatches, not one: applySeek can run
            // synchronously from within a SwiftUI view-update pass (e.g. a progress-
            // bar drag driving `progress` → syncProgress → applySeek), so setting
            // isPositioning here directly triggers "Publishing changes from within
            // view updates". The first hop moves the flag-set itself outside that
            // update pass; the second hop is what actually gives SwiftUI a render
            // in between to draw the spinner BEFORE the block starts.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.vm?.isPositioning = true
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    // [2] Unified with didLayout's restore loop — same secant method,
                    // same safety guards. Previously applySeek used a fixed cpp/pageStep
                    // ratio (correctionDelta), which is why [SEEK] logs never showed a density.
                    let result = self.landingLoop(tv: textView, startY: targetY, targetCharIdx: targetCharIdx,
                                                  totalChars: total, tag: "SEEK") { charIdx, _ in
                        let capturedVM = self.vm
                        Task { @MainActor in capturedVM?.rebasePage(atCharIdx: charIdx, totalChars: total) }
                        self.postSeekExclude = true
                    }
                    self.vm?.isPositioning = false

                    os_log("[NCL-3] applySeek-done allow=%d has=%d vo=%d target=%.3f offsetY=%.0f",
                       log: spLog, type: .info,
                       textView.layoutManager.allowsNonContiguousLayout ? 1 : 0,
                       textView.layoutManager.hasNonContiguousLayout ? 1 : 0,
                       UIAccessibility.isVoiceOverRunning ? 1 : 0,
                       target, result.y)
                    DispatchQueue.main.async { [weak self] in self?.isSeeking = false }
                }
            }
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

        func scheduleRestore(_ target: Double, in textView: UITextView) {
            cancelRestore()
            pendingRestoreTarget = target
            isRestorePending = true
            lastReportedProgress = nil
            lastAppliedSeekTarget = -1   // reset so the restored position always fires
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
                let capturedTarget = target
                cancelRestore()
                // Proportional pixel estimate — the landing loop's setContentOffset+
                // ensureLayout+layoutIfNeeded+glyphRange(forBoundingRect:) steps
                // establish whatever layout is needed for wherever we actually land.
                let rawY = tkH * capturedTarget
                let totalChars = stableCharCount > 0 ? stableCharCount : tv.textStorage.length
                let targetCharIdx = Int(capturedTarget * Double(max(1, totalChars)))

                // This first restore used to block the main thread for ~3s on a
                // 7.8M-char book. That was font-attribute fixing, not layout — fixed
                // at the source (see landingLoop's doc comment); now ~100ms. The
                // spinner stays as a safety net for any residual stall.
                // TWO nested dispatches, not one: didLayout runs synchronously from
                // within a SwiftUI view-update pass, so setting isPositioning here
                // directly triggers "Publishing changes from within view updates".
                // The first hop moves the flag-set itself outside that update pass;
                // the second hop is what actually gives SwiftUI a render in between
                // to draw the spinner BEFORE the multi-second block starts — doing
                // both in the same hop would still freeze with no visible feedback.
                DispatchQueue.main.async { [weak self, weak tv] in
                    guard let self, let tv else { return }
                    self.vm?.isPositioning = true
                    DispatchQueue.main.async { [weak self, weak tv] in
                        guard let self, let tv else { return }
                        // [2] Unified with applySeek's landing loop — same secant
                        // method, same safety guards (350ms budget, asymmetric dy
                        // clamp, density validity range).
                        _ = self.landingLoop(tv: tv, startY: rawY, targetCharIdx: targetCharIdx,
                                             totalChars: totalChars, tag: "RESTORE")
                        self.vm?.isPositioning = false
                    // Use capturedTarget (= saved charIndex / totalChars) as the
                    // authoritative progress value, not the landed measurement — see
                    // prior Newton-loop-drift note: measuring progress off the CURRENT
                    // pixel position accumulates rounding error across close/open
                    // cycles instead of using the exact value that was saved.
                    self.lastReportedProgress = capturedTarget
                    self.progress = capturedTarget
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
                        // Trigger background pagination now that we know the stable bounds.
                        self.triggerPaginationIfNeeded(tv: tv)
                    }
                }
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
            guard let tv = textView, tv.bounds.width > 0 else { onTap(0.5); return }
            let x = gesture.location(in: tv).x
            onTap(min(max(x / tv.bounds.width, 0), 1))
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
            let lm = tv.layoutManager
            let tc = tv.textContainer

            // Compute pageStep from actual line metrics so scroll distance exactly
            // matches the rendered text area — floor(textAreaH/lineHeight)*lineHeight.
            // Fallback: visible - 80 (legacy behaviour) when settings are unavailable.
            let pageStep: CGFloat = {
                if let s = settings, let v = vm, v.textAreaSize.height > 0 {
                    let fSize = CGFloat(max(1.0, s.fontSize))
                    let lh    = fSize + CGFloat(max(0.0, s.lineSpacing))
                    let lpp   = floor(v.textAreaSize.height / lh)
                    return lpp * lh
                }
                return visible - 80
            }()

            // Page by CHARACTER, not raw pixels: pick the glyph near the bottom
            // of the current view (for forward) and scroll so it sits at the top.
            // That glyph is already laid out, so the offset can't be clamped and
            // we never force a big relayout that would shift the pixel↔char map.
            let base = pageTargetY ?? tv.contentOffset.y
            let refContentY = forward ? base + pageStep : base - pageStep
            let refContainerY = max(0, refContentY - inset)
            // Lay out the region around the reference point (extends only from the
            // current layout frontier downward — content above is untouched), so
            // glyphIndex returns the real glyph instead of a clamped one near the
            // frontier (which would repeat the page).
            let ensureRect = CGRect(x: 0, y: refContainerY, width: tc.size.width, height: pageStep + 80)
            lm.ensureLayout(forBoundingRect: ensureRect, in: tc)
            // BUG (3rd attempt — point/rect hit-testing is inherently ambiguous at line
            // boundaries): both glyphRange(forBoundingRect:) and glyphIndex(for:point:)
            // resolve a boundary point by "nearest" or "overlapping" glyph, which can
            // snap to the PREVIOUS line's trailing glyph when the target Y sits exactly
            // on (or a hair past) that line's lower edge — reproducing the same ~1-line
            // (621pt vs pageStep=648pt) undershoot regardless of which hit-test API is used.
            // Fix: enumerate line fragments directly (same technique BookPaginator uses
            // to place page boundaries) and take the first fragment whose usedRect.minY
            // is at/after refContainerY — no hit-testing, no boundary ambiguity.
            // Bounded to glyphRange(forBoundingRect: ensureRect) so this stays O(local)
            // under NCL instead of forcing full-document layout.
            let boundedGlyphRange = lm.glyphRange(forBoundingRect: ensureRect, in: tc)
            guard boundedGlyphRange.location != NSNotFound, boundedGlyphRange.length > 0 else {
                print(String(format: "[PAGE] forward=%d STALLED no-glyphs-in-range base=%.0f refContainerY=%.0f",
                             forward ? 1 : 0, base, refContainerY))
                return
            }
            var glyphIdx = NSNotFound
            lm.enumerateLineFragments(forGlyphRange: boundedGlyphRange) { _, usedRect, _, glyphRange, stop in
                if glyphIdx == NSNotFound, usedRect.minY >= refContainerY - 0.5 {
                    glyphIdx = glyphRange.location
                    stop.pointee = true
                }
            }
            guard glyphIdx != NSNotFound, glyphIdx < lm.numberOfGlyphs else {
                print(String(format: "[PAGE] forward=%d STALLED glyphIdx-not-found base=%.0f refContainerY=%.0f",
                             forward ? 1 : 0, base, refContainerY))
                return
            }
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
            guard abs(finalTarget - base) > 1 else {
                print(String(format: "[PAGE] forward=%d STALLED no-movement base=%.0f finalTarget=%.0f refContainerY=%.0f maxOffset=%.0f pageStep=%.1f",
                             forward ? 1 : 0, base, finalTarget, refContainerY, maxOffset, pageStep))
                return
            }
            pageTargetY = finalTarget
            let charIdx = pageCharMap[capturedPageIndex] ?? 0
            let total = stableCharCount > 0 ? stableCharCount : tv.textStorage.length
            let pageProgress = total > 0 ? Double(charIdx) / Double(total) : 0
            print(String(format: "[PAGE] forward=%d offsetY=%.0f charIdx=%d progress=%.4f  (%.0f ms)",
                         forward ? 1 : 0, finalTarget, charIdx, pageProgress,
                         (CFAbsoluteTimeGetCurrent() - _pageT0) * 1000))

            // Calibration sample collection — [2] filter: 20–2000 range, median,
            // skip the first turn after any seek so a bad delta doesn't corrupt data.
            if forward, !hasLockedCharsPerPage, let prev = lastPageCharIdx {
                let delta = charIdx - prev
                if !postSeekExclude, delta >= 20, delta <= 2000 {
                    pageCharDeltas.append(delta)
                    if pageCharDeltas.count == 10 {
                        let median = pageCharDeltas.sorted()[5]   // 10 samples → index 5
                        print(String(format: "[PAGE-CAL] 10-sample median charsPerPage=%d  (min=%d max=%d)  key=%@",
                                     median, pageCharDeltas.min()!, pageCharDeltas.max()!,
                                     currentProfileKey as NSString))
                        pageCharDeltas.removeAll()
                        hasLockedCharsPerPage = true    // [3]: lock at most once per session
                        let capturedVM2 = vm
                        Task { @MainActor in capturedVM2?.lockCharsPerPage(median, profileKey: currentProfileKey) }
                    }
                }
                postSeekExclude = false
            }
            lastPageCharIdx = charIdx

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
            let capturedForward = forward
            isScrollingProgrammatically = true
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, capturedPageIndex, capturedForward] in
                guard let self else { return }
                self.isScrollingProgrammatically = false
                self.pageTargetY = nil
                let charIdx = self.pageCharMap.removeValue(forKey: capturedPageIndex)
                self.commitProgress(tv, pageCharIndex: charIdx)
                // Update counter on the committed page (must be on main actor).
                let capturedVM = self.vm
                Task { @MainActor in
                    if capturedForward { capturedVM?.advancePage() } else { capturedVM?.retreatPage() }
                }
            }
            tv.layer.add(transition, forKey: "pageTurn")
            tv.setContentOffset(CGPoint(x: 0, y: finalTarget), animated: false)
            CATransaction.commit()
        }
    }
}
#endif
