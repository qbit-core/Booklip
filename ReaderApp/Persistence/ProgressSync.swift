import Foundation

// Syncs per-book reading progress across devices via iCloud key-value store.
// Books have per-device UUIDs, so we key on a stable content signature
// (title + author + word count) instead of the local id.
enum ProgressSync {
    // Only touch iCloud KVS when iCloud is actually configured/signed in.
    // Without it, accessing NSUbiquitousKeyValueStore logs "BUG IN CLIENT OF KVS".
    private static var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    private static let store = NSUbiquitousKeyValueStore.default

    struct Entry: Codable {
        var progress: Double
        var updated: Date
    }

    static func signature(for book: Book) -> String {
        "p_" + "\(book.title)|\(book.author)|\(book.wordCount)"
            .data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    static func push(_ book: Book) {
        guard isAvailable else { return }
        let entry = Entry(progress: book.progress, updated: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        store.set(data, forKey: signature(for: book))
        store.synchronize()
    }

    /// Returns the cloud progress if it is newer than the local copy.
    static func newerProgress(for book: Book, localUpdated: Date) -> Double? {
        guard isAvailable,
              let data = store.data(forKey: signature(for: book)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.updated > localUpdated,
              abs(entry.progress - book.progress) > 0.001
        else { return nil }
        return entry.progress
    }

    static func startObserving(_ handler: @escaping () -> Void) {
        guard isAvailable else { return }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { _ in handler() }
        store.synchronize()
    }
}
