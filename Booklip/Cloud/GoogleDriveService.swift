import Foundation
import Combine

final class GoogleDriveService: ObservableObject {
    @Published var isSignedIn = false
    @Published var isLoading  = false
    @Published var error: String?

    private let tokenKey = "gdrive_token"
    private var token: OAuthSession.Token? {
        get { load() }
        set { save(newValue) }
    }

    private static let authURL  = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let apiBase  = "https://www.googleapis.com/drive/v3"

    init() { isSignedIn = token != nil }

    // MARK: - Auth

    @MainActor func signIn() async {
        do {
            let t = try await OAuthSession.authorize(
                authURL: Self.authURL,
                tokenURL: Self.tokenURL,
                clientID: CloudConfig.googleClientID,
                redirectURI: CloudConfig.googleRedirectURI,
                scopes: ["https://www.googleapis.com/auth/drive.readonly"]
            )
            token = t
            isSignedIn = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor func signOut() {
        token = nil
        isSignedIn = false
    }

    // MARK: - Files

    func files(folderID: String = "root") async throws -> [CloudFile] {
        let accessToken = try await validAccessToken()
        let query = "'\(folderID)' in parents and trashed = false".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let fields = "nextPageToken,files(id,name,size,mimeType,webContentLink)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        // Follow nextPageToken; a single page hid everything past 100 entries.
        var results: [CloudFile] = []
        var pageToken: String? = nil
        for _ in 0..<50 {
            var urlString = "\(Self.apiBase)/files?q=\(query)&fields=\(fields)&pageSize=100"
            if let pageToken { urlString += "&pageToken=\(pageToken)" }
            var req = URLRequest(url: URL(string: urlString)!)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let items = json["files"] as? [[String: Any]] ?? []
            results += items.compactMap { item in
                guard let id   = item["id"]   as? String,
                      let name = item["name"] as? String,
                      let mime = item["mimeType"] as? String else { return nil }
                return CloudFile(
                    id: id, name: name,
                    isFolder: mime == "application/vnd.google-apps.folder",
                    size: item["size"].flatMap { Int64("\($0)") },
                    downloadURL: item["webContentLink"] as? String,
                    mimeType: mime
                )
            }
            guard let next = json["nextPageToken"] as? String, !next.isEmpty else { break }
            pageToken = next
        }
        return results
    }

    func download(_ file: CloudFile) async throws -> URL {
        let accessToken = try await validAccessToken()
        // Google Docs native formats can't be downloaded directly — only binary files
        var req = URLRequest(url: URL(string: "\(Self.apiBase)/files/\(file.id)?alt=media")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CloudError.downloadFailed
        }
        return try writeTempFile(data, name: file.name)
    }

    // MARK: - Helpers

    private func validAccessToken() async throws -> String {
        guard let t = token else { throw CloudError.notSignedIn }
        if t.isExpired {
            do {
                var refreshed = try await OAuthSession.refresh(t, tokenURL: Self.tokenURL, clientID: CloudConfig.googleClientID)
                if refreshed.refreshToken == nil { refreshed.refreshToken = t.refreshToken }
                token = refreshed
                return refreshed.accessToken
            } catch OAuthError.refreshRejected {
                // Only an explicit rejection ends the session; transient errors
                // (offline, 5xx) propagate and keep the tokens.
                await MainActor.run { self.signOut() }
                throw CloudError.notSignedIn
            }
        }
        return t.accessToken
    }

    private func writeTempFile(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func save(_ t: OAuthSession.Token?) {
        if let t, let data = try? JSONEncoder().encode(t) {
            UserDefaults.standard.set(data, forKey: tokenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: tokenKey)
        }
    }

    private func load() -> OAuthSession.Token? {
        guard let data = UserDefaults.standard.data(forKey: tokenKey) else { return nil }
        return try? JSONDecoder().decode(OAuthSession.Token.self, from: data)
    }
}

enum CloudError: LocalizedError {
    case notSignedIn, downloadFailed
    var errorDescription: String? {
        switch self {
        case .notSignedIn:    return "Not signed in. Please connect your account first."
        case .downloadFailed: return "File download failed."
        }
    }
}
