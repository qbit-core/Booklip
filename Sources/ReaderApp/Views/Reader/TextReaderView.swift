import SwiftUI

struct TextReaderView: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var settings: ReadingSettings
    @Binding var showBars: Bool
    @ObservedObject var tts: TTSManager
    // feature 1 & 2: page navigation command from ReaderView
    @Binding var pageNavigationDirection: Int
    // feature 10: search query from ReaderView
    let searchQuery: String
    // feature 9: expose current text selection so ReaderView can create highlights
    @Binding var selectedRange: NSRange?

    var body: some View {
        NativeTextView(
            text: vm.book.format == .markdown ? nil : vm.plainText,
            attributedText: vm.book.format == .markdown ? vm.attributedText : nil,
            contentVersion: vm.contentVersion,
            settings: settings,
            progress: $vm.progress,
            onTap: { showBars.toggle() },
            ttsHighlightRange: tts.highlightRange,
            userHighlights: vm.highlights,
            displayMode: settings.displayMode,
            pageNavigationDirection: $pageNavigationDirection,
            searchQuery: searchQuery,
            selectedRange: $selectedRange
        )
    }
}

// MARK: - macOS

#if os(macOS)
import AppKit

struct NativeTextView: NSViewRepresentable {
    let text: String?
    let attributedText: AttributedString?
    let contentVersion: Int
    let settings: ReadingSettings
    @Binding var progress: Double
    let onTap: () -> Void
    let ttsHighlightRange: NSRange?
    let userHighlights: [BookHighlight]
    let displayMode: ReaderDisplayMode
    @Binding var pageNavigationDirection: Int
    let searchQuery: String
    @Binding var selectedRange: NSRange?

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, onTap: onTap,
                    navigationDirection: $pageNavigationDirection,
                    selectedRange: $selectedRange)
    }

    // Clear text content and remove the bounds observer before SwiftUI releases
    // the view hierarchy. NSLayoutManager with a large glyph store (≥1M chars)
    // walks NSTextContainer→NSTextView back-pointers during dealloc, producing
    // an extra retain/release that corrupts the NSView refcount and triggers the
    // "reached dealloc but still has a super view" assertion.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        storage.endEditing()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 60)
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        let recognizer = NSClickGestureRecognizer(target: context.coordinator,
                                                  action: #selector(Coordinator.handleTap))
        recognizer.numberOfClicksRequired = 1
        textView.addGestureRecognizer(recognizer)
        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
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
        context.coordinator.displayMode = displayMode

        let contentChanged = contentVersion != context.coordinator.appliedContentVersion
        applyContent(to: textView, contentChanged: contentChanged)
        applyHighlights(to: textView)
        if contentChanged {
            context.coordinator.appliedContentVersion = contentVersion
        }

        // Defer all layout-forcing operations out of the SwiftUI update cycle.
        // updateNSView is called during SwiftUI's own layout pass; accessing
        // frame.height or calling scroll(to:) synchronously here triggers AppKit's
        // -layoutSubtreeIfNeeded inside an already-in-progress layout, which corrupts
        // NSView retain counts and causes the "reached dealloc with superview" crash.
        let coordinator = context.coordinator
        let targetProgress = progress
        let dir = pageNavigationDirection
        let query = searchQuery
        let skipScroll = contentChanged
        DispatchQueue.main.async { [weak coordinator] in
            guard let coordinator else { return }
            // feature 1 & 2: handle page navigation
            if dir != 0 {
                coordinator.navigatePage(direction: dir, in: scrollView)
                DispatchQueue.main.async { self.pageNavigationDirection = 0 }
            }
            // Skip scroll restore on the pass where content was just set.
            if !skipScroll {
                coordinator.scrollToProgress(targetProgress)
            }
            // feature 10: scroll to first search match
            if !query.isEmpty {
                coordinator.scrollToSearch(query: query, in: scrollView, textView: textView)
            }
        }
    }

    // Apply font/color/spacing and text content.
    // contentChanged=true means we must replace the string; false means only re-style.
    private func applyContent(to textView: NSTextView, contentChanged: Bool) {
        guard let storage = textView.textStorage else { return }
        let font = NSFont(name: settings.fontName, size: settings.fontSize)
            ?? NSFont.systemFont(ofSize: settings.fontSize)
        let color = NSColor(settings.currentPreset.text)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = settings.lineSpacing
        let styleAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle
        ]

        // Batch all mutations so NSLayoutManager receives a single processEditing call.
        storage.beginEditing()

        if contentChanged {
            if let attr = attributedText {
                // Markdown: replace with attributed content
                let nsAttr = NSAttributedString(attr)
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                          with: nsAttr)
            } else if let str = text {
                // Plain / EPUB text: replaceCharacters copies into NSTextStorage's own
                // buffer, breaking Swift COW buffer sharing that caused the autorelease
                // pool crash when the Swift String was freed while NSLayoutManager still
                // held an interior pointer via the bridged NSString.
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                          with: str)
            }
        }

        if storage.length > 0 {
            storage.setAttributes(styleAttrs, range: NSRange(location: 0, length: storage.length))
        }
        textView.backgroundColor = NSColor(settings.currentPreset.background)

        storage.endEditing()
    }

    // feature 5 & 9: apply user highlights (yellow) and TTS sentence highlight (blue)
    private func applyHighlights(to textView: NSTextView) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        storage.beginEditing()
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: full)

        for h in userHighlights {
            let r = NSRange(location: h.startOffset, length: h.length)
            guard NSMaxRange(r) <= storage.length else { continue }
            storage.addAttribute(.backgroundColor,
                                 value: NSColor.systemYellow.withAlphaComponent(0.45), range: r)
        }
        if let tts = ttsHighlightRange {
            let loc = min(tts.location, storage.length)
            let len = min(tts.length, storage.length - loc)
            if len > 0 {
                storage.addAttribute(.backgroundColor,
                                     value: NSColor.systemBlue.withAlphaComponent(0.25),
                                     range: NSRange(location: loc, length: len))
            }
        }
        storage.endEditing()
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var progress: Double
        @Binding var navigationDirection: Int
        @Binding var selectedRange: NSRange?
        let onTap: () -> Void
        var displayMode: ReaderDisplayMode = .scroll
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var isScrollingProgrammatically = false
        private var lastSearchQuery = ""
        // Tracks which contentVersion has been written into NSTextStorage so we avoid
        // O(n) string comparison and skip scrollToProgress until layout is ready.
        var appliedContentVersion: Int = -1

        init(progress: Binding<Double>, onTap: @escaping () -> Void,
             navigationDirection: Binding<Int>, selectedRange: Binding<NSRange?>) {
            _progress = progress
            _navigationDirection = navigationDirection
            _selectedRange = selectedRange
            self.onTap = onTap
        }

        func scrollToProgress(_ target: Double) {
            guard let sv = scrollView else { return }
            let contentHeight = sv.documentView?.frame.height ?? 0
            let visibleHeight = sv.contentView.bounds.height
            let scrollable = contentHeight - visibleHeight
            guard scrollable > 0 else { return }
            let targetOffset = target * scrollable
            let currentOffset = sv.contentView.bounds.origin.y
            guard abs(targetOffset - currentOffset) > 1 else { return }
            isScrollingProgrammatically = true
            sv.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
            sv.reflectScrolledClipView(sv.contentView)
            isScrollingProgrammatically = false
        }

        // feature 1: advance or retreat by one screen height
        func navigatePage(direction: Int, in scrollView: NSScrollView) {
            let pageHeight = scrollView.contentView.bounds.height
            let contentHeight = scrollView.documentView?.frame.height ?? 0
            let scrollable = contentHeight - pageHeight
            guard scrollable > 0 else { return }
            let current = scrollView.contentView.bounds.origin.y
            let target = max(0, min(current + CGFloat(direction) * pageHeight, scrollable))
            isScrollingProgrammatically = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isScrollingProgrammatically = false
            progress = target / scrollable
        }

        @objc func boundsChanged(_ notification: Notification) {
            guard !isScrollingProgrammatically, let sv = scrollView else { return }
            let contentHeight = sv.documentView?.frame.height ?? 0
            let visibleHeight = sv.contentView.bounds.height
            let scrollable = contentHeight - visibleHeight
            guard scrollable > 0 else { return }

            // feature 2: in paper mode snap back to page boundaries on scroll
            let offset = sv.contentView.bounds.origin.y
            if displayMode == .paper {
                let pageIndex = round(offset / visibleHeight)
                let snapped = pageIndex * visibleHeight
                if abs(offset - snapped) > 4 {
                    isScrollingProgrammatically = true
                    sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(snapped, scrollable))))
                    sv.reflectScrolledClipView(sv.contentView)
                    isScrollingProgrammatically = false
                }
                progress = max(0, min(snapped / scrollable, 1))
            } else {
                DispatchQueue.main.async {
                    self.progress = max(0, min(offset / scrollable, 1))
                }
            }
        }

        @objc func handleTap(_ recognizer: NSGestureRecognizer) { onTap() }

        // feature 9: capture text selection
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let r = tv.selectedRange()
            DispatchQueue.main.async {
                self.selectedRange = r.length > 0 ? r : nil
            }
        }

        // feature 10: scroll to first occurrence of query in text
        func scrollToSearch(query: String, in scrollView: NSScrollView, textView: NSTextView) {
            guard query != lastSearchQuery else { return }
            lastSearchQuery = query
            let str = textView.string as NSString
            let found = str.range(of: query, options: .caseInsensitive)
            guard found.location != NSNotFound else { return }

            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: found, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

            let contentHeight = scrollView.documentView?.frame.height ?? 0
            let visibleHeight = scrollView.contentView.bounds.height
            let scrollable = contentHeight - visibleHeight
            guard scrollable > 0 else { return }

            let targetY = max(0, min(rect.midY - visibleHeight / 2, scrollable))
            isScrollingProgrammatically = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isScrollingProgrammatically = false
            progress = targetY / scrollable
        }
    }
}

