import SwiftUI

struct Highlight: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var bookID: UUID
    var location: Int          // UTF-16 location in the rendered text storage
    var length: Int
    var colorName: String      // see HighlightColor
    var snippet: String
    var progress: Double
    var date: Date = Date()

    var range: NSRange { NSRange(location: location, length: length) }
}

enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        case .pink:   return .pink
        }
    }
}
