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
        var req = URLRequest(url: URL(string: "\(Self.graphBase)\(path)?$select=id,name,size,folder,file,@microsoft.graph.downloadUrl&$top=100")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let items = json["value"] as? [[String: Any]] ?? []
        return items.compactMap { item in
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
    }

    func download(_ file: CloudFile) async throws -> URL {
        guard let urlString = file.downloadURL, let url = URL(string: urlString) else {
            // Fall back to Graph API download
            let accessToken = try await validAccessToken()
            var req = URLRequest(url: URL(string: "\(Self.graphBase)/me/drive/items/\(file.id)/content")!)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            return try writeTempFile(data, name: file.name)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try writeTempFile(data, name: file.name)
    }

    // MARK: - Helpers

    private func validAccessToken() async throws -> String {
        guard var t = token else { throw CloudError.notSignedIn }
        if t.isExpired {
            t = try await OAuthSession.refresh(t, tokenURL: Self.tokenURL, clientID: CloudConfig.oneDriveClientID)
            token = t
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
