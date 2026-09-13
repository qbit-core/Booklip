import SwiftUI
import Combine

@main
struct BooklipApp: App {
    @StateObject private var library = LibraryViewModel()
    @StateObject private var settings = ReadingSettings()
#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#else
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif

    init() {
        // Cloud downloads run in a background URLSession. Attach early so a
        // relaunch-to-finish-a-transfer finds the session, and route files
        // that finish with no one awaiting them (app was terminated) into the
        // library exactly as a live import would.
        BackgroundDownloader.shared.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(settings)
                .onAppear {
                    let lib = library
                    BackgroundDownloader.shared.orphanHandler = { url, meta in
                        lib.importBook(from: url, intoFolderNamed: meta.folderName)
                    }
                }
        }
#if os(macOS)
        // Remove "New Window" from the File menu so the user can't manually
        // open a second Library window (⌘N), which would cause duplicate
        // reader windows when a book is opened.
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
#endif
    }
}

#if os(iOS)
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    /// The system relaunched (or woke) the app because a background download
    /// finished; hand the completion handler to the downloader, which calls it
    /// once every delegate event for the session has been delivered.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloader.sessionIdentifier else { completionHandler(); return }
        BackgroundDownloader.shared.backgroundCompletionHandler = completionHandler
        BackgroundDownloader.shared.warmUp()
    }
}
#endif

#if os(macOS)
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Prevent state restoration from opening a second Library window.
        // NSQuitAlwaysKeepsWindows=false stops future saves; deleting the
        // saved-state bundle clears any state that was saved before this fix,
        // so restoration has nothing to work with on this and every future launch.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        if let bundleID = Bundle.main.bundleIdentifier,
           let libDir = FileManager.default.urls(for: .libraryDirectory,
                                                 in: .userDomainMask).first {
            let stateURL = libDir
                .appendingPathComponent("Saved Application State")
                .appendingPathComponent("\(bundleID).savedState")
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Safety net: if state restoration still managed to open extra Library
        // windows (e.g. debug sandbox, first run before saved-state was deleted),
        // close all but the key (front) window. Reader windows have a transparent
        // titlebar; Library windows do not — use that to distinguish the two.
        DispatchQueue.main.async {
            let key = NSApplication.shared.keyWindow
            for window in NSApplication.shared.windows
            where window !== key && window.isVisible && !window.titlebarAppearsTransparent {
                window.close()
            }
        }
    }
}
#endif
