import Foundation

struct Bookmark: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var bookID: UUID
    var progress: Double      // 0...1 position in the book
    var snippet: String       // short text preview at that position
    var date: Date = Date()
}
