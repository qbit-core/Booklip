import SwiftUI

struct BookCard: View {
    let book: Book

    var body: some View {
        // Outer aspect ratio fixes the ENTIRE card size so every card in the
        // grid is the same height — cover (2:3) occupies the top 3/4,
        // the text strip fills the remaining 1/4 and is clipped if needed.
        Color.clear
            .aspectRatio(1.0/2.0, contentMode: .fit)
            .overlay(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    // Cover — always 2:3 of card width
                    Color.clear
                        .aspectRatio(2.0/3.0, contentMode: .fit)
                        .overlay {
                            if let cover = coverImage {
                                cover.resizable().scaledToFill()
                            } else {
                                coverColor
                                    .overlay(alignment: .bottomLeading) {
                                        Text(book.title)
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(.ultraThinMaterial)
                                    }
                            }
                        }
                        .overlay(alignment: .bottomTrailing) { formatBadge }
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Text strip — fixed height, single-line title
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(book.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if book.progress > 0 {
                            ProgressView(value: book.progress)
                                .tint(.accentColor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
