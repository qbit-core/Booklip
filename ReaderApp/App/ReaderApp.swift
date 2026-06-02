import SwiftUI
import Combine

@main
struct ReaderApp: App {
    @StateObject private var library = LibraryViewModel()
    @StateObject private var settings = ReadingSettings()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(settings)
        }
    }
}
