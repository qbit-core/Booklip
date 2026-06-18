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
        // SwiftUI's WindowGroup opens one window on every launch; macOS state
        // restoration would re-open the previous session's window alongside it,
        // resulting in two Library windows. Opt out of window restoration.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
}
#endif
