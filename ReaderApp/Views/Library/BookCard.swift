import SwiftUI

struct BookCard: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(coverColor)
                    .frame(height: 200)
                Text(book.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(4)
                formatBadge
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(book.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if book.progress > 0 {
                    ProgressView(value: book.progress)
                        .tint(.accentColor)
                }
            }
        }
        .background(Color(white: 1.0))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    private var formatBadge: some View {
        Text(book.format.displayName)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(8)
    }

    private var coverColor: Color {
        let colors: [Color] = [.indigo, .teal, .orange, .pink, .purple, .green, .blue]
        let index = abs(book.title.hashValue) % colors.count
        return colors[index]
    }
}
