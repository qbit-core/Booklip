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

extension ToolbarItemPlacement {
    static var platformTrailing: ToolbarItemPlacement {
#if os(iOS)
        .topBarTrailing
#else
        .automatic
#endif
    }
}
