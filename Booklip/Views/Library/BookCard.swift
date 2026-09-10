import SwiftUI

struct BookCard: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                if let cover = coverImage {
                    cover
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(coverColor)
                        .overlay(alignment: .bottomLeading) {
                            Text(book.title)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.ultraThinMaterial)
                        }
                }
                formatBadge
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(2.0/3.0, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private var coverImage: Image? { BookCover.image(for: book) }

    private var coverColor: Color {
        let colors: [Color] = [.indigo, .teal, .orange, .pink, .purple, .green, .blue]
        let index = abs(book.title.hashValue) % colors.count
        return colors[index]
    }
}

// Cross-platform cover image loader from a saved file.
enum BookCover {
    static func image(for book: Book) -> Image? {
        guard let url = book.coverURL,
              let data = try? Data(contentsOf: url) else { return nil }
#if os(iOS)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
#elseif os(macOS)
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
#else
        return nil
#endif
    }
}
