import SwiftUI
import PDFKit

struct PDFReaderView: View {
    let document: PDFDocument?
    var background: Color = Color(white: 1)
    @Binding var progress: Double
    @Binding var showBars: Bool
    @Binding var pageNavigationDirection: Int
    var searchQuery: String = ""

    var body: some View {
        PDFKitView(
            document: document,
            background: background,
            progress: $progress,
            pageNavigationDirection: $pageNavigationDirection,
            onTap: { showBars.toggle() }
        )
    }
}

// MARK: - iOS

#if os(iOS)
import UIKit

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument?
    let background: Color
    @Binding var progress: Double
    @Binding var pageNavigationDirection: Int
    var onTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(progress: $progress) }

    func makeUIView(context: Context) -> PDFView {
        let view = makePDFView()
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        context.coordinator.onTap = onTap
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document == nil { uiView.document = document }
        uiView.backgroundColor = UIColor(background)
        context.coordinator.onTap = onTap

        let dir = pageNavigationDirection
        if dir != 0 {
            if dir > 0 { uiView.goToNextPage(nil) }
            else       { uiView.goToPreviousPage(nil) }
            let binding = $pageNavigationDirection
            DispatchQueue.main.async { binding.wrappedValue = 0 }
        } else if let doc = uiView.document, let currentPage = uiView.currentPage {
            let pageCount = max(doc.pageCount - 1, 1)
            let currentProgress = Double(doc.index(for: currentPage)) / Double(pageCount)
            if abs(progress - currentProgress) > 0.01 {
                let target = Int(round(progress * Double(pageCount)))
                if let page = doc.page(at: min(target, doc.pageCount - 1)) {
                    uiView.go(to: page)
                }
            }
        }
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
}

// MARK: - macOS

#elseif os(macOS)
import AppKit

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument?
    let background: Color
    @Binding var progress: Double
    @Binding var pageNavigationDirection: Int
    var onTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(progress: $progress) }

    func makeNSView(context: Context) -> PDFView {
        let view = makePDFView()
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
        nsView.backgroundColor = NSColor(background)
        if nsView.displayMode != .singlePageContinuous { nsView.displayMode = .singlePageContinuous }
        context.coordinator.onTap = onTap

        let dir = pageNavigationDirection
        if dir != 0 {
            if dir > 0 { nsView.goToNextPage(nil) }
            else       { nsView.goToPreviousPage(nil) }
            let binding = $pageNavigationDirection
            DispatchQueue.main.async { binding.wrappedValue = 0 }
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
}
#endif

// MARK: - Shared helpers

private func makePDFView() -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    return view
}

// Coordinator is shared across platforms
#if os(iOS)
class Coordinator: NSObject, UIGestureRecognizerDelegate {
#else
class Coordinator: NSObject {
#endif
    @Binding var progress: Double
    var onTap: () -> Void = {}
    init(progress: Binding<Double>) { _progress = progress }

    @objc func handleTap(_ gesture: Any) { onTap() }

    @objc func pageChanged(_ notification: Notification) {
        guard let view = notification.object as? PDFView,
              let doc = view.document,
              let page = view.currentPage
        else { return }
        let pageIndex = doc.index(for: page)
        let newProgress = Double(pageIndex) / Double(max(doc.pageCount - 1, 1))
        // PDFViewPageChanged can fire during updateUIView/updateNSView when the
        // document is first assigned — defer so we never write inside a view update.
        DispatchQueue.main.async { [weak self] in self?.progress = newProgress }
    }
}
