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
            window = nil
            if let id = currentItemId { _openReaderItemIDs.remove(id) }
        }

        func windowWillClose(_ notification: Notification) {
            if let id = currentItemId { _openReaderItemIDs.remove(id) }
            if let contentView = window?.contentView {
                clearNSTextViews(in: contentView)
            }
            // The NSApplication inner autorelease pool (created per run-loop iteration
            // inside NSApplication.run) drains AFTER this event handler returns but
            // BEFORE the next run-loop iteration. NSLayoutManager stores its glyph and
            // line-fragment arrays and also autoreleases references to them via internal
            // accessor methods; if we nil `window` here those arrays are freed by
            // dealloc while the pool still holds a reference, so the pool drain calls
            // objc_release on freed memory → EXC_BAD_ACCESS in NSArrayM.dealloc.
            // By holding the window alive via `deferred` until the GCD block fires
            // (next run-loop iteration, after the pool has already drained), all
            // autoreleased references are released while the objects are still alive.
            let deferred = window
            window = nil
            currentItemId = nil
            onClose?()
            onClose = nil
            DispatchQueue.main.async { _ = deferred }
        }

        private func clearNSTextViews(in view: NSView) {
            for sub in view.subviews { clearNSTextViews(in: sub) }
            if let tv = view as? NSTextView {
                autoreleasepool {
                    // Invalidate NSLayoutManager's glyph and layout caches before
                    // clearing the text storage. This releases the cached arrays now
                    // (while our pool is active and objects are still alive) instead
                    // of deferring to dealloc, where they could race the pool drain.
                    if let lm = tv.layoutManager, let ts = tv.textStorage, ts.length > 0 {
                        lm.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: ts.length),
                                            changeInLength: 0, actualCharacterRange: nil)
                        lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: ts.length),
                                            actualCharacterRange: nil)
                    }
                    tv.textStorage?.setAttributedString(NSAttributedString(string: ""))
                }
            }
        }
    }
}
#endif
