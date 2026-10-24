import Foundation
import CryptoKit

/// OAuth 2.0 for installed apps: browser consent, PKCE, and a loopback redirect to 127.0.0.1.
/// Uses the user's own "Desktop app" OAuth client from Google Cloud Console.
public final class GoogleOAuth {
    public struct Client {
        public var id: String
        public var secret: String
        public init(id: String, secret: String) { self.id = id; self.secret = secret }
    }

    public struct Grant {
        public var refreshToken: String
        public var email: String
    }

    static let scope = "https://www.googleapis.com/auth/drive"
    private let client: Client

    public init(client: Client) { self.client = client }

    /// Opens the consent page and waits (up to 5 minutes) for the redirect. Call off the main thread.
    public func authorize(openURL: (URL) -> Void) throws -> Grant {
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(16)

        let done = DispatchSemaphore(value: 0)
        var code: String?
        var failure: String?
        let server = HTTPServer { req in
            let items = URLComponents(string: req.target)?.queryItems ?? []
            let value = { (n: String) in items.first { $0.name == n }?.value }
            guard value("state") == state else {
                return HTTPResponse(status: 400, body: .data(Data("Unexpected request.".utf8)))
            }
            if let c = value("code") { code = c } else { failure = value("error") ?? "no code returned" }
            done.signal()
            let page = code != nil
                ? "<h2>SkyMount is connected to Google Drive.</h2><p>You can close this tab.</p>"
                : "<h2>Google sign-in did not finish.</h2><p>\(failure ?? "")</p>"
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/html; charset=utf-8")],
                                body: .data(Data("<!doctype html><meta charset=utf-8>\(page)".utf8)))
        }
        let port = try server.start()
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        openURL(comps.url!)

        if done.wait(timeout: .now() + 300) == .timedOut {
            throw RemoteError.authentication("timed out waiting for the browser")
        }
        guard let code else { throw RemoteError.authentication(failure ?? "cancelled") }

        let token = try tokenRequest([
            "code": code, "client_id": client.id, "client_secret": client.secret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = token["refresh_token"] as? String, let access = token["access_token"] as? String else {
            throw RemoteError.authentication("Google returned no refresh token")
        }
        return Grant(refreshToken: refresh, email: (try? Self.email(accessToken: access)) ?? "")
    }

    /// Returns (accessToken, expiry).
    public func refresh(_ refreshToken: String) throws -> (String, Date) {
        let token = try tokenRequest([
            "refresh_token": refreshToken, "client_id": client.id, "client_secret": client.secret,
            "grant_type": "refresh_token",
        ])
        guard let access = token["access_token"] as? String else {
            throw RemoteError.authentication("Google refused the saved sign-in; sign in again")
        }
        let expires = (token["expires_in"] as? Double) ?? 3000
        return (access, Date().addingTimeInterval(expires - 60))
    }

    private func tokenRequest(_ form: [String: String]) throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        let (data, resp) = try HTTPClient.data(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard resp.statusCode == 200 else {
            let reason = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \(resp.statusCode)"
            throw RemoteError.authentication(reason)
        }
        return json
    }

    private static func email(accessToken: String) throws -> String {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try HTTPClient.data(req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((json?["user"] as? [String: Any])?["emailAddress"] as? String) ?? ""
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
