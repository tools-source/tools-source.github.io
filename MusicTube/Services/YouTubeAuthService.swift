import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

final class YouTubeAuthService: NSObject, AuthProviding {
    private enum Constants {
        static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
        static let userInfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
        static let scope = [
            "openid",
            "email",
            "profile",
            "https://www.googleapis.com/auth/youtube.readonly"
        ].joined(separator: " ")
    }

    private enum Keys {
        static let legacySessionData = "musictube.youtube.session"
        static let keychainAccount = "youtube.session"
    }

    enum AuthError: LocalizedError {
        case missingConfig(String)
        case placeholderConfig(String)
        case invalidClientIDFormat
        case failedToStartSession
        case missingCode
        case invalidCallback
        case invalidTokenResponse

        var errorDescription: String? {
            switch self {
            case .missingConfig(let key):
                return "Missing \(key) in Info.plist"
            case .placeholderConfig(let key):
                return "\(key) still uses the checked-in placeholder value. Replace it in MusicTube/Resources/Secrets.local.xcconfig before signing in."
            case .invalidClientIDFormat:
                return "YOUTUBE_CLIENT_ID does not look like a Google OAuth client ID. It should usually end with .apps.googleusercontent.com."
            case .failedToStartSession:
                return "Could not start OAuth session"
            case .missingCode:
                return "OAuth callback was missing an authorization code"
            case .invalidCallback:
                return "OAuth callback URL was invalid"
            case .invalidTokenResponse:
                return "Token response was invalid"
            }
        }
    }

