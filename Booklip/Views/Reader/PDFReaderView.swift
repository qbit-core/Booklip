import SwiftUI
import PDFKit

struct PDFReaderView: View {
    let document: PDFDocument?
    var background: Color = Color(white: 1)
    @Binding var progress: Double
    @Binding var showBars: Bool
    @Binding var pageNavigationDirection: Int
    var searchQuery: String = ""
    var pageEffect: PageEffect = .verticalSlide

    var body: some View {
        ContinuousPDFView(
            document: document,
            progress: $progress,
            pageNavigationDirection: $pageNavigationDirection,
            pageEffect: pageEffect,
            onTap: { showBars.toggle() }
        )
    }
}

// MARK: - iOS

#if os(iOS)
import UIKit

private struct ContinuousPDFView: UIViewRepresentable {
    let document: PDFDocument?
    @Binding var progress: Double
    @Binding var pageNavigationDirection: Int
    var pageEffect: PageEffect = .verticalSlide
    var onTap: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, pageNavigationDirection: $pageNavigationDirection, onTap: onTap)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = .systemGray6
        scrollView.delegate = context.coordinator
        context.coordinator.scrollView = scrollView

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap))
        scrollView.addGestureRecognizer(tap)

        if let doc = document {
            context.coordinator.buildPages(doc, in: scrollView)
        }
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coord = context.coordinator
        coord.onTap = onTap

        let isPaper = pageEffect == .paper
        // In paper mode disable user scrolling — page turns are driven by
        // navigatePage() with a CATransition, matching EPUB paper mode behaviour.
        scrollView.isPagingEnabled = false
        scrollView.isScrollEnabled = !isPaper
        scrollView.showsVerticalScrollIndicator = !isPaper

        // Rebuild pages when pageEffect changes so sizing is correct
        if coord.document == nil || coord.currentPageEffect != pageEffect, let doc = document {
            coord.currentPageEffect = pageEffect
            coord.buildPages(doc, in: scrollView)
        }

        // Page navigation from tap zones / keyboard
        let dir = pageNavigationDirection
        if dir != 0 {
            coord.navigatePage(dir, in: scrollView)
            DispatchQueue.main.async { pageNavigationDirection = 0 }
        } else {
            coord.seek(to: progress, in: scrollView)
        }
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var progress: Double
        @Binding var pageNavigationDirection: Int
        var onTap: () -> Void
        weak var scrollView: UIScrollView?
        var document: PDFDocument?
        var pageViews: [UIImageView] = []
        // page offsets (top-Y of each page in the scroll view content)
        var pageOffsets: [CGFloat] = []
        var isScrollingProgrammatically = false
        var lastReportedProgress: Double?
        var currentPageEffect: PageEffect = .verticalSlide
        private let pageSpacing: CGFloat = 8

        init(progress: Binding<Double>, pageNavigationDirection: Binding<Int>, onTap: @escaping () -> Void) {
            _progress = progress
            _pageNavigationDirection = pageNavigationDirection
            self.onTap = onTap
        }

        func buildPages(_ doc: PDFDocument, in scrollView: UIScrollView) {
            document = doc
            pageViews.forEach { $0.removeFromSuperview() }
            // Remove old container subviews
            scrollView.subviews.forEach { $0.removeFromSuperview() }
            pageViews = []
            pageOffsets = []

            let screenBounds = UIScreen.main.bounds
            let width = max(scrollView.bounds.width, screenBounds.width)
            let screenHeight = max(scrollView.bounds.height, screenBounds.height)
            let isPaper = currentPageEffect == .paper

            let container = UIView()
            container.backgroundColor = .clear
            scrollView.addSubview(container)

            var y: CGFloat = 0
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let pageRect = page.bounds(for: .mediaBox)

                let imageView = UIImageView()
                imageView.contentMode = .scaleAspectFit
                imageView.backgroundColor = .white

                let frameHeight: CGFloat
                let renderSize: CGSize
                let renderScale: CGFloat

                if isPaper {
                    // Each page occupies exactly one screen height
                    frameHeight = screenHeight
                    let scaleW = width / pageRect.width
                    let scaleH = screenHeight / pageRect.height
                    renderScale = min(scaleW, scaleH)
                    renderSize = CGSize(width: pageRect.width * renderScale,
                                       height: pageRect.height * renderScale)
                } else {
                    renderScale = width / pageRect.width
                    renderSize = CGSize(width: width, height: pageRect.height * renderScale)
                    frameHeight = renderSize.height
                }

                imageView.frame = CGRect(x: 0, y: y, width: width, height: frameHeight)
                container.addSubview(imageView)
                pageViews.append(imageView)
                pageOffsets.append(y)

                let capturedPage = page
                let capturedRenderSize = renderSize
                let capturedRenderScale = renderScale
                DispatchQueue.global(qos: .userInitiated).async { [weak imageView] in
                    let renderer = UIGraphicsImageRenderer(size: capturedRenderSize)
                    let img = renderer.image { ctx in
                        UIColor.white.setFill()
                        ctx.fill(CGRect(origin: .zero, size: capturedRenderSize))
                        ctx.cgContext.translateBy(x: 0, y: capturedRenderSize.height)
                        ctx.cgContext.scaleBy(x: 1, y: -1)
                        ctx.cgContext.scaleBy(x: capturedRenderScale, y: capturedRenderScale)
                        capturedPage.draw(with: .mediaBox, to: ctx.cgContext)
                    }
                    DispatchQueue.main.async { imageView?.image = img }
                }

                y += frameHeight + (isPaper ? 0 : pageSpacing)
            }

            container.frame = CGRect(x: 0, y: 0, width: width, height: y)
            scrollView.contentSize = CGSize(width: width, height: y)

            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let sv = scrollView else { return }
                self.seek(to: self.progress, in: sv)
            }
        }

        func seek(to target: Double, in scrollView: UIScrollView) {
            guard !isScrollingProgrammatically else { return }
            if let lr = lastReportedProgress, abs(lr - target) < 0.001 { return }
            let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            guard maxOffset > 0 else { return }
            let targetY = min(max(0, target * scrollView.contentSize.height), maxOffset)
            guard abs(scrollView.contentOffset.y - targetY) > 2 else { return }
            isScrollingProgrammatically = true
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            isScrollingProgrammatically = false
        }

        func navigatePage(_ direction: Int, in scrollView: UIScrollView) {
            guard !pageOffsets.isEmpty else { return }
            let currentY = scrollView.contentOffset.y

            // Find the page currently at or just past the top of the viewport
            var currentIndex = 0
            for (i, offset) in pageOffsets.enumerated() {
                if offset <= currentY + 1 { currentIndex = i }
            }

            let targetIndex = max(0, min(pageOffsets.count - 1, currentIndex + direction))
            guard targetIndex != currentIndex else { return }
            var targetY = pageOffsets[targetIndex]
            let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            targetY = min(targetY, maxOffset)

            isScrollingProgrammatically = true
            if currentPageEffect == .paper {
                // Horizontal push transition — matches EPUB paper mode behaviour.
                let transition = CATransition()
                transition.duration = 0.35
                transition.type = .push
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                transition.subtype = direction > 0 ? .fromRight : .fromLeft
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self, weak scrollView] in
                    self?.isScrollingProgrammatically = false
                    if let sv = scrollView { self?.commitProgress(sv) }
                }
                scrollView.layer.add(transition, forKey: "pageTurn")
                scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
                CATransaction.commit()
            } else {
                scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
                isScrollingProgrammatically = false
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
            if !willDecelerate { commitProgress(scrollView) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { commitProgress(scrollView) }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { commitProgress(scrollView) }

        private func commitProgress(_ scrollView: UIScrollView) {
            guard !isScrollingProgrammatically else { return }
            let total = scrollView.contentSize.height
            guard total > 0 else { return }
            let value = scrollView.contentOffset.y / total
            lastReportedProgress = value
            DispatchQueue.main.async { [weak self] in self?.progress = value }
        }

        @objc func handleTap() { onTap() }
    }
}

