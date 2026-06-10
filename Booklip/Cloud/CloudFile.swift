import Foundation

struct CloudFile: Identifiable, Hashable {
    let id: String
    let name: String
    let isFolder: Bool
    let size: Int64?
    let downloadURL: String?
    let mimeType: String?

    var isSupportedBook: Bool {
        guard !isFolder else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["txt", "epub", "pdf", "md", "markdown"].contains(ext)
    }

    var formatIcon: String {
        switch (name as NSString).pathExtension.lowercased() {
        case "epub":            return "book.closed"
        case "pdf":             return "doc.richtext"
        case "txt":             return "doc.text"
        case "md", "markdown":  return "text.alignleft"
        default:                return isFolder ? "folder.fill" : "doc"
        }
    }
}
