import Foundation

public enum BackendKind: String, Codable, CaseIterable, Identifiable {
    case sftp, ftp, s3, googleDrive

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sftp: return "SFTP"
        case .ftp: return "FTP / FTPS"
        case .s3: return "Amazon S3 or compatible"
        case .googleDrive: return "Google Drive"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .sftp: return 22
        case .ftp: return 21
        case .s3, .googleDrive: return 0
        }
    }
}

public enum SecretField: String, CaseIterable {
    case password, keyPassphrase, s3SecretKey, googleClientSecret, googleRefreshToken
}

/// Everything about a connection except secrets, which go to the keychain.
public struct ConnectionConfig: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name = ""
    public var kind: BackendKind = .sftp

    // SFTP / FTP
    public var host = ""
    public var port = 22
    public var username = ""
    public var remotePath = "/"
    public var sftpUseKey = false
    public var sftpKeyPath = "~/.ssh/id_ed25519"
    public var sftpHostFingerprint: String?
    public var ftpUseTLS = true

    // S3
    public var s3Endpoint = "https://s3.amazonaws.com"
    public var s3Region = "us-east-1"
    public var s3Bucket = ""
    public var s3AccessKey = ""
    public var s3PathStyle = false

    // Google Drive
    public var googleClientID = ""
    public var googleAccount = ""

    // Behaviour
    public var autoMount = false
    public var readOnly = false
    public var listingTTL: Double = 15

    public init() {}

    public func secretAccount(_ field: SecretField) -> String { "\(id.uuidString).\(field.rawValue)" }
    public func secret(_ field: SecretField) -> String? { Keychain.get(secretAccount(field)) }
    public func setSecret(_ field: SecretField, _ value: String?) { Keychain.set(value, for: secretAccount(field)) }

    public var displayName: String { name.isEmpty ? "Untitled connection" : name }

    /// Short description of where this connection points, for lists.
    public var summary: String {
        switch kind {
        case .sftp, .ftp: return username.isEmpty ? host : "\(username)@\(host)"
        case .s3: return s3Bucket
        case .googleDrive: return googleAccount.isEmpty ? "Not signed in" : googleAccount
        }
    }

    /// Returns a message describing the first missing required field, or nil when the config is usable.
    public func validationProblem() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the connection a name." }
        switch kind {
        case .sftp, .ftp:
            if host.isEmpty { return "Enter the server address." }
            if username.isEmpty { return "Enter the user name." }
            if !(1...65535).contains(port) { return "The port must be between 1 and 65535." }
        case .s3:
            if URL(string: s3Endpoint)?.scheme == nil { return "Enter the endpoint as a full URL, like https://s3.amazonaws.com." }
            if s3Bucket.isEmpty { return "Enter the bucket name." }
            if s3AccessKey.isEmpty { return "Enter the access key ID." }
        case .googleDrive:
            if googleClientID.isEmpty { return "Enter the OAuth client ID from Google Cloud Console." }
        }
        return nil
    }
}

public final class ConnectionStore {
    public static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkyMount", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }()

    public static func load() -> [ConnectionConfig] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ConnectionConfig].self, from: data)) ?? []
    }

    public static func save(_ configs: [ConnectionConfig]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(configs).write(to: fileURL, options: .atomic)
    }
}

public enum BackendFactory {
    /// `onFingerprint` receives an SFTP host key seen for the first time so it can be stored.
    public static func make(_ c: ConnectionConfig, onFingerprint: @escaping (String) -> Void) throws -> RemoteFileSystem {
        switch c.kind {
        case .sftp:
            return SFTPBackend(settings: SFTPSettings(
                host: c.host, port: c.port, username: c.username, remoteRoot: c.remotePath,
                password: c.sftpUseKey ? nil : c.secret(.password),
                privateKeyPath: c.sftpUseKey ? c.sftpKeyPath : nil,
                keyPassphrase: c.sftpUseKey ? c.secret(.keyPassphrase) : nil,
                knownFingerprint: c.sftpHostFingerprint), onNewFingerprint: onFingerprint)
        case .ftp:
            return FTPBackend(settings: FTPSettings(host: c.host, port: c.port, username: c.username,
                                                    password: c.secret(.password) ?? "", remoteRoot: c.remotePath,
                                                    useTLS: c.ftpUseTLS))
        case .s3:
            guard let endpoint = URL(string: c.s3Endpoint) else { throw RemoteError.protocolError("invalid endpoint") }
            guard let secret = c.secret(.s3SecretKey), !secret.isEmpty else {
                throw RemoteError.authentication("the secret access key is missing")
            }
            return S3Backend(settings: S3Settings(endpoint: endpoint, region: c.s3Region, bucket: c.s3Bucket,
                                                  accessKey: c.s3AccessKey, secretKey: secret,
                                                  pathStyle: c.s3PathStyle, prefix: c.remotePath))
        case .googleDrive:
            guard let refresh = c.secret(.googleRefreshToken) else {
                throw RemoteError.authentication("sign in with Google first")
            }
            return GoogleDriveBackend(client: .init(id: c.googleClientID, secret: c.secret(.googleClientSecret) ?? ""),
                                      refreshToken: refresh)
        }
    }
}
