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

private var _openReaderItemIDs: Set<AnyHashable> = []
private var _retainedWindows: [ObjectIdentifier: NSWindow] = [:]

private func collectTextStorages(in view: NSView, into arr: inout [NSTextStorage]) {
    for sub in view.subviews { collectTextStorages(in: sub, into: &arr) }
    if let tv = view as? NSTextView, let storage = tv.textStorage {
        arr.append(storage)
    }
}

// Final stage of window teardown, called after NSWindow.close() has fully returned.
//
// Two AppKit hazards make teardown non-trivial:
//
// Hazard A — EXC_BAD_ACCESS at __CFRunLoopPerCalloutARPEnd:
//   close() autoreleases AppKit-internal bookkeeping objects (CA transactions,
//   window-ordering state) into the CFRunLoop per-callout pool.  Those objects
//   hold unsafe_unretained back-refs into the view hierarchy.  If we nil
//   contentViewController *during* windowWillClose (which fires mid-close()), we
//   free the view hierarchy while those objects still point at it.  The outer pool
//   drains after close() returns → EXC_BAD_ACCESS.
//   Fix: windowWillClose defers this function to DispatchQueue.main.async.
//
// Hazard B — NSInvalidArgumentException "-[NSView contentViewController]":
//   With isReleasedWhenClosed = true (the default), close() calls [window release]
//   internally.  Even though our strong ref keeps the window alive, AppKit's
//   internal "being released" path replaces contentViewController with an opaque
//   proxy object.  Accessing window.contentViewController after close() then hits
//   an object that doesn't understand that selector.
//   Fix: set isReleasedWhenClosed = false so close() only hides the window.
//   We collect hostingVC and textStorages BEFORE close() is called, so this
//   function never needs to touch window.contentViewController at all.
//
// Parameters are pre-collected before close() executes.
private func teardownWindowContent(
    window: NSWindow,
    hostingVC: NSViewController?,
    textStorages: [NSTextStorage]
) {
    let key = ObjectIdentifier(window)
    var textStorages = textStorages

    // Nil contentViewController in an explicit pool. The hosting controller's
    // retain count drops to zero here, triggering NSHostingController →
    // NSTextView → NSLayoutManager dealloc while `hostingVC` (parameter, alive
    // for the entire function) and `textStorages` keep NSTextStorage live through
    // NSLayoutManager.dealloc's autorelease of glyph-cache objects.
    autoreleasepool {
        window.contentViewController = nil
        _ = hostingVC  // keep parameter alive through pool drain
    }

    // Release NSTextStorage now that NSLayoutManager is gone.
    autoreleasepool {
        textStorages.removeAll()
    }

    // Keep the now-empty window alive one more main-queue hop to outlast any
    // residual ARP drain, then release it trivially.
    _retainedWindows[key] = window
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        autoreleasepool {
            _ = _retainedWindows.removeValue(forKey: key)
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
            hosting.sizingOptions = []
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.contentViewController = hosting
            win.setContentSize(NSSize(width: 700, height: 900))
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.minSize = NSSize(width: 480, height: 640)
            win.animationBehavior = .none
            // Prevent close() from calling [window release] internally, which
            // corrupts contentViewController with an opaque proxy object even when
            // we still hold a strong reference.  We release the window ourselves.
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()
            win.makeKeyAndOrderFront(nil)
            self.window = win
        }

        func closeWindow() {
            guard let win = window else { return }
            win.delegate = nil
            // Collect refs BEFORE close() so contentViewController is still valid.
            let hostingVC = win.contentViewController
            var textStorages: [NSTextStorage] = []
            if let cv = hostingVC?.view {
                collectTextStorages(in: cv, into: &textStorages)
            }
            win.close()
            window = nil
            if let id = currentItemId { _openReaderItemIDs.remove(id) }
            currentItemId = nil
            // close() has returned; safe to tear down synchronously.
            teardownWindowContent(window: win, hostingVC: hostingVC, textStorages: textStorages)
        }

        func windowWillClose(_ notification: Notification) {
            guard let win = window else { return }
            if let id = currentItemId { _openReaderItemIDs.remove(id) }
            // Collect refs NOW while the view hierarchy is intact (mid-close is fine
            // for reads; it's writes/nils that cause the CFRunLoop-pool hazard).
            let hostingVC = win.contentViewController
            var textStorages: [NSTextStorage] = []
            if let cv = hostingVC?.view {
                collectTextStorages(in: cv, into: &textStorages)
            }
            window = nil
            currentItemId = nil
            onClose?()
            onClose = nil
            // Defer teardown to after close() fully unwinds so the CFRunLoop
            // per-callout pool drains before we nil the view hierarchy.
            // Captures win/hostingVC/textStorages by value — no reference to self.
            DispatchQueue.main.async {
                teardownWindowContent(window: win, hostingVC: hostingVC, textStorages: textStorages)
            }
        }
    }
}
#endif
