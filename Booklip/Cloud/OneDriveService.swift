import Foundation
import Combine

final class OneDriveService: ObservableObject {
    @Published var isSignedIn = false
    @Published var isLoading  = false
    @Published var error: String?

    private let tokenKey = "onedrive_token"
    private var token: OAuthSession.Token? {
        get { load() }
        set { save(newValue) }
    }

    private static let authURL   = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
    private static let tokenURL  = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
    private static let graphBase = "https://graph.microsoft.com/v1.0"

    init() { isSignedIn = token != nil }

    // MARK: - Auth

    @MainActor func signIn() async {
        do {
            let t = try await OAuthSession.authorize(
                authURL: Self.authURL,
                tokenURL: Self.tokenURL,
                clientID: CloudConfig.oneDriveClientID,
                redirectURI: CloudConfig.oneDriveRedirectURI,
                scopes: ["Files.Read", "offline_access"]
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

    func files(folderID: String? = nil) async throws -> [CloudFile] {
        let accessToken = try await validAccessToken()
        let path = folderID.map { "/me/drive/items/\($0)/children" } ?? "/me/drive/root/children"
        // Follow @odata.nextLink; a single page hid everything past 100 entries.
        var nextURL: URL? = URL(string: "\(Self.graphBase)\(path)?$select=id,name,size,folder,file,@microsoft.graph.downloadUrl&$top=100")
        var results: [CloudFile] = []
        var pages = 0
        while let url = nextURL, pages < 50 {
            pages += 1
            var req = URLRequest(url: url)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let items = json["value"] as? [[String: Any]] ?? []
            results += items.compactMap { item in
                guard let id   = item["id"]   as? String,
                      let name = item["name"] as? String else { return nil }
                return CloudFile(
                    id: id, name: name,
                    isFolder: item["folder"] != nil,
                    size: (item["size"] as? Int64),
                    downloadURL: item["@microsoft.graph.downloadUrl"] as? String,
                    mimeType: (item["file"] as? [String: Any])?["mimeType"] as? String
                )
            }
            nextURL = (json["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        return results
    }

    func download(_ file: CloudFile) async throws -> URL {
        // Both branches must check the status: a 401 (stale token) or 404/410
        // (expired pre-authenticated downloadUrl) returns a JSON error body that
        // was previously written out and imported as the "book".
        let data: Data
        let response: URLResponse
        if let urlString = file.downloadURL, let url = URL(string: urlString) {
            (data, response) = try await URLSession.shared.data(from: url)
        } else {
            // Fall back to Graph API download
            let accessToken = try await validAccessToken()
            var req = URLRequest(url: URL(string: "\(Self.graphBase)/me/drive/items/\(file.id)/content")!)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            (data, response) = try await URLSession.shared.data(for: req)
        }
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
                var refreshed = try await OAuthSession.refresh(t, tokenURL: Self.tokenURL, clientID: CloudConfig.oneDriveClientID)
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
