import Foundation

/// Persisted charsPerPage calibration keyed by layout parameters.
/// Built from median of measured page-turn deltas; used as the seed
/// for estimatedTotalPages before BookPaginator completes.
struct PaginationProfile {
    let charsPerPage: Int

    static func key(fontName: String, fontSize: Double, lineSpacing: Double,
                    textAreaW: Double, textAreaH: Double) -> String {
        "\(fontName)|\(fontSize)|\(lineSpacing)|\(Int(textAreaW))x\(Int(textAreaH))"
    }

    private static let udKey = "PaginationProfiles_v2"

    static func load(key: String) -> PaginationProfile? {
        guard let dict = UserDefaults.standard.dictionary(forKey: udKey),
              let val = dict[key] as? Int, val > 0 else { return nil }
        return PaginationProfile(charsPerPage: val)
    }

    static func save(charsPerPage: Int, key: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: udKey) as? [String: Int]) ?? [:]
        dict[key] = charsPerPage
        UserDefaults.standard.set(dict, forKey: udKey)
    }
}