    private let urlSession: URLSession
    private var authSession: ASWebAuthenticationSession?
    private weak var presentationWindow: UIWindow?

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        super.init()
    }

    func restoreSession() async -> YouTubeSession? {
        guard
            let data = loadStoredSessionData(),
            let session = try? JSONDecoder().decode(YouTubeSession.self, from: data)
        else {
            return nil
        }

        if session.isExpired == false {
            return session
        }

        do {
            let refreshedSession = try await refreshSession(from: session)
            persistSession(refreshedSession)
            return refreshedSession
        } catch {
            clearStoredSession()
            return nil
        }
    }

    func signIn() async throws -> YouTubeSession {
        let clientID = try configValue(for: "YOUTUBE_CLIENT_ID")
        let redirectURIString = try configValue(for: "YOUTUBE_REDIRECT_URI")

        guard let redirectURI = URL(string: redirectURIString), let callbackScheme = redirectURI.scheme else {
            throw AuthError.invalidCallback
        }

        let codeVerifier = Self.randomURLSafeString(length: 96)
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let state = Self.randomURLSafeString(length: 24)

        var authComponents = URLComponents(url: Constants.authEndpoint, resolvingAgainstBaseURL: false)
        authComponents?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURIString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Constants.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authURL = authComponents?.url else {
            throw AuthError.invalidCallback
        }

        let callbackURL = try await beginWebAuth(url: authURL, callbackScheme: callbackScheme)
        let code = try Self.authorizationCode(from: callbackURL, expectedState: state)

        let tokenParams: [String: String] = [
            "client_id": clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURIString
        ]

        var request = URLRequest(url: Constants.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = tokenParams.formURLEncodedData

        let (tokenData, _) = try await urlSession.data(for: request)
        let token = try JSONDecoder().decode(TokenResponse.self, from: tokenData)

        guard let accessToken = token.accessToken, let expiresIn = token.expiresIn else {
            throw AuthError.invalidTokenResponse
        }

        var userRequest = URLRequest(url: Constants.userInfoEndpoint)
        userRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (userData, _) = try await urlSession.data(for: userRequest)
        let user = try JSONDecoder().decode(YouTubeUser.self, from: userData)

        let session = YouTubeSession(
            accessToken: accessToken,
            refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            user: user
        )

        persistSession(session)
        return session
    }

    func signOut() async {
        clearStoredSession()
    }

    private func refreshSession(from session: YouTubeSession) async throws -> YouTubeSession {
        guard let refreshToken = session.refreshToken, refreshToken.isEmpty == false else {
            throw AuthError.invalidTokenResponse
        }

        let clientID = try configValue(for: "YOUTUBE_CLIENT_ID")
        let tokenParams: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]

        var request = URLRequest(url: Constants.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = tokenParams.formURLEncodedData

        let (tokenData, _) = try await urlSession.data(for: request)
        let token = try JSONDecoder().decode(TokenResponse.self, from: tokenData)

        guard let accessToken = token.accessToken, let expiresIn = token.expiresIn else {
            throw AuthError.invalidTokenResponse
        }

        return YouTubeSession(
            accessToken: accessToken,
            refreshToken: token.refreshToken ?? session.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            user: session.user
        )
    }

    private func loadStoredSessionData() -> Data? {
        if let keychainData = keychainSessionData() {
            return keychainData
        }

        guard let legacyData = UserDefaults.standard.data(forKey: Keys.legacySessionData) else {
            return nil
        }

        if storeSessionDataInKeychain(legacyData) {
            UserDefaults.standard.removeObject(forKey: Keys.legacySessionData)
        }

        return legacyData
    }

    private func persistSession(_ session: YouTubeSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }

        _ = storeSessionDataInKeychain(data)
        UserDefaults.standard.removeObject(forKey: Keys.legacySessionData)
    }

    private func clearStoredSession() {
        let _ = SecItemDelete(keychainQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: Keys.legacySessionData)
    }

    private func keychainSessionData() -> Data? {
        var query = keychainQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private func storeSessionDataInKeychain(_ data: Data) -> Bool {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = keychainQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.codex.MusicTube"),
            kSecAttrAccount as String: Keys.keychainAccount
        ]
    }

    private func beginWebAuth(url: URL, callbackScheme: String) async throws -> URL {
        let presentationAnchor = await MainActor.run { currentPresentationAnchor() }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.resume(throwing: AuthError.failedToStartSession)
                    return
                }

                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                    defer {
                        self?.authSession = nil
                        self?.presentationWindow = nil
                    }

                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let callbackURL else {
                        continuation.resume(throwing: AuthError.invalidCallback)
                        return
                    }

                    continuation.resume(returning: callbackURL)
                }

                self.presentationWindow = presentationAnchor
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.authSession = session

                if session.start() == false {
                    self.authSession = nil
                    self.presentationWindow = nil
                    continuation.resume(throwing: AuthError.failedToStartSession)
                }
            }
        }
    }

    @MainActor
    private func currentPresentationAnchor() -> UIWindow {
        let allWindowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        if let keyWindow = allWindowScenes
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: \.isKeyWindow) {
            return keyWindow
        }

        if let firstWindow = allWindowScenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? allWindowScenes.flatMap(\.windows).first {
            return firstWindow
        }

        return UIWindow(frame: .zero)
    }

    private func configValue(for key: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, value.isEmpty == false else {
            throw AuthError.missingConfig(key)
        }

        if value.hasPrefix("YOUR_") {
            throw AuthError.placeholderConfig(key)
        }

        if key == "YOUTUBE_CLIENT_ID", value.hasSuffix(".apps.googleusercontent.com") == false {
            throw AuthError.invalidClientIDFormat
        }

        return value
    }

    private static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw AuthError.invalidCallback
        }

        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard returnedState == expectedState else {
            throw AuthError.invalidCallback
        }

        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.missingCode
        }

        return code
    }

    private static func randomURLSafeString(length: Int) -> String {
        let charset = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0 ..< length).compactMap { _ in charset.randomElement() })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString
    }
}

extension YouTubeAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationWindow ?? ASPresentationAnchor()
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private extension Dictionary where Key == String, Value == String {
    var formURLEncodedData: Data? {
        let body = map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")

        return body.data(using: .utf8)
    }
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
