import Foundation

enum BookStore {
    static let documentsDirectory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    private static let listKey    = "savedBooks"
    private static let folderKey  = "savedFolders"

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
    }

    static func loadFolders() -> [BookFolder] {
        guard let data = UserDefaults.standard.data(forKey: folderKey),
              let folders = try? JSONDecoder().decode([BookFolder].self, from: data)
        else { return [] }
        return folders
    }

    static func saveFolders(_ folders: [BookFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: folderKey)
    }
}
