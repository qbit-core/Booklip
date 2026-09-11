import Foundation

enum BookStore {
    static let documentsDirectory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    private static let listKey    = "savedBooks"
    private static let folderKey  = "savedFolders"

    static func load() -> [Book] {
        guard let data = UserDefaults.standard.data(forKey: listKey) else { return [] }
        let decoder = JSONDecoder()
        // Fast path: all books decode successfully.
        if let books = try? decoder.decode([Book].self, from: data) { return books }
        // Fallback: decode each element individually so a single corrupt entry
        // (e.g. from a schema mismatch) does not wipe the entire library.
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let recovered = raw.compactMap { dict -> Book? in
                guard let elem = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? decoder.decode(Book.self, from: elem)
            }
            if !recovered.isEmpty { return recovered }
        }
        return []
    }

    static func save(_ books: [Book]) {
        guard let data = try? JSONEncoder().encode(books) else { return }
        UserDefaults.standard.set(data, forKey: listKey)
    }

    // Copies the file into Documents and returns the destination fileName.
    static func importFile(from url: URL) throws -> String {
        let fileName = UUID().uuidString + "." + url.pathExtension
        let destination = documentsDirectory.appendingPathComponent(fileName)
        // Security-scoped resource access (needed for files picked via document picker)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return fileName
    }

    static func delete(book: Book) {
        try? FileManager.default.removeItem(at: book.fileURL)
        if let cover = book.coverURL { try? FileManager.default.removeItem(at: cover) }
        let id = book.id.uuidString
        let ud = UserDefaults.standard
        ud.removeObject(forKey: "settings_\(id)")
        ud.removeObject(forKey: bookmarkKey(book.id))
        ud.removeObject(forKey: "highlights_\(id)")
    }

    // Saves cover image data and returns its file name.
    static func saveCover(_ data: Data, for fileName: String) -> String? {
        let coverName = (fileName as NSString).deletingPathExtension + "_cover.img"
        let url = documentsDirectory.appendingPathComponent(coverName)
        do { try data.write(to: url); return coverName } catch { return nil }
    }

    // MARK: - Per-book appearance settings

    struct BookSettings: Codable {
        var fontName: String
        var fontSize: Double
        var lineSpacing: Double
        var presetId: String
    }

    static func loadSettings(_ bookID: UUID) -> BookSettings? {
        guard let data = UserDefaults.standard.data(forKey: "settings_\(bookID.uuidString)") else { return nil }
        return try? JSONDecoder().decode(BookSettings.self, from: data)
    }

    static func saveSettings(_ s: BookSettings, for bookID: UUID) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: "settings_\(bookID.uuidString)")
    }

    // MARK: - Bookmarks

    private static func bookmarkKey(_ bookID: UUID) -> String { "bookmarks_\(bookID.uuidString)" }

    static func loadBookmarks(_ bookID: UUID) -> [Bookmark] {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey(bookID)),
              let list = try? JSONDecoder().decode([Bookmark].self, from: data)
        else { return [] }
        return list.sorted { $0.progress < $1.progress }
    }

    static func saveBookmarks(_ bookmarks: [Bookmark], for bookID: UUID) {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey(bookID))
    }

    // MARK: - Highlights

    static func loadHighlights(_ bookID: UUID) -> [Highlight] {
        guard let data = UserDefaults.standard.data(forKey: "highlights_\(bookID.uuidString)"),
              let list = try? JSONDecoder().decode([Highlight].self, from: data)
        else { return [] }
        return list.sorted { $0.progress < $1.progress }
    }

    static func saveHighlights(_ highlights: [Highlight], for bookID: UUID) {
        guard let data = try? JSONEncoder().encode(highlights) else { return }
        UserDefaults.standard.set(data, forKey: "highlights_\(bookID.uuidString)")
    }

    static func loadFolders() -> [BookFolder] {
        guard let data = UserDefaults.standard.data(forKey: folderKey) else { return [] }
        let decoder = JSONDecoder()
        if let folders = try? decoder.decode([BookFolder].self, from: data) { return folders }
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let recovered = raw.compactMap { dict -> BookFolder? in
                guard let elem = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                return try? decoder.decode(BookFolder.self, from: elem)
            }
            if !recovered.isEmpty { return recovered }
        }
        return []
    }

    static func saveFolders(_ folders: [BookFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: folderKey)
    }
}
