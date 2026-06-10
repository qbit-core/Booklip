import Foundation
import Combine

final class DropboxService: ObservableObject {
    @Published var isSignedIn = false
    @Published var isLoading  = false
    @Published var error: String?

    private let tokenKey = "dropbox_token"
    private var token: OAuthSession.Token? {
        get { load() }
        set { save(newValue) }
    }

    private static let authURL   = URL(string: "https://www.dropbox.com/oauth2/authorize")!
    private static let tokenURL  = URL(string: "https://api.dropboxapi.com/oauth2/token")!
    private static let listURL   = URL(string: "https://api.dropboxapi.com/2/files/list_folder")!
    private static let downloadURL = URL(string: "https://content.dropboxapi.com/2/files/download")!

    init() { isSignedIn = token != nil }

    // MARK: - Auth

    @MainActor func signIn() async {
        do {
            // token_access_type=offline gives a refresh token
            var authURL = URLComponents(url: Self.authURL, resolvingAgainstBaseURL: false)!
            authURL.queryItems = [.init(name: "token_access_type", value: "offline")]
            let t = try await OAuthSession.authorize(
                authURL: authURL.url!,
                tokenURL: Self.tokenURL,
                clientID: CloudConfig.dropboxClientID,
                redirectURI: CloudConfig.dropboxRedirectURI,
                scopes: ["files.metadata.read", "files.content.read"]
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

    func files(folderID: String?) async throws -> [CloudFile] {
        let accessToken = try await validAccessToken()
        // Dropbox identifies folders by path; root is the empty string.
        let path = folderID ?? ""
        var req = URLRequest(url: Self.listURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": path,
            "limit": 200,
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let entries = json["entries"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let tag  = entry[".tag"] as? String,
                  let name = entry["name"] as? String,
                  let lower = entry["path_lower"] as? String else { return nil }
            let isFolder = (tag == "folder")
            return CloudFile(
                id: lower,                       // use path as the identifier
                name: name,
                isFolder: isFolder,
                size: entry["size"] as? Int64,
                downloadURL: nil,
                mimeType: nil
            )
        }
    }

    func download(_ file: CloudFile) async throws -> URL {
        let accessToken = try await validAccessToken()
        var req = URLRequest(url: Self.downloadURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // Dropbox download takes its argument as a header, not a body
        let arg = try JSONSerialization.data(withJSONObject: ["path": file.id])
        req.setValue(String(data: arg, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")
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
                var refreshed = try await OAuthSession.refresh(t, tokenURL: Self.tokenURL, clientID: CloudConfig.dropboxClientID)
                if refreshed.refreshToken == nil { refreshed.refreshToken = t.refreshToken } // preserve
                token = refreshed
                return refreshed.accessToken
            } catch {
                // Session is no longer valid — reflect that in the UI.
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

extension DropboxService: CloudBrowserService {}
