import SwiftUI

struct ReadingProgressBar: View {
    @Binding var progress: Double
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: isDragging ? 8 : 4)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(progress), height: isDragging ? 8 : 4)

                // Thumb
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: isDragging ? 20 : 0, height: isDragging ? 20 : 0)
                    .offset(x: geo.size.width * CGFloat(progress) - (isDragging ? 10 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isDragging)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        progress = min(max(value.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: 20)
        .padding(.horizontal)
        .animation(.easeInOut(duration: 0.15), value: isDragging)
    }
}
