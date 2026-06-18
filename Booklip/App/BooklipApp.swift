import SwiftUI
import Combine

@main
struct BooklipApp: App {
    @StateObject private var library = LibraryViewModel()
    @StateObject private var settings = ReadingSettings()
#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(settings)
        }
    }
}

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
}
#endif
