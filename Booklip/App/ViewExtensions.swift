import SwiftUI

extension View {
    func inlineNavigationTitle() -> some View {
#if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    func hideNavigationBar() -> some View {
#if os(iOS)
        // Hide the whole nav bar (incl. the system back button); we provide
        // our own back control in the reader's top bar. Apply every relevant
        // API so it also holds when pushed from a searchable list.
        self.toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .navigationBarHidden(true)
#else
        self
#endif
    }
}

extension View {
    // Full-screen on iOS; a standalone movable window on macOS.
    func readerCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
#if os(iOS)
        self.fullScreenCover(item: item, content: content)
#else
        self.background(ReaderStandaloneWindow(item: item, makeContent: content))
#endif
    }
}

extension ToolbarItemPlacement {
    static var platformTrailing: ToolbarItemPlacement {
#if os(iOS)
        .topBarTrailing
#else
        .automatic
#endif
    }
}

// MARK: - macOS standalone window

#if os(macOS)
import AppKit

/// Presents content in a standalone, freely movable NSWindow instead of an
/// attached sheet. Each distinct item ID gets its own window; closing the
/// window sets the binding back to nil.
private struct ReaderStandaloneWindow<Item: Identifiable, Content: View>: NSViewRepresentable {
    @Binding var item: Item?
    let makeContent: (Item) -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        if let current = item {
            let newId = AnyHashable(current.id)
            guard coord.currentItemId != newId else { return }
            coord.currentItemId = newId
            let binding = $item
            coord.open(
                content: AnyView(makeContent(current)),
                onClose: { DispatchQueue.main.async { binding.wrappedValue = nil } }
            )
        } else {
            coord.closeWindow()
        }
    }

    class Coordinator: NSObject, NSWindowDelegate {
        var currentItemId: AnyHashable?
        private var window: NSWindow?
        private var onClose: (() -> Void)?

        func open(content: AnyView, onClose: @escaping () -> Void) {
            closeWindow()
            self.onClose = onClose

            let hosting = NSHostingController(rootView: content)
            // NSScrollView has no intrinsic size, so the hosting controller's
            // preferred content size is near-zero. Disable auto-sizing so the
            // window keeps the size we specify rather than collapsing on show.
            hosting.sizingOptions = []
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.contentViewController = hosting
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.minSize = NSSize(width: 480, height: 640)
            win.delegate = self
            win.center()
            win.makeKeyAndOrderFront(nil)
            self.window = win
        }

        func closeWindow() {
            window?.delegate = nil   // stop the delegate callback firing for our own close
            window?.close()
            window = nil
        }

        func windowWillClose(_ notification: Notification) {
            window = nil
            currentItemId = nil
            onClose?()
            onClose = nil
        }
    }
}
#endif
