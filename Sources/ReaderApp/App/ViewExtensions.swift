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

// Clear NSTextView content recursively so NSLayoutManager's glyph cache is
// empty before the enclosing NSWindow is released.  Must be called while the
// view is still in the subview tree (before SwiftUI teardown removes it).
private func wipeNSTextViews(in view: NSView) {
    for sub in view.subviews { wipeNSTextViews(in: sub) }
    if let tv = view as? NSTextView,
       let storage = tv.textStorage,
       let lm = tv.layoutManager,
       let tc = tv.textContainer {
        autoreleasepool {
            storage.setAttributedString(NSAttributedString(string: ""))
            // setAttributedString INVALIDATES NSLayoutManager's glyph cache for
            // the replaced range but does NOT free the allocated glyph data —
            // NSLayoutManager marks the range as needing regeneration and keeps
            // the old glyph buffer live.  When NSLayoutManager.dealloc runs
            // later it tries to retain an internal glyph-cache object that was
            // already freed in the same dealloc chain (AppKit bug), crashing
            // during the autorelease pool drain.
            //
            // ensureLayout(for:) forces NSLayoutManager to REGENERATE glyphs for
            // the now-empty content.  During regeneration the invalid (large) glyph
            // buffer is freed and replaced with a trivially empty one.  After this
            // call NSLayoutManager.dealloc has nothing to over-retain/release.
            lm.ensureLayout(for: tc)
        }
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
            // Dispatch NSTextView wipe BEFORE window.close() so the wipe block is
            // queued ahead of the binding-nil block (dispatched inside windowWillClose
            // via onClose()).  GCD FIFO guarantees the wipe fires while the NSScrollView
            // is still in the subview tree, emptying NSLayoutManager's glyph cache
            // before deferWindowRelease releases the window.
            if let cv = window?.contentViewController?.view {
                DispatchQueue.main.async { wipeNSTextViews(in: cv) }
            }
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
            // Dispatch wipe BEFORE onClose() so it is queued ahead of binding-nil.
            if let cv = deferred?.contentViewController?.view {
                DispatchQueue.main.async { wipeNSTextViews(in: cv) }
            }
            onClose?()
            onClose = nil
            deferWindowRelease(deferred)
        }

        // NSLayoutManager.dealloc has an AppKit bug: it calls retain on an already-
        // freed glyph-cache object in the same dealloc chain, and the autoreleasepool
        // that wraps removeValue(forKey:) crashes when it drains that bad reference.
        // Fix: clear NSTextView content while the view is still in the subview tree
        // (dispatched by closeWindow/windowWillClose BEFORE the binding-nil block so
        // GCD FIFO guarantees the wipe fires first).  With an empty glyph cache,
        // NSLayoutManager.dealloc has nothing to over-retain/over-release.
        //
        // _retainedWindows keeps NSWindow alive across two main-queue hops to outlast
        // the NSApplication autorelease pool drain.  Closures capture only `key`
        // (ObjectIdentifier, a value type) — no ARC on NSWindow through the closure.
        private func deferWindowRelease(_ window: NSWindow?) {
            guard let window else { return }
            let key = ObjectIdentifier(window)
            _retainedWindows[key] = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                autoreleasepool {
                    _ = _retainedWindows.removeValue(forKey: key)
                }
            }
        }
    }
}
#endif
