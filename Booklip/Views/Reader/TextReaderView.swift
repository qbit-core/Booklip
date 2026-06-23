import SwiftUI
import Combine

struct TextReaderView: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var settings: ReadingSettings
    @ObservedObject var tts: TTSManager
    @Binding var showBars: Bool
    @Binding var autoScrolling: Bool
    @Binding var highlightMode: Bool
    @StateObject private var pageLayout = PageStepState()
    // Reference-type channel for scroll-position and tap events from the primary
    // coordinator. The coordinator holds only a weak reference to this object, so it
    // can never crash — if the view is dismantled before the coordinator is released
    // (via AppKit's gesture-recognizer retain chain), writes just become no-ops.
#if os(macOS)
    @StateObject private var eventChannel = TextViewEventChannel()
#endif

    private var richBlocks: [ContentBlock] {
        vm.book.format == .epub ? vm.blocks : []
    }

    var body: some View {
#if os(macOS)
        Group {
            if settings.pageColumns == 2 {
                HStack(spacing: 0) {
                    nativeTextView(progress: vm.progress, isPrimary: true)
                    Divider()
                    nativeTextView(progress: min(vm.progress + pageLayout.value, 1.0),
                                   isPrimary: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                nativeTextView(progress: vm.progress, isPrimary: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Propagate coordinator scroll events → model. .dropFirst() skips the
        // initial zero emission so we never override a book's saved progress.
        .onReceive(eventChannel.$scrollProgress.dropFirst()) { vm.progress = $0 }
        .onReceive(eventChannel.$tapCount.dropFirst()) { _ in showBars.toggle() }
#else
        nativeTextView(progress: $vm.progress, isPrimary: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
    }

#if os(macOS)
    private func nativeTextView(progress: Double, isPrimary: Bool) -> NativeTextView {
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
            eventChannel: isPrimary ? eventChannel : nil,
            pageColumns: settings.pageColumns,
            // Both columns receive pageLayout: secondary reads .scrollable to
            // position itself; primary is the only one that writes it (guarded
            // by isPrimary inside updatePageStep).
            pageLayout: pageLayout,
            isPrimary: isPrimary
        )
    }
#else
    private func nativeTextView(progress: Binding<Double>, isPrimary: Bool) -> NativeTextView {
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
            onTap: { showBars.toggle() },
            pageColumns: settings.pageColumns,
            pageLayout: isPrimary ? pageLayout : nil,
            isPrimary: isPrimary
        )
    }
#endif
}

// Reference-type channels for coordinator → SwiftUI communication on macOS.
// The coordinator holds only weak references to these objects. If the view is
// dismantled before the coordinator is finally released (e.g. via AppKit's
// gesture-recognizer retain chain), writes become safe no-ops instead of crashing.
final class PageStepState: ObservableObject {
    @Published var value: Double = 0
    // Primary's scrollable pixel range; set before value so it is readable in the
    // re-render that value triggers. Not @Published — no extra re-render needed.
    var scrollable: CGFloat = 0
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
    // Coordinator communicates scroll position and taps back to SwiftUI via this
    // channel. Using a weak reference in the coordinator means the coordinator can
    // never crash accessing freed SwiftUI backing stores, regardless of teardown order.
    var eventChannel: TextViewEventChannel? = nil
    var pageColumns: Int = 1
    var pageLayout: PageStepState? = nil
    var isPrimary: Bool = true

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(pageColumns: pageColumns, isPrimary: isPrimary)
        c.pageLayout = pageLayout
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
        if isPrimary {
            // didLiveScrollNotification fires only on user-initiated gestures — never
            // from programmatic scrolls inside updateNSView, so writing bindings is safe.
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.didLiveScroll),
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
            context.coordinator.installKeyMonitor()
            if pageColumns > 1 {
                // Observe the CLIP VIEW's frame changes (window layout, resize) so we can
                // compute pageStep once the visible height is known. Safe: NSClipView does
                // not fire frameDidChangeNotification during NSTextView deallocation.
                scrollView.contentView.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    context.coordinator,
                    selector: #selector(Coordinator.clipViewFrameChanged),
                    name: NSView.frameDidChangeNotification,
                    object: scrollView.contentView
                )
            }
        }
        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.isDismantled = true
        coordinator.removeKeyMonitor()
        NotificationCenter.default.removeObserver(coordinator)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView

        // Only rebuild content when text/style/highlights actually change — never on
        // the frequent progress updates that scrolling produces.  Rebuilding the full
        // attributed string on every SwiftUI tick blocks the main thread and creates a
        // layout loop that prevents text from ever painting.
        let styleKey = "\(embeddedFontName ?? settings.fontName)|\(settings.fontSize)|\(settings.lineSpacing)|\(settings.presetId)|hl\(highlights.count)"
        let contentKey: String = {
            if !blocks.isEmpty {
                // Include a coarse width bucket so images are re-scaled when
                // the window is resized after the initial (zero-width) render.
                let bucket = (Int(textView.bounds.width) / 50) * 50
                return "blocks-\(blocks.count)-w\(bucket)"
            }
            return text.map { "txt-\($0.count)" }
                ?? "attr-\(attributedText.map { NSAttributedString($0).length } ?? 0)"
        }()
        if context.coordinator.lastStyleKey != styleKey
            || context.coordinator.lastContentKey != contentKey {
            // Wrap in a local pool so that NSTextStorage / NSLayoutManager internal
            // arrays (attribute runs, glyph tables) that AppKit autoreleases during
            // setAttributedString / addAttributes / sizeToFit are drained HERE —
            // while NSFont, NSColor, NSTextAttachment, etc. are still retained by
            // the new text storage. Without this, those arrays linger in the main
            // run-loop pool; when the window closes, NSTextStorage is freed first
            // (releasing the objects), and the pool drain later tries to release them
            // a second time → EXC_BAD_ACCESS in objc_release / NSArrayM.dealloc.
            autoreleasepool {
                applyContent(to: textView)
                // In double-page mode, force a synchronous layout so scrollToProgress
                // below sees the correct content height for both columns.
                if pageColumns > 1 { textView.sizeToFit() }
            }
            context.coordinator.lastStyleKey = styleKey
            context.coordinator.lastContentKey = contentKey
        }

        // Scroll to progress if it was changed externally (e.g. dragging the progress bar)
        context.coordinator.scrollToProgress(progress)
        let highlight = NSColor(settings.currentPreset.text).withAlphaComponent(0.18)
        context.coordinator.updateHighlight(spokenRange, in: textView, color: highlight)
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
                return (NSScreen.main?.frame.width ?? 800) - 80
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

        if let attr = attributedText {
            let str = NSAttributedString(attr).string
            if textView.string != str {
                textView.textStorage?.setAttributedString(NSAttributedString(attr))
            }
        } else if let str = text, textView.string != str {
            textView.textStorage?.setAttributedString(NSAttributedString(string: str))
        }

        // Always re-apply style attributes so font/color/spacing changes take effect
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes(styleAttrs, range: NSRange(location: 0, length: storage.length))
            for h in highlights where NSMaxRange(h.range) <= storage.length {
                storage.addAttribute(.backgroundColor,
                                     value: NSColor(HighlightColor(rawValue: h.colorName)?.color ?? .yellow).withAlphaComponent(0.4),
                                     range: h.range)
            }
        }
        textView.backgroundColor = NSColor(settings.currentPreset.background)
    }

    class Coordinator: NSObject {
        // Weak references only — coordinator can outlive the SwiftUI view hierarchy
        // (AppKit retains it via the gesture recognizer on NSTextView). Using weak
        // references means all writes become no-ops after the view is dismantled,
        // regardless of teardown order. No closures, no @Binding captures.
        weak var eventChannel: TextViewEventChannel?
        weak var pageLayout: PageStepState?
        var pageColumns: Int
        let isPrimary: Bool
        weak var scrollView: NSScrollView?
        var isScrollingProgrammatically = false
        var isDismantled = false
        private var lastHighlight: NSRange?
        var lastStyleKey = ""
        var lastContentKey = ""
        private var keyMonitor: Any?

        init(pageColumns: Int, isPrimary: Bool) {
            self.pageColumns = pageColumns
            self.isPrimary = isPrimary
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
            // In double-page mode advance two pages at once so the spread turns together.
            let step = CGFloat(pageColumns) * pageHeight
            let target = max(0, min(current + CGFloat(direction) * step, scrollable))
            guard abs(target - current) > 1 else { return }
            isScrollingProgrammatically = true
            sv.contentView.scroll(to: NSPoint(x: 0, y: target))
            sv.reflectScrolledClipView(sv.contentView)
            isScrollingProgrammatically = false
            let capturedScrollable = scrollable
            let capturedPageHeight = pageHeight
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDismantled else { return }
                self.eventChannel?.scrollProgress = target / capturedScrollable
                self.updatePageStep(scrollable: capturedScrollable, pageHeight: capturedPageHeight)
            }
        }

        func updateHighlight(_ range: NSRange?, in textView: NSTextView, color: NSColor) {
            if let a = range, let b = lastHighlight, NSEqualRanges(a, b) { return }
            if range == nil && lastHighlight == nil { return }
            guard let storage = textView.textStorage else { return }
            if let old = lastHighlight, NSMaxRange(old) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: old)
            }
            lastHighlight = range
            if let r = range, NSMaxRange(r) <= storage.length {
                storage.addAttribute(.backgroundColor, value: color, range: r)
                // Guard the scroll so boundsChanged doesn't fire during updateNSView.
                isScrollingProgrammatically = true
                textView.scrollRangeToVisible(r)
                isScrollingProgrammatically = false
            }
        }

        func scrollToProgress(_ target: Double) {
            guard let sv = scrollView else { return }

            // Secondary column: use the primary's pre-computed scrollable range so
            // the right page is shown even before the secondary's own NSTextView has
            // finished its asynchronous layout (at which point bounds.height may
            // still be 0, making a content-height calculation useless).
            let scrollable: CGFloat
            if !isPrimary, let layout = pageLayout, layout.scrollable > 0 {
                scrollable = layout.scrollable
            } else {
                let contentHeight = sv.documentView?.frame.height ?? 0
                let visibleHeight = sv.contentView.bounds.height
                let s = contentHeight - visibleHeight
                if s > 0 {
                    let h = visibleHeight
                    RunLoop.main.perform { [weak self] in self?.updatePageStep(scrollable: s, pageHeight: h) }
                }
                guard s > 0 else { return }
                scrollable = s
            }

            let targetOffset = target * scrollable
            let currentOffset = sv.contentView.bounds.origin.y
            guard abs(targetOffset - currentOffset) > 1 else { return }

            isScrollingProgrammatically = true
            sv.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
            sv.reflectScrolledClipView(sv.contentView)
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
            updatePageStep(scrollable: scrollable, pageHeight: visibleHeight)
        }

        private func updatePageStep(scrollable: CGFloat, pageHeight: CGFloat) {
            guard isPrimary, pageColumns > 1, scrollable > 0 else { return }
            // Store scrollable before publishing value so the secondary column can
            // read it in the SwiftUI re-render that value triggers.
            pageLayout?.scrollable = scrollable
            let newStep = Double(pageHeight / scrollable)
            if abs(newStep - (pageLayout?.value ?? 0)) > 0.001 {
                pageLayout?.value = newStep
            }
        }

        @objc func clipViewFrameChanged(_ notification: Notification) {
            guard !isDismantled, isPrimary, pageColumns > 1 else { return }
            guard let sv = scrollView else { return }
            let contentHeight = sv.documentView?.frame.height ?? 0
            let visibleHeight = sv.contentView.bounds.height
            let scrollable = contentHeight - visibleHeight
            guard scrollable > 0 else { return }
            let s = scrollable, h = visibleHeight
            RunLoop.main.perform { [weak self] in self?.updatePageStep(scrollable: s, pageHeight: h) }
        }

        @objc func handleTap(_ recognizer: NSGestureRecognizer) { eventChannel?.tapCount += 1 }
    }
}