// MARK: - macOS

#elseif os(macOS)
import AppKit

private struct ContinuousPDFView: NSViewRepresentable {
    let document: PDFDocument?
    @Binding var progress: Double
    @Binding var pageNavigationDirection: Int
    var pageEffect: PageEffect = .verticalSlide
    var onTap: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, onTap: onTap)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = pageEffect == .paper ? .singlePage : .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = false
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        let click = NSClickGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(click)
        context.coordinator.onTap = onTap
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document == nil { nsView.document = document }
        context.coordinator.onTap = onTap
        let desiredMode: PDFDisplayMode = pageEffect == .paper ? .singlePage : .singlePageContinuous
        if nsView.displayMode != desiredMode { nsView.displayMode = desiredMode }

        let dir = pageNavigationDirection
        if dir != 0 {
            if dir > 0 { nsView.goToNextPage(nil) }
            else       { nsView.goToPreviousPage(nil) }
            DispatchQueue.main.async { pageNavigationDirection = 0 }
        } else if let doc = nsView.document, let currentPage = nsView.currentPage {
            let pageCount = max(doc.pageCount - 1, 1)
            let currentProgress = Double(doc.index(for: currentPage)) / Double(pageCount)
            if abs(progress - currentProgress) > 0.01 {
                let target = Int(round(progress * Double(pageCount)))
                if let page = doc.page(at: min(target, doc.pageCount - 1)) {
                    nsView.go(to: page)
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    class Coordinator: NSObject {
        @Binding var progress: Double
        var onTap: () -> Void
        init(progress: Binding<Double>, onTap: @escaping () -> Void) {
            _progress = progress
            self.onTap = onTap
        }
        @objc func handleTap(_ g: Any) { onTap() }
        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView,
                  let doc = view.document,
                  let page = view.currentPage else { return }
            let idx = doc.index(for: page)
            let value = Double(idx) / Double(max(doc.pageCount - 1, 1))
            DispatchQueue.main.async { [weak self] in self?.progress = value }
        }
    }
}
#endif
