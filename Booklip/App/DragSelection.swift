import SwiftUI

// Photos-style drag selection for grids and lists in a "Select" mode.
//
// Each selectable cell reports its frame (`.dragSelectItem(id)`), the container
// listens for a drag (`.dragSelection(...)`). A drag that starts mostly
// horizontal engages selection: the first cell under the finger decides
// whether the sweep selects or deselects, and every cell the finger crosses
// afterwards gets the same state. A vertical drag is left to the scroll view.

private struct DragSelectFramesKey: PreferenceKey {
    static let defaultValue: [AnyHashable: CGRect] = [:]
    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private let dragSelectSpace = "booklip.dragSelect"

private struct DragSelectItem<ID: Hashable>: ViewModifier {
    let id: ID
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear.preference(key: DragSelectFramesKey.self,
                                       value: [AnyHashable(id): geo.frame(in: .named(dragSelectSpace))])
            }
        )
    }
}

private struct DragSelectContainer<ID: Hashable>: ViewModifier {
    let enabled: Bool
    let isSelected: (ID) -> Bool
    let setSelected: (ID, Bool) -> Void

    @State private var frames: [AnyHashable: CGRect] = [:]
    @State private var engaged = false
    @State private var decided = false      // direction decided (engaged or scrolling)
    @State private var target = true        // state applied to swept cells
    @State private var visited: Set<AnyHashable> = []

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: dragSelectSpace)
            .onPreferenceChange(DragSelectFramesKey.self) { frames = $0 }
            .simultaneousGesture(enabled ? drag : nil)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(dragSelectSpace))
            .onChanged { value in
                if !decided {
                    let dx = abs(value.translation.width), dy = abs(value.translation.height)
                    guard dx + dy >= 6 else { return }
                    decided = true
                    guard dx > dy, let start = item(at: value.startLocation) else { return }
                    engaged = true
                    target = !isSelected(start)
                    apply(start)
                }
                guard engaged, let id = item(at: value.location) else { return }
                apply(id)
            }
            .onEnded { _ in
                engaged = false
                decided = false
                visited.removeAll()
            }
    }

    private func item(at point: CGPoint) -> ID? {
        frames.first { $0.value.contains(point) }?.key.base as? ID
    }

    private func apply(_ id: ID) {
        let key = AnyHashable(id)
        guard !visited.contains(key) else { return }
        visited.insert(key)
        if isSelected(id) != target { setSelected(id, target) }
    }
}

extension View {
    /// Marks a cell as a drag-selection target identified by `id`.
    func dragSelectItem<ID: Hashable>(_ id: ID) -> some View {
        modifier(DragSelectItem(id: id))
    }

    /// Enables Photos-style sweep selection over the cells inside this view.
    func dragSelection<ID: Hashable>(enabled: Bool,
                                     isSelected: @escaping (ID) -> Bool,
                                     setSelected: @escaping (ID, Bool) -> Void) -> some View {
        modifier(DragSelectContainer(enabled: enabled, isSelected: isSelected, setSelected: setSelected))
    }
}
