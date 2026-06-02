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
        let storage = textView.textStorage
        if storage.length > 0 {
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

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 60, left: 20, bottom: 60, right: 20)
        textView.translatesAutoresizingMaskIntoConstraints = false
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
        textView.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap)))
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        applyContent(to: textView)
        scrollView.backgroundColor = UIColor(settings.currentPreset.background)
        context.coordinator.scrollToProgress(progress, in: scrollView)
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
            if textView.text != str {
                textView.attributedText = NSAttributedString(attr)
            }
        } else if let str = text, textView.text != str {
            textView.text = str
        }

        // Always re-apply style so font/color/spacing changes take effect
        let storage = textView.textStorage
        if storage.length > 0 {
            storage.addAttributes(styleAttrs, range: NSRange(location: 0, length: storage.length))
        }
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var progress: Double
        let onTap: () -> Void
        weak var textView: UITextView?
        weak var scrollView: UIScrollView?
        var isScrollingProgrammatically = false

        init(progress: Binding<Double>, onTap: @escaping () -> Void) {
            _progress = progress
            self.onTap = onTap
        }

        func scrollToProgress(_ target: Double, in scrollView: UIScrollView) {
            let scrollable = scrollView.contentSize.height - scrollView.bounds.height
            guard scrollable > 0 else { return }
            let targetOffset = target * scrollable
            let currentOffset = scrollView.contentOffset.y
            guard abs(targetOffset - currentOffset) > 1 else { return }
            isScrollingProgrammatically = true
            scrollView.contentOffset = CGPoint(x: 0, y: targetOffset)
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
