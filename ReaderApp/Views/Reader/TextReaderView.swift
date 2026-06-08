import SwiftUI

struct TextReaderView: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var settings: ReadingSettings
    @ObservedObject var tts: TTSManager
    @Binding var showBars: Bool
    @Binding var autoScrolling: Bool
    @Binding var highlightMode: Bool

    private var richBlocks: [ContentBlock] {
        vm.book.format == .epub ? vm.blocks : []
    }

    var body: some View {
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
            onAddHighlight: { range, color, snippet, progress in
                vm.addHighlight(range: range, colorName: color, snippet: snippet, progress: progress)
            },
            progress: $vm.progress,
            spokenRange: tts.spokenRange,
            onTap: { showBars.toggle() }
        )
    }
}

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
    @Binding var autoScrolling: Bool
    var autoScrollSpeed: Double = 40
    var highlightMode: Bool = false
    var highlights: [Highlight] = []
    var onAddHighlight: (NSRange, String, String, Double) -> Void = { _, _, _, _ in }
    @Binding var progress: Double
    var spokenRange: NSRange?
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(progress: $progress, onTap: onTap) }

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
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        applyContent(to: textView)
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
            let maxWidth = textView.bounds.width - 50
            let result = NSMutableAttributedString()
            for block in blocks {
                switch block {
                case .text(let s):
                    result.append(NSAttributedString(string: s + "\n\n", attributes: styleAttrs))
                case .image(let data):
                    if let image = NSImage(data: data) {
                        let attachment = NSTextAttachment()
                        let cell = NSTextAttachmentCell(imageCell: image)
                        attachment.attachmentCell = cell
                        let w = max(1, maxWidth)
                        let scale = min(1, w / max(image.size.width, 1))
                        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
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
        @Binding var progress: Double
        let onTap: () -> Void
        weak var scrollView: NSScrollView?
        var isScrollingProgrammatically = false
        private var lastHighlight: NSRange?

        init(progress: Binding<Double>, onTap: @escaping () -> Void) {
            _progress = progress
            self.onTap = onTap
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
                textView.scrollRangeToVisible(r)
            }
        }

        func scrollToProgress(_ target: Double) {
            guard let sv = scrollView else { return }
            let contentHeight = sv.documentView?.frame.height ?? 0
            let visibleHeight = sv.contentView.bounds.height
            let scrollable = contentHeight - visibleHeight
            guard scrollable > 0 else { return }

            let targetOffset = target * scrollable
            let currentOffset = sv.contentView.bounds.origin.y
            // Only scroll if difference is more than 1pt (avoids feedback loop from user scrolling)
            guard abs(targetOffset - currentOffset) > 1 else { return }

            isScrollingProgrammatically = true
            sv.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
            sv.reflectScrolledClipView(sv.contentView)
            isScrollingProgrammatically = false
        }

        @objc func boundsChanged(_ notification: Notification) {
            guard !isScrollingProgrammatically, let sv = scrollView else { return }
            let contentHeight = sv.documentView?.frame.height ?? 0
            let visibleHeight = sv.contentView.bounds.height
            let scrollable = contentHeight - visibleHeight
            guard scrollable > 0 else { return }
            let offset = sv.contentView.bounds.origin.y
            DispatchQueue.main.async {
                self.progress = max(0, min(offset / scrollable, 1))
            }
        }

        @objc func handleTap(_ recognizer: NSGestureRecognizer) { onTap() }
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
                if storage.length > 0 {
                    let v = min(max(Double(r.location) / Double(storage.length), 0), 1)
                    lastReportedProgress = v
                    progress = v
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
            // Advance ~one screenful, keeping a little overlap for reading continuity.
            let step = max(tv.bounds.height - 90, 120)
            let maxOffset = max(0, tv.contentSize.height - tv.bounds.height)
            // Base on the in-flight target (not the interpolating contentOffset)
            // so a tap during the animation advances instead of repeating the page.
            let base = pageTargetY ?? tv.contentOffset.y
            let target = min(max(0, base + (forward ? step : -step)), maxOffset)
            guard abs(target - base) > 1 else { return }
            pageTargetY = target

            // Set the offset INSTANTLY (never animated) so a growing contentSize
            // from lazy TextKit layout can't cancel the scroll and revert the
            // page. The motion is supplied by a CATransition on the layer.
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
            tv.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            CATransaction.commit()
        }
    }
}
#endif
