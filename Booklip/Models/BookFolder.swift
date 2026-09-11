import Foundation

struct BookFolder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var dateCreated: Date = Date()

    enum CodingKeys: String, CodingKey { case id, name, dateCreated }

    init(name: String) {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decodeIfPresent(UUID.self,   forKey: .id)          ?? UUID()
        name        = try c.decode(String.self,          forKey: .name)
        dateCreated = try c.decodeIfPresent(Date.self,   forKey: .dateCreated) ?? Date()
    }
}
