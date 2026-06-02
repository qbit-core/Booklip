import AuthenticationServices
import Foundation

/// Provides the window anchor for ASWebAuthenticationSession.
/// Kept as a separate @MainActor NSObject so OAuthSession itself
/// need not adopt the @MainActor-isolated presentation protocol.
@MainActor
final class AuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresentationProvider()
    var activeSession: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
#else
        NSApplication.shared.windows.first ?? ASPresentationAnchor()
#endif
    }
}

/// Lightweight OAuth 2.0 helper using ASWebAuthenticationSession.
enum OAuthSession {
    struct Token: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var isExpired: Bool { Date() >= expiresAt }
    }

    // MARK: - Authorization Code Flow (main thread — ASWebAuthenticationSession requires it)

    @MainActor
    static func authorize(
        authURL: URL,
        tokenURL: URL,
        clientID: String,
        redirectURI: String,
        scopes: [String]
    ) async throws -> Token {
        let state = UUID().uuidString
        var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id",     value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri",  value: redirectURI),
            .init(name: "scope",         value: scopes.joined(separator: " ")),
            .init(name: "state",         value: state),
            .init(name: "response_mode", value: "query"),
        ]

        let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: URL(string: redirectURI)!.scheme
            ) { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: error ?? OAuthError.cancelled) }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = AuthPresentationProvider.shared
            session.start()
            AuthPresentationProvider.shared.activeSession = session
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw OAuthError.noCode }

        return try await exchangeCode(code, tokenURL: tokenURL, clientID: clientID, redirectURI: redirectURI)
    }

    // MARK: - Token Exchange (pure networking)

    static func exchangeCode(_ code: String, tokenURL: URL, clientID: String, redirectURI: String) async throws -> Token {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type":  "authorization_code",
            "code":         code,
            "client_id":    clientID,
            "redirect_uri": redirectURI,
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
         .joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try parseToken(from: data)
    }

    static func refresh(_ token: Token, tokenURL: URL, clientID: String) async throws -> Token {
        guard let refreshToken = token.refreshToken else { throw OAuthError.noRefreshToken }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type":    "refresh_token",
            "refresh_token":  refreshToken,
            "client_id":      clientID,
        ].map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try parseToken(from: data)
    }

    // MARK: - Helpers

    private static func parseToken(from data: Data) throws -> Token {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String else { throw OAuthError.badResponse }
        let expires = (json["expires_in"] as? TimeInterval)
            .map { Date().addingTimeInterval($0) } ?? Date().addingTimeInterval(3600)
        return Token(accessToken: access, refreshToken: json["refresh_token"] as? String, expiresAt: expires)
    }
}

enum OAuthError: LocalizedError {
    case cancelled, noCode, noRefreshToken, badResponse
    var errorDescription: String? {
        switch self {
        case .cancelled:       return "Authentication was cancelled."
        case .noCode:          return "No authorization code returned."
        case .noRefreshToken:  return "No refresh token — please sign in again."
        case .badResponse:     return "Unexpected response from auth server."
        }
    }
}
