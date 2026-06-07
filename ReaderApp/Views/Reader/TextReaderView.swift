import SwiftUI

struct TextReaderView: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var settings: ReadingSettings
    @ObservedObject var tts: TTSManager
    @Binding var showBars: Bool

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
    @Binding var progress: Double
    var spokenRange: NSRange?
    let onTap: () -> Void

    // Above this length we skip the per-character paragraph-style pass,
    // since addAttributes over the whole storage forces a synchronous
    // full-document layout that freezes the UI on open.
    private static let paragraphStyleLimit = 200_000

    func makeCoordinator() -> Coordinator { Coordinator(progress: $progress, onTap: onTap) }

    func makeUIView(context: Context) -> UITextView {
        // A natively scrolling UITextView lays out text lazily via TextKit,
        // so it handles multi-million-character documents and scrolls smoothly.
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 60, left: 20, bottom: 60, right: 20)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.pageEffect = pageEffect
        // Only restyle when text/style actually change — never on the frequent
        // progress updates that scrolling produces.
        let styleKey = "\(embeddedFontName ?? settings.fontName)|\(settings.fontSize)|\(settings.lineSpacing)|\(settings.presetId)"
        let contentKey: String = {
            if !blocks.isEmpty { return "blocks-\(blocks.count)" }
            return text.map { "txt-\($0.count)" }
                ?? "attr-\(attributedText.map { NSAttributedString($0).length } ?? 0)"
        }()

        if context.coordinator.lastStyleKey != styleKey || context.coordinator.lastContentKey != contentKey {
            applyContent(to: textView)
            textView.backgroundColor = UIColor(settings.currentPreset.background)
            context.coordinator.lastStyleKey = styleKey
            context.coordinator.lastContentKey = contentKey
        }

        // Sync scroll to progress (initial restore + seeking from the progress bar).
        // Defer once so content layout has settled and contentSize is valid.
        let target = progress
        context.coordinator.syncProgress(target, in: textView)
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.syncProgress(target, in: textView)
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
    }

    class Coordinator: NSObject, UITextViewDelegate {
        @Binding var progress: Double
        let onTap: () -> Void
        weak var textView: UITextView?
        var isScrollingProgrammatically = false
        var lastStyleKey = ""
        var lastContentKey = ""
        private var lastReportedProgress: Double?   // last value WE pushed from scrolling
        private var lastHighlight: NSRange?
        var pageEffect: PageEffect = .verticalSlide

        init(progress: Binding<Double>, onTap: @escaping () -> Void) {
            _progress = progress
            self.onTap = onTap
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
            }
        }

        private func sameRange(_ a: NSRange?, _ b: NSRange?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return NSEqualRanges(x, y)
            default: return false
            }
        }

        // Scroll the text to match an externally-set progress value — used for
        // the initial position restore and for seeking via the progress bar.
        // Skips changes that originated from our own scroll reporting so it
        // never fights the user's manual scrolling.
        func syncProgress(_ target: Double, in textView: UITextView) {
            let scrollable = textView.contentSize.height - textView.bounds.height
            guard scrollable > 0 else { return }   // not laid out yet
            // This value came from our own scroll → don't bounce back
            if let lr = lastReportedProgress, abs(lr - target) < 0.0015 { return }
            let current = textView.contentOffset.y / scrollable
            guard abs(current - target) > 0.003 else { return }
            isScrollingProgrammatically = true
            textView.setContentOffset(CGPoint(x: 0, y: target * scrollable), animated: false)
            isScrollingProgrammatically = false
        }

        // Update progress only when scrolling settles — writing the binding on
        // every frame re-renders the SwiftUI tree mid-scroll and causes jitter.
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
            commitProgress(scrollView)
        }

        private func commitProgress(_ scrollView: UIScrollView) {
            guard !isScrollingProgrammatically else { return }
            let scrollable = scrollView.contentSize.height - scrollView.bounds.height
            guard scrollable > 0 else { return }
            let value = max(0, min(scrollView.contentOffset.y / scrollable, 1))
            lastReportedProgress = value   // remember so syncProgress won't bounce back
            progress = value
        }

        // Tap zones: left third = page back, right third = page forward, middle = toggle bars.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let tv = textView, tv.bounds.width > 0 else { onTap(); return }
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

        private func page(_ tv: UITextView, forward: Bool) {
            // Advance ~one screenful, keeping a little overlap for reading continuity.
            let step = max(tv.bounds.height - 90, 120)
            let maxOffset = max(0, tv.contentSize.height - tv.bounds.height)
            let target = min(max(0, tv.contentOffset.y + (forward ? step : -step)), maxOffset)
            guard abs(target - tv.contentOffset.y) > 1 else { return }

            switch pageEffect {
            case .verticalSlide:
                isScrollingProgrammatically = true   // cleared in didEndScrollingAnimation
                tv.setContentOffset(CGPoint(x: 0, y: target), animated: true)

            case .paper:
                // Horizontal page turn (right-to-left for forward): the new page
                // pushes in from the right while the old page slides off left.
                isScrollingProgrammatically = true
                let transition = CATransition()
                transition.duration = 0.4
                transition.type = .push
                transition.subtype = forward ? .fromRight : .fromLeft
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                CATransaction.begin()
                CATransaction.setCompletionBlock {
                    self.isScrollingProgrammatically = false
                    self.commitProgress(tv)
                }
                tv.layer.add(transition, forKey: "pageTurn")
                tv.contentOffset = CGPoint(x: 0, y: target)
                CATransaction.commit()
            }
        }
    }
}
#endif