// MARK: - iOS

#else
import UIKit

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
    let onTap: () -> Void
    var pageColumns: Int = 1
    var pageLayout: PageStepState? = nil
    var isPrimary: Bool = true

    // Above this length we skip the per-character paragraph-style pass,
    // since addAttributes over the whole storage forces a synchronous
    // full-document layout that freezes the UI on open.
    private static let paragraphStyleLimit = 200_000

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, autoScrolling: $autoScrolling, onTap: onTap)
    }

    func makeUIView(context: Context) -> UITextView {
        // Force TextKit 1 (accessing layoutManager opts out of TextKit 2),
        // which scrolls very large documents more smoothly and avoids the
        // relayout jank seen when returning from the background.
        let textView = UITextView(usingTextLayoutManager: false)
        _ = textView.layoutManager
        textView.isEditable = false
        textView.isSelectable = false      // reading view: no text selection (fixes tap-selects-text)
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 60, left: 20, bottom: 60, right: 20)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        textView.addGestureRecognizer(tap)

        // Horizontal swipes page the same way as the tap zones.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleSwipe(_:)))
            swipe.direction = direction
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
        // In highlight mode allow text selection (so the user can pick a range);
        // otherwise selection stays off so taps drive paging.
        textView.isSelectable = highlightMode
        // Paper mode: navigation is tap/swipe only — block free-scroll gestures.
        // Programmatic setContentOffset in page() still works when isScrollEnabled=false.
        textView.isScrollEnabled = pageEffect != .paper

        // Only restyle when text/style/highlights actually change — never on the
        // frequent progress updates that scrolling produces.
        let styleKey = "\(embeddedFontName ?? settings.fontName)|\(settings.fontSize)|\(settings.lineSpacing)|\(settings.presetId)|hl\(highlights.count)"
        let contentKey: String = {
            if !blocks.isEmpty { return "blocks-\(blocks.count)" }
            return text.map { "txt-\($0.count)" }
                ?? "attr-\(attributedText.map { NSAttributedString($0).length } ?? 0)"
        }()

        let contentChanged = context.coordinator.lastStyleKey != styleKey
            || context.coordinator.lastContentKey != contentKey
        if contentChanged {
            applyContent(to: textView)
            textView.backgroundColor = UIColor(settings.currentPreset.background)
            context.coordinator.lastStyleKey = styleKey
            context.coordinator.lastContentKey = contentKey
        }

        if contentChanged {
            // Content was (re)built — restore to the current/saved position,
            // retrying until the text view is actually laid out.
            context.coordinator.scheduleRestore(progress, in: textView)
        } else {
            // Only progress changed (e.g. dragging the bar) — seek there.
            context.coordinator.syncProgress(progress, in: textView)
        }

        // TTS highlight + auto-scroll
        let highlight = UIColor(settings.currentPreset.text).withAlphaComponent(0.18)
        context.coordinator.updateHighlight(spokenRange, in: textView, color: highlight)
    }

    private func applyContent(to textView: UITextView) {
        let fontName = embeddedFontName ?? settings.fontName
        let font = UIFont(name: fontName, size: settings.fontSize)
            ?? UIFont.systemFont(ofSize: settings.fontSize)
        let color = UIColor(settings.currentPreset.text)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = settings.lineSpacing

        // EPUB with images: build a rich NSAttributedString from blocks
        if !blocks.isEmpty {
            // textView may not be laid out yet → fall back to the screen width
            let insets = textView.textContainerInset.left + textView.textContainerInset.right + 10
            let laidOutWidth = textView.bounds.width - insets
            let available = laidOutWidth > 50 ? laidOutWidth
                : (UIScreen.main.bounds.width - 40)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle
            ]
            var imageCount = 0, decoded = 0
            let result = NSMutableAttributedString()
            for block in blocks {
                switch block {
                case .text(let s):
                    result.append(NSAttributedString(string: s + "\n\n", attributes: attrs))
                case .image(let data):
                    imageCount += 1
                    if let image = UIImage(data: data) {
                        decoded += 1
                        let attachment = NSTextAttachment()
                        attachment.image = image
                        let scale = min(1, available / max(image.size.width, 1))
                        attachment.bounds = CGRect(x: 0, y: 0,
                                                   width: image.size.width * scale,
                                                   height: image.size.height * scale)
                        result.append(NSAttributedString(attachment: attachment))
                        result.append(NSAttributedString(string: "\n\n", attributes: attrs))
                    }
                }
            }
            print("[EPUB] render: \(blocks.count) blocks, \(imageCount) images, \(decoded) decoded, width=\(available)")
            textView.attributedText = result
            applyHighlights(to: textView)
            return
        }

        if let attr = attributedText {
            textView.attributedText = NSAttributedString(attr)
        } else if let str = text {
            textView.text = str
        }
        // Cheap, lazy — applies as default attributes without full relayout
        textView.font = font
        textView.textColor = color

        // Line spacing needs an attribute pass — affordable only for smaller docs
        let storage = textView.textStorage
        if storage.length > 0, storage.length <= Self.paragraphStyleLimit, settings.lineSpacing > 0 {
            storage.addAttribute(.paragraphStyle, value: paragraphStyle,
                                 range: NSRange(location: 0, length: storage.length))
        }
        applyHighlights(to: textView)
    }

    private func applyHighlights(to textView: UITextView) {
        let storage = textView.textStorage
        for h in highlights where NSMaxRange(h.range) <= storage.length {
            let color = UIColor(HighlightColor(rawValue: h.colorName)?.color ?? .yellow).withAlphaComponent(0.4)
            storage.addAttribute(.backgroundColor, value: color, range: h.range)
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        @Binding var progress: Double
        @Binding var autoScrolling: Bool
        let onTap: () -> Void
        weak var textView: UITextView?
        var isScrollingProgrammatically = false
        var lastStyleKey = ""
        var lastContentKey = ""
        private var lastReportedProgress: Double?   // last value WE pushed from scrolling
        private var lastHighlight: NSRange?
        var pageEffect: PageEffect = .verticalSlide

        // Auto-scroll
        var autoScrollSpeed: Double = 40            // points per second
        private var displayLink: CADisplayLink?
        private var autoScrollAccumulator: CFTimeInterval = 0

        // Highlights
        var highlightMode = false
        var onAddHighlight: (NSRange, String, String, Double) -> Void = { _, _, _, _ in }

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
            // Clear previous highlight
            if let old = lastHighlight, NSMaxRange(old) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: old)
            }
            lastHighlight = range
            // Apply new highlight + scroll it into view
            if let r = range, NSMaxRange(r) <= storage.length {
                storage.addAttribute(.backgroundColor, value: color, range: r)
                isScrollingProgrammatically = true
                textView.scrollRangeToVisible(r)
                isScrollingProgrammatically = false
                // Follow TTS with the progress bar so closing saves the spoken
                // position (and reopening + play resumes from there).
                // Defer the write so it never fires inside updateUIView.
                if storage.length > 0 {
                    let v = min(max(Double(r.location) / Double(storage.length), 0), 1)
                    lastReportedProgress = v
                    DispatchQueue.main.async { [weak self] in self?.progress = v }
                }
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
        func syncProgress(_ target: Double, in textView: UITextView) {
            guard pendingRestore == nil else { return }   // initial restore wins
            guard textView.bounds.width > 0, textView.textStorage.length > 0 else { return }
            if let lr = lastReportedProgress, abs(lr - target) < 0.0015 { return }
            guard abs(charProgress(textView) - target) > 0.003 else { return }
            // Compute the target offset first — boundingRect forces TextKit to lay
            // out up to that glyph, so contentSize is accurate before we clamp.
            let y = offsetForCharProgress(target, in: textView)
            let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
            let clamped = min(max(0, y), maxOffset)
            isScrollingProgrammatically = true
            textView.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
            isScrollingProgrammatically = false
        }

        // Restore to a saved position, retrying until the text view is laid out
        // (on first open the view often has no size / contentSize yet).
        private var pendingRestore: Double?
        func scheduleRestore(_ target: Double, in textView: UITextView) {
            pendingRestore = target
            attemptRestore(in: textView, retries: 20)
        }

        private func attemptRestore(in tv: UITextView, retries: Int) {
            guard let target = pendingRestore else { return }
            let ready = tv.bounds.width > 0 && tv.textStorage.length > 0
            if ready {
                let y = offsetForCharProgress(target, in: tv)   // forces layout to target
                let maxOffset = max(0, tv.contentSize.height - tv.bounds.height)
                // If we want a non-top position but content isn't tall enough yet,
                // layout hasn't caught up — retry shortly.
                if target > 0.001, maxOffset < 1, retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                        self?.attemptRestore(in: tv, retries: retries - 1)
                    }
                    return
                }
                let clamped = min(max(0, y), maxOffset)
                isScrollingProgrammatically = true
                tv.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
                isScrollingProgrammatically = false

                // The offset can be reset to 0 by a layout pass that runs right
                // after updateUIView; if it didn't stick, retry next runloop.
                if abs(tv.contentOffset.y - clamped) > 10, retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.attemptRestore(in: tv, retries: retries - 1)
                    }
                    return
                }
                lastReportedProgress = target
                pendingRestore = nil
            } else if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.attemptRestore(in: tv, retries: retries - 1)
                }
            } else {
                pendingRestore = nil
            }
        }

        // Update progress only when scrolling settles — writing the binding on
        // every frame re-renders the SwiftUI tree mid-scroll and causes jitter.
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            pageTargetY = nil      // user took over; forget any queued page target
            pendingRestore = nil   // and cancel any in-flight position restore
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
            let value = charProgress(tv)
            lastReportedProgress = value   // remember so syncProgress won't bounce back
            progress = value
        }

        // Tap zones: left third = page back, right third = page forward, middle = toggle bars.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let tv = textView, tv.bounds.width > 0 else { onTap(); return }
            if highlightMode { onTap(); return }   // let selection work; don't page
            let x = gesture.location(in: tv).x
            let w = tv.bounds.width
            if x < w * 0.30 {
                page(tv, forward: false)
            } else if x > w * 0.70 {
                page(tv, forward: true)
            } else {
                onTap()
            }
        }

        // Swipe right = page forward (like tapping the right), swipe left = back.
        @objc func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
            guard let tv = textView, tv.bounds.width > 0, !highlightMode else { return }
            switch gesture.direction {
            case .right: page(tv, forward: true)
            case .left:  page(tv, forward: false)
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

        private func page(_ tv: UITextView, forward: Bool) {
            pendingRestore = nil   // user is navigating — don't let restore reset it
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
                transition.subtype = forward ? .fromBottom : .fromTop
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
