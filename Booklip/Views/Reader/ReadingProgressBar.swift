import SwiftUI

struct ReadingProgressBar: View {
    @Binding var progress: Double
    @State private var isDragging = false
    // Visual-only position during drag; committed to the binding only on onEnded.
    @State private var dragProgress: Double? = nil

    private var displayProgress: Double { dragProgress ?? progress }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: isDragging ? 8 : 4)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(displayProgress), height: isDragging ? 8 : 4)

                // Thumb
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: isDragging ? 20 : 0, height: isDragging ? 20 : 0)
                    .offset(x: geo.size.width * CGFloat(displayProgress) - (isDragging ? 10 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isDragging)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragProgress = min(max(value.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { value in
                        let finalProgress = min(max(value.location.x / geo.size.width, 0), 1)
                        dragProgress = nil
                        isDragging = false
                        progress = finalProgress
                    }
            )
        }
        .frame(height: 20)
        .padding(.horizontal)
        .animation(.easeInOut(duration: 0.15), value: isDragging)
    }
}
