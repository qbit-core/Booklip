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

// Windows held alive across two main-queue hops to outlast the NSApplication
// autorelease pool drain. See deferWindowRelease(_:) for the full rationale.
private var _retainedWindows: [ObjectIdentifier: NSWindow] = [:]

// Collect all NSTextStorage objects in a view tree.
// Used by deferWindowRelease to keep them alive through the window dealloc chain.
private func collectTextStorages(in view: NSView, into arr: inout [NSTextStorage]) {
    for sub in view.subviews { collectTextStorages(in: sub, into: &arr) }
    if let tv = view as? NSTextView, let storage = tv.textStorage {
        arr.append(storage)
    }
}

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
            let binding = $item
            // Set currentItemId AFTER open() so that closeWindow() inside open()
            // still sees the OLD id (for _openReaderItemIDs cleanup), not the new one.
            coord.open(
                content: AnyView(makeContent(current)),
                itemId: newId,
                onClose: { DispatchQueue.main.async { binding.wrappedValue = nil } }
            )
            coord.currentItemId = newId
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
            window?.delegate = nil
            window?.close()
            let deferred = window
            window = nil
            if let id = currentItemId { _openReaderItemIDs.remove(id) }
            currentItemId = nil
            deferWindowRelease(deferred)
        }

        func windowWillClose(_ notification: Notification) {
            if let id = currentItemId { _openReaderItemIDs.remove(id) }
            let deferred = window
            window = nil
            currentItemId = nil
            onClose?()
            onClose = nil
            deferWindowRelease(deferred)
        }

        // AppKit bug: NSTextView.dealloc releases both NSLayoutManager and NSTextStorage,
        // but their release order is undefined. If NSTextStorage is freed first,
        // NSLayoutManager.dealloc (or the glyph-cache objects it autoreleases into the
        // explicit pool) accesses freed NSTextStorage memory when the pool drains →
        // EXC_BAD_ACCESS in objc_release.
        //
        // Fix: capture strong references to all NSTextStorage objects before releasing
        // the window. This keeps NSTextStorage alive through the entire window-dealloc
        // chain and the subsequent ARP drain, regardless of ivar-release order inside
        // NSTextView.dealloc. After the pool drains safely, we release NSTextStorage
        // in a dedicated pool where no sibling objects are being freed.
        //
        // _retainedWindows keeps NSWindow alive across two main-queue hops to outlast
        // the NSApplication per-callout autorelease pool drain.
        private func deferWindowRelease(_ window: NSWindow?) {
            guard let window else { return }
            let key = ObjectIdentifier(window)
            // Collect NSTextStorage refs NOW, while the view hierarchy is intact.
            // 50 ms later the window's contentViewController may be replaced by an
            // internal AppKit object (e.g. _AdditionalDimmingViewContentViewController)
            // that does not respond to -contentViewController → NSInvalidArgumentException.
            var textStorages: [NSTextStorage] = []
            if let cv = window.contentViewController?.view {
                collectTextStorages(in: cv, into: &textStorages)
            }
            _retainedWindows[key] = window
            // The asyncAfter closure captures only `key` (value type — no ARC) and
            // `textStorages` (already populated). It does NOT capture `window`; a direct
            // reference would add a second strong owner and NSWindow.dealloc would fire
            // outside our explicit pool when the closure is freed by the dispatch source
            // (block_destroy_helper → EXC_BAD_ACCESS).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                autoreleasepool {
                    _ = _retainedWindows.removeValue(forKey: key)
                    // NSWindow.dealloc fires inside this pool (sole retainer released).
                    // NSTextView.dealloc releases NSLayoutManager → NSLayoutManager.dealloc
                    // autoreleases glyph-cache objects into this pool.
                    // NSTextStorage is kept alive by `textStorages` so those objects
                    // drain safely regardless of ivar-release order in NSTextView.dealloc.
                }
                autoreleasepool {
                    textStorages.removeAll()
                    // NSTextStorage.dealloc fires here, cleanly.
                }
            }
        }
    }
}
#endif
