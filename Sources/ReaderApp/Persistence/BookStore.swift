import Foundation

enum BookStore {
    static let documentsDirectory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    private static let listKey = "savedBooks"

    static func load() -> [Book] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let books = try? JSONDecoder().decode([Book].self, from: data)
        else { return [] }
        return books
    }

    static func save(_ books: [Book]) {
        guard let data = try? JSONEncoder().encode(books) else { return }
        UserDefaults.standard.set(data, forKey: listKey)
    }

    // Copies the file into Documents and returns the destination fileName.
    static func importFile(from url: URL) throws -> String {
        let fileName = UUID().uuidString + "." + url.pathExtension
        let destination = documentsDirectory.appendingPathComponent(fileName)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: destination)
        return fileName
    }

    static func delete(book: Book) {
        try? FileManager.default.removeItem(at: book.fileURL)
        // feature 8: also remove cover thumbnail if present
        if let cover = book.coverImageFileName {
            try? FileManager.default.removeItem(at: documentsDirectory.appendingPathComponent(cover))
        }
    }

    // feature 8: persist a PNG thumbnail and return its file name
    static func saveCoverImage(_ pngData: Data, bookID: UUID) -> String {
        let fileName = bookID.uuidString + "_cover.png"
        try? pngData.write(to: documentsDirectory.appendingPathComponent(fileName))
        return fileName
    }

    static func coverImageURL(fileName: String) -> URL {
        documentsDirectory.appendingPathComponent(fileName)
    }
}
