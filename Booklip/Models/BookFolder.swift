import Foundation

struct BookFolder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var dateCreated: Date = Date()
}
