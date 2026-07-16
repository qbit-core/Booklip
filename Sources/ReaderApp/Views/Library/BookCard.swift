import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct BookCard: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                // feature 8: show PDF cover thumbnail if available, else color placeholder
                coverView
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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

    @ViewBuilder
    private var coverView: some View {
        if let fileName = book.coverImageFileName,
           let image = loadCoverImage(fileName: fileName) {
            image
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(coverColor)
        }
    }

    private func loadCoverImage(fileName: String) -> Image? {
        let url = BookStore.coverImageURL(fileName: fileName)
        #if os(iOS)
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
        #elseif os(macOS)
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
        #endif
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
