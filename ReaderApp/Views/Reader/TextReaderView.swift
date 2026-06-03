import SwiftUI

struct TextReaderView: View {
    @ObservedObject var vm: ReaderViewModel
    @ObservedObject var settings: ReadingSettings
    @Binding var showBars: Bool

    var body: some View {
        NativeTextView(
            text: vm.book.format == .markdown ? nil : vm.plainText,
            attributedText: vm.book.format == .markdown ? vm.attributedText : nil,
            settings: settings,
            progress: $vm.progress,
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
    let settings: ReadingSettings
    @Binding var progress: Double
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
    }

    private func applyContent(to textView: NSTextView) {
        let font = NSFont(name: settings.fontName, size: settings.fontSize)
            ?? NSFont.systemFont(ofSize: settings.fontSize)
        let color = NSColor(settings.currentPreset.text)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = settings.lineSpacing
        let styleAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle
        ]

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

        init(progress: Binding<Double>, onTap: @escaping () -> Void) {
            _progress = progress
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
    let settings: ReadingSettings
    @Binding var progress: Double
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(progress: $progress, onTap: onTap) }

    func makeUIView(context: Context) -> UITextView {
        // UITextView scrolls natively with lazy TextKit layout — handles
        // multi-million-character documents without laying everything out at once.
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 60, left: 20, bottom: 60, right: 20)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false   // don't swallow scroll/selection touches
        textView.addGestureRecognizer(tap)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        applyContent(to: textView)
        textView.backgroundColor = UIColor(settings.currentPreset.background)
        context.coordinator.scrollToProgress(progress, in: textView)
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

    class Coordinator: NSObject, UITextViewDelegate {
        @Binding var progress: Double
        let onTap: () -> Void
        weak var textView: UITextView?
        var isScrollingProgrammatically = false

        init(progress: Binding<Double>, onTap: @escaping () -> Void) {
            _progress = progress
            self.onTap = onTap
        }

        func scrollToProgress(_ target: Double, in textView: UITextView) {
            let scrollable = textView.contentSize.height - textView.bounds.height
            guard scrollable > 0 else { return }
            let targetOffset = target * scrollable
            let currentOffset = textView.contentOffset.y
            guard abs(targetOffset - currentOffset) > 1 else { return }
            isScrollingProgrammatically = true
            textView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
            isScrollingProgrammatically = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isScrollingProgrammatically else { return }
            let scrollable = scrollView.contentSize.height - scrollView.bounds.height
            guard scrollable > 0 else { return }
            progress = max(0, min(scrollView.contentOffset.y / scrollable, 1))
        }

        @objc func handleTap() { onTap() }
    }
}
#endif
