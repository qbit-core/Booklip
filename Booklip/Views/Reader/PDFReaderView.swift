import SwiftUI
import PDFKit

struct PDFReaderView: View {
    let document: PDFDocument?
    var background: Color = Color(white: 1)
    @Binding var progress: Double
    var pageColumns: Int = 1

    var body: some View {
        PDFKitView(document: document, background: background, progress: $progress, pageColumns: pageColumns)
    }
}

// MARK: - iOS

#if os(iOS)
import UIKit

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument?
    let background: Color
    @Binding var progress: Double
    var pageColumns: Int = 1

    func makeCoordinator() -> Coordinator { Coordinator(progress: $progress) }

    func makeUIView(context: Context) -> PDFView {
        let view = makePDFView()
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document == nil { uiView.document = document }
        uiView.backgroundColor = UIColor(background)
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
    var pageColumns: Int = 1

    func makeCoordinator() -> Coordinator { Coordinator(progress: $progress) }

    func makeNSView(context: Context) -> PDFView {
        let view = makePDFView()
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document == nil { nsView.document = document }
        nsView.backgroundColor = NSColor(background)
        // Switch between single and two-up layout based on the appearance setting.
        let mode: PDFDisplayMode = pageColumns == 2 ? .twoUpContinuous : .singlePageContinuous
        if nsView.displayMode != mode { nsView.displayMode = mode }
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
class Coordinator: NSObject {
    @Binding var progress: Double
    init(progress: Binding<Double>) { _progress = progress }

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