// MARK: - iOS

#else
import UIKit

struct NativeTextView: UIViewRepresentable {
    let text: String?
    let attributedText: AttributedString?
    let settings: ReadingSettings
    @Binding var progress: Double
    let onTap: () -> Void
    let ttsHighlightRange: NSRange?
    let userHighlights: [BookHighlight]
    let displayMode: ReaderDisplayMode
    @Binding var pageNavigationDirection: Int
    let searchQuery: String
    @Binding var selectedRange: NSRange?

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, onTap: onTap,
                    navigationDirection: $pageNavigationDirection,
                    selectedRange: $selectedRange)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 60, left: 20, bottom: 60, right: 20)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = context.coordinator
        scrollView.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            textView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        scrollView.delegate = context.coordinator
        textView.addGestureRecognizer(
            UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        )
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        applyContent(to: textView)
        applyHighlights(to: textView)
        scrollView.backgroundColor = UIColor(settings.currentPreset.background)

        // feature 2: paper mode disables free scrolling
        scrollView.isScrollEnabled = displayMode == .scroll

        // feature 1: page navigation
        let dir = pageNavigationDirection
        if dir != 0 {
            context.coordinator.navigatePage(direction: dir, in: scrollView)
            DispatchQueue.main.async { self.pageNavigationDirection = 0 }
        }

        context.coordinator.scrollToProgress(progress, in: scrollView)

        // feature 5: auto-scroll to keep TTS sentence in view
        if let ttsRange = ttsHighlightRange {
            context.coordinator.scrollToRange(ttsRange, in: scrollView, textView: textView)
        }

        // feature 10: scroll to first search match
        if !searchQuery.isEmpty {
            context.coordinator.scrollToSearch(query: searchQuery, in: scrollView, textView: textView)
        }
    }

    private func applyHighlights(to textView: UITextView) {
        let storage = textView.textStorage
        guard storage.length > 0 else { return }
        storage.removeAttribute(.backgroundColor,
                                range: NSRange(location: 0, length: storage.length))
        for h in userHighlights {
            let r = NSRange(location: h.startOffset, length: h.length)
            guard NSMaxRange(r) <= storage.length else { continue }
            storage.addAttribute(.backgroundColor,
                                 value: UIColor.systemYellow.withAlphaComponent(0.45), range: r)
        }
        if let tts = ttsHighlightRange {
            let loc = min(tts.location, storage.length)
            let len = min(tts.length, storage.length - loc)
            if len > 0 {
                storage.addAttribute(.backgroundColor,
                                     value: UIColor.systemBlue.withAlphaComponent(0.25),
                                     range: NSRange(location: loc, length: len))
            }
        }
    }

    private func applyContent(to textView: UITextView) {
        let font = UIFont(name: settings.fontName, size: settings.fontSize)
            ?? UIFont.systemFont(ofSize: settings.fontSize)
        let color = UIColor(settings.currentPreset.text)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = settings.lineSpacing
        let styleAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle
        ]
        if let attr = attributedText {
            let str = NSAttributedString(attr).string
            if textView.text != str { textView.attributedText = NSAttributedString(attr) }
        } else if let str = text, textView.text != str {
            textView.text = str
        }
        let storage = textView.textStorage
        if storage.length > 0 {
            storage.addAttributes(styleAttrs, range: NSRange(location: 0, length: storage.length))
        }
    }

    class Coordinator: NSObject, UIScrollViewDelegate, UITextViewDelegate {
        @Binding var progress: Double
        @Binding var navigationDirection: Int
        @Binding var selectedRange: NSRange?
        let onTap: () -> Void
        weak var textView: UITextView?
        weak var scrollView: UIScrollView?
        var isScrollingProgrammatically = false
        private var lastSearchQuery = ""
        private var lastTTSRange: NSRange?

        init(progress: Binding<Double>, onTap: @escaping () -> Void,
             navigationDirection: Binding<Int>, selectedRange: Binding<NSRange?>) {
            _progress = progress
            _navigationDirection = navigationDirection
            _selectedRange = selectedRange
            self.onTap = onTap
        }

        func scrollToProgress(_ target: Double, in scrollView: UIScrollView) {
            let scrollable = scrollView.contentSize.height - scrollView.bounds.height
            guard scrollable > 0 else { return }
            let targetOffset = target * scrollable
            guard abs(targetOffset - scrollView.contentOffset.y) > 1 else { return }
            isScrollingProgrammatically = true
            scrollView.contentOffset = CGPoint(x: 0, y: targetOffset)
            isScrollingProgrammatically = false
        }

        // feature 1: advance or retreat by one screen height
        func navigatePage(direction: Int, in scrollView: UIScrollView) {
            let pageHeight = scrollView.bounds.height
            let scrollable = scrollView.contentSize.height - pageHeight
            guard scrollable > 0 else { return }
            let target = max(0, min(scrollView.contentOffset.y + CGFloat(direction) * pageHeight, scrollable))
            isScrollingProgrammatically = true
            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
            isScrollingProgrammatically = false
            progress = target / scrollable
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isScrollingProgrammatically else { return }
            let scrollable = scrollView.contentSize.height - scrollView.bounds.height
            guard scrollable > 0 else { return }
            progress = max(0, min(scrollView.contentOffset.y / scrollable, 1))
        }

        // feature 5: keep TTS sentence visible; only scrolls when sentence moves significantly
        func scrollToRange(_ range: NSRange, in scrollView: UIScrollView, textView: UITextView) {
            if let last = lastTTSRange, last == range { return }
            lastTTSRange = range
            guard range.location < textView.textStorage.length else { return }

            let glyphRange = textView.layoutManager
                .glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = textView.layoutManager
                .boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
            let inset = textView.textContainerInset
            let rectInScroll = rect.offsetBy(dx: inset.left, dy: inset.top)
            let scrollable = scrollView.contentSize.height - scrollView.bounds.height
            guard scrollable > 0 else { return }
            let targetY = max(0, min(rectInScroll.midY - scrollView.bounds.height / 2, scrollable))
            guard abs(targetY - scrollView.contentOffset.y) > scrollView.bounds.height * 0.3 else { return }
            isScrollingProgrammatically = true
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
            isScrollingProgrammatically = false
            progress = targetY / scrollable
        }

        // feature 10: scroll to first occurrence of query
        func scrollToSearch(query: String, in scrollView: UIScrollView, textView: UITextView) {
            guard query != lastSearchQuery, let text = textView.text else { return }
            lastSearchQuery = query
            let nsText = text as NSString
            let found = nsText.range(of: query, options: .caseInsensitive)
            guard found.location != NSNotFound else { return }
            scrollToRange(found, in: scrollView, textView: textView)
        }

        // feature 9: capture text selection
        func textViewDidChangeSelection(_ textView: UITextView) {
            let r = textView.selectedRange
            DispatchQueue.main.async {
                self.selectedRange = r.length > 0 ? r : nil
            }
        }

        @objc func handleTap() { onTap() }
    }
}
#endif
