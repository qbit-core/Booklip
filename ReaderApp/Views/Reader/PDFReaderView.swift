import SwiftUI
import PDFKit

struct PDFReaderView: View {
    let document: PDFDocument?
    @Binding var progress: Double

    var body: some View {
        PDFKitView(document: document, progress: $progress)
    }
}

// MARK: - iOS

#if os(iOS)
import UIKit

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument?
    @Binding var progress: Double

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
    }
}

// MARK: - macOS

#elseif os(macOS)
import AppKit

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument?
    @Binding var progress: Double

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
        progress = Double(pageIndex) / Double(max(doc.pageCount - 1, 1))
    }
}
