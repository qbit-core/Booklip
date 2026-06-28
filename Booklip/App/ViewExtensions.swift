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

// Global set of item IDs that currently have an open reader window.
// Prevents two Library windows from spawning duplicate reader windows for the
// same book when both observe the same selectedBook binding change.
private var _openReaderItemIDs: Set<AnyHashable> = []

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
                itemId: newId,
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

        func open(content: AnyView, itemId: AnyHashable, onClose: @escaping () -> Void) {
            // If another Library window already opened a reader for this book,
            // just bring that window forward rather than creating a second one.
            if _openReaderItemIDs.contains(itemId) {
                for win in NSApplication.shared.windows
                where win.titlebarAppearsTransparent && win.isVisible {
                    win.makeKeyAndOrderFront(nil)
                    break
                }
                return
            }
            _openReaderItemIDs.insert(itemId)
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
            // contentViewController= may resize the window if preferredContentSize
            // is non-zero; override to guarantee our desired initial size.
            win.setContentSize(NSSize(width: 700, height: 900))
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.minSize = NSSize(width: 480, height: 640)
            // Disable the window open/close animation so AppKit never creates
            // _NSWindowTransformAnimation. That animation stores unsafe_unretained
            // references into the window's view hierarchy; our windowWillClose handler
            // releases NSHostingController synchronously while the animation object
            // is still autoreleased, causing objc_release on a freed pointer when
            // the autorelease pool drains during the next CA transaction commit.
            win.animationBehavior = .none
            win.delegate = self
            win.center()
            win.makeKeyAndOrderFront(nil)
            self.window = win
        }

        func closeWindow() {
            window?.delegate = nil   // stop the delegate callback firing for our own close
            window?.close()
            if let contentView = window?.contentView {
                clearNSTextViews(in: contentView)
            }
            let deferred = window
            window = nil
            if let id = currentItemId { _openReaderItemIDs.remove(id) }
            currentItemId = nil
            deferWindowRelease(deferred)
        }

        func windowWillClose(_ notification: Notification) {
            if let id = currentItemId { _openReaderItemIDs.remove(id) }
            if let contentView = window?.contentView {
                clearNSTextViews(in: contentView)
            }
            let deferred = window
            window = nil
            currentItemId = nil
            onClose?()
            onClose = nil
            deferWindowRelease(deferred)
        }

        // Defer NSWindow dealloc past the NSApplication autorelease pool drain.
        //
        // NSLayoutManager autoreleases references to its glyph/line-fragment arrays
        // via internal accessor methods. If the window (and thus NSLayoutManager) is
        // freed before the pool drains, NSLayoutManager.dealloc frees those objects
        // while the pool still holds a reference → objc_release on freed memory
        // (EXC_BAD_ACCESS in NSArrayM.dealloc / AutoreleasePoolPage::releaseUntil).
        //
        // Two GCD hops are required because CFRunLoop calls __CFRunLoopDoBlocks once
        // more AFTER source0 (AppKit event processing) but BEFORE kCFRunLoopBeforeWaiting
        // (pool drain). A single async fires in that same pass; the outer block fires
        // there, schedules the inner block, and the inner block fires only in the NEXT
        // __CFRunLoopDoBlocks sweep — which is after the pool drain. This holds for
        // both the user-close path (windowWillClose, called from source0) and the
        // programmatic path (closeWindow, called from a SwiftUI GCD update block).
        //
        // Empty closure body: "_ = deferred" gives ARC an in-body use-point and the
        // optimizer moves the release there, then block_destroy_helper releases again
        // → double-free. With no body reference the sole release is in the destroy helper.
        private func deferWindowRelease(_ window: NSWindow?) {
            DispatchQueue.main.async {
                DispatchQueue.main.async { [window] in }
            }
        }

        private func clearNSTextViews(in view: NSView) {
            for sub in view.subviews { clearNSTextViews(in: sub) }
            if let tv = view as? NSTextView {
                autoreleasepool {
                    tv.textStorage?.setAttributedString(NSAttributedString(string: ""))
                }
            }
        }
    }
}
#endif
