import SwiftUI
import PDFKit

struct PDFReaderView: View {
    let document: PDFDocument?
    @Binding var progress: Double
    let displayMode: ReaderDisplayMode
    // feature 1: -1 = prev page, 0 = idle, 1 = next page
    @Binding var pageNavigationDirection: Int
    let searchQuery: String

    var body: some View {
        PDFKitView(
            document: document,
            progress: $progress,
            displayMode: displayMode,
            pageNavigationDirection: $pageNavigationDirection,
            searchQuery: searchQuery
        )
    }
}

// MARK: - iOS

#if os(iOS)
import UIKit

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument?
    @Binding var progress: Double
    let displayMode: ReaderDisplayMode
    @Binding var pageNavigationDirection: Int
    let searchQuery: String

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, navigationDirection: $pageNavigationDirection)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = buildPDFView(mode: displayMode)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        context.coordinator.pdfView = view
        return view
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document == nil { pdfView.document = document }

        // feature 2: paper = single page (no continuous scroll); scroll = continuous
        let targetMode: PDFDisplayMode = displayMode == .paper ? .singlePage : .singlePageContinuous
        if pdfView.displayMode != targetMode { pdfView.displayMode = targetMode }

        // feature 1: keyboard/programmatic page navigation
        let dir = pageNavigationDirection
        if dir != 0 {
            if dir > 0 { pdfView.goToNextPage(nil) }
            else       { pdfView.goToPreviousPage(nil) }
            DispatchQueue.main.async { self.pageNavigationDirection = 0 }
        }

        // feature 10: find text and navigate to first result
        if !searchQuery.isEmpty {
            context.coordinator.performSearch(query: searchQuery, in: pdfView)
        }
    }
}

// MARK: - macOS

#elseif os(macOS)
import AppKit

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument?
    @Binding var progress: Double
    let displayMode: ReaderDisplayMode
    @Binding var pageNavigationDirection: Int
    let searchQuery: String

    func makeCoordinator() -> Coordinator {
        Coordinator(progress: $progress, navigationDirection: $pageNavigationDirection)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = buildPDFView(mode: displayMode)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        context.coordinator.pdfView = view
        return view
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document == nil { pdfView.document = document }

        let targetMode: PDFDisplayMode = displayMode == .paper ? .singlePage : .singlePageContinuous
        if pdfView.displayMode != targetMode { pdfView.displayMode = targetMode }

        let dir = pageNavigationDirection
        if dir != 0 {
            if dir > 0 { pdfView.goToNextPage(nil) }
            else       { pdfView.goToPreviousPage(nil) }
            DispatchQueue.main.async { self.pageNavigationDirection = 0 }
        }

        if !searchQuery.isEmpty {
            context.coordinator.performSearch(query: searchQuery, in: pdfView)
        }
    }
}
#endif

// MARK: - Shared helpers

private func buildPDFView(mode: ReaderDisplayMode) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = mode == .paper ? .singlePage : .singlePageContinuous
    view.displayDirection = .vertical
    return view
}

class Coordinator: NSObject {
    @Binding var progress: Double
    @Binding var navigationDirection: Int
    weak var pdfView: PDFView?
    private var lastSearchQuery = ""

    init(progress: Binding<Double>, navigationDirection: Binding<Int>) {
        _progress = progress
        _navigationDirection = navigationDirection
    }

    @objc func pageChanged(_ notification: Notification) {
        guard let view = notification.object as? PDFView,
              let doc = view.document,
              let page = view.currentPage
        else { return }
        let pageIndex = doc.index(for: page)
        progress = Double(pageIndex) / Double(max(doc.pageCount - 1, 1))
    }

    // feature 10: synchronous PDF text search; navigates to first match
    func performSearch(query: String, in pdfView: PDFView) {
        guard query != lastSearchQuery, let doc = pdfView.document else { return }
        lastSearchQuery = query
        let results = doc.findString(query, withOptions: [.caseInsensitive])
        if let first = results.first {
            pdfView.go(to: first)
        }
    }
}
