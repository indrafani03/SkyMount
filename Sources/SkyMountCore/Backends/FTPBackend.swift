import Foundation
import CShims

public struct FTPSettings {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var remoteRoot: String
    public var useTLS: Bool

    public init(host: String, port: Int, username: String, password: String, remoteRoot: String, useTLS: Bool) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.remoteRoot = remoteRoot
        self.useTLS = useTLS
    }
}

/// FTP / explicit FTPS through libcurl. Every call opens its own transfer, so calls can run in parallel.
public final class FTPBackend: RemoteFileSystem {
    private let s: FTPSettings
    private var supportsMLSD = true

    public init(settings: FTPSettings) { s = settings }

    public func connect() throws { _ = try list("/") }
    public func disconnect() {}

    private func full(_ path: String) -> String { RemotePath.under(s.remoteRoot, path) }

    private func url(_ fullPath: String, directory: Bool = false) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ";?#%"))
        var encoded = fullPath.addingPercentEncoding(withAllowedCharacters: allowed) ?? fullPath
        if directory, !encoded.hasSuffix("/") { encoded += "/" }
        // A leading "%2F" makes curl treat the path as absolute instead of relative to the login folder.
        return "ftp://\(s.host):\(s.port)/%2F\(encoded.dropFirst())"
    }

    private struct Result { var code: Int32; var body: Data; var response: Int; var message: String }

    private func perform(url: String, customRequest: String? = nil, quote: [String] = [], nobody: Bool = false,
                         downloadTo: UnsafeMutablePointer<FILE>? = nil,
                         uploadFrom: UnsafeMutablePointer<FILE>? = nil, uploadSize: Int64 = 0,
                         range: String? = nil) -> Result {
        var out: UnsafeMutablePointer<CChar>?
        var outLen = 0
        var response = 0
        var errbuf = [CChar](repeating: 0, count: 256)
        let userpwd = "\(s.username):\(s.password)"
        let cQuote = quote.map { strdup($0) }
        defer { cQuote.forEach { free($0) } }

        let rc: Int32 = url.withCString { cURL in
            userpwd.withCString { cUser in
                withOptionalCString(customRequest) { cCustom in
                    withOptionalCString(range) { cRange in
                        cQuote.map { UnsafePointer($0) }.withUnsafeBufferPointer { qp in
                            var req = sm_ftp_request(url: cURL, userpwd: cUser, use_tls: s.useTLS ? 1 : 0,
                                                     custom_request: cCustom, quote: qp.baseAddress,
                                                     quote_count: Int32(quote.count), nobody: nobody ? 1 : 0,
                                                     download_to: downloadTo, upload_from: uploadFrom,
                                                     upload_size: uploadSize, range: cRange)
                            return sm_ftp_perform(&req, &out, &outLen, &response, &errbuf)
                        }
                    }
                }
            }
        }
        let body = out.map { Data(bytes: $0, count: outLen) } ?? Data()
        sm_free(out)
        return Result(code: rc, body: body, response: response, message: String(cString: errbuf))
    }

    private func check(_ r: Result, _ path: String) throws {
        guard r.code != 0 else { return }
        switch r.response {
        case 550: throw RemoteError.notFound(path)
        case 530: throw RemoteError.authentication(r.message)
        case 553, 532: throw RemoteError.permissionDenied(path)
        default:
            if r.code == 9 || r.code == 78 { throw RemoteError.notFound(path) } // ACCESS_DENIED / REMOTE_FILE_NOT_FOUND
            if r.code == 67 { throw RemoteError.authentication(r.message) }    // LOGIN_DENIED
            throw RemoteError.network(r.message.isEmpty ? "FTP error \(r.code)" : r.message)
        }
    }

    // MARK: Listing

    public func list(_ path: String) throws -> [RemoteItem] {
        let dirURL = url(full(path), directory: true)
        if supportsMLSD {
            let r = perform(url: dirURL, customRequest: "MLSD")
            if r.code == 0 { return Self.parseMLSD(r.body) }
            if r.response != 500 && r.response != 502 && r.response != 504 { try check(r, path) }
            supportsMLSD = false
        }
        let r = perform(url: dirURL)
        try check(r, path)
        return Self.parseLIST(r.body)
    }

    public func stat(_ path: String) throws -> RemoteItem { try statViaParent(path) }

    static func parseMLSD(_ data: Data) -> [RemoteItem] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMddHHmmss"
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let name = String(line[line.index(after: space)...])
            var facts: [String: String] = [:]
            for f in line[..<space].split(separator: ";") {
                let kv = f.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { facts[kv[0].lowercased()] = String(kv[1]) }
            }
            let type = facts["type"]?.lowercased() ?? "file"
            if type == "cdir" || type == "pdir" || name == "." || name == ".." { return nil }
            return RemoteItem(name: name, isDirectory: type == "dir",
                              size: UInt64(facts["size"] ?? "0") ?? 0,
                              modified: facts["modify"].flatMap { fmt.date(from: String($0.prefix(14))) } ?? Date(),
                              mode: facts["unix.mode"].flatMap { UInt32($0, radix: 8) })
        }
    }

    /// Unix `ls -l` style lines: "drwxr-xr-x 2 user group 4096 Jan 02 10:00 name".
    static func parseLIST(_ data: Data) -> [RemoteItem] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count == 9, let perms = parts.first else { return nil }
            var name = String(parts[8])
            if perms.hasPrefix("l"), let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            if name == "." || name == ".." { return nil }
            return RemoteItem(name: name, isDirectory: perms.hasPrefix("d"), size: UInt64(parts[4]) ?? 0,
                              modified: parseLsDate("\(parts[5]) \(parts[6]) \(parts[7])"),
                              mode: parseMode(perms))
        }
    }

    /// "-rwxr-xr-x" to 0o755.
    static func parseMode<S: StringProtocol>(_ perms: S) -> UInt32? {
        let bits = Array(perms.dropFirst().prefix(9))
        guard bits.count == 9 else { return nil }
        var mode: UInt32 = 0
        for (i, c) in bits.enumerated() where c != "-" { mode |= 1 << UInt32(8 - i) }
        return mode
    }

    private static func parseLsDate(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d yyyy"
        if let d = f.date(from: s) { return d }
        f.dateFormat = "MMM d HH:mm yyyy"
        let year = Calendar.current.component(.year, from: Date())
        if let d = f.date(from: "\(s) \(year)") { return d > Date() ? f.date(from: "\(s) \(year - 1)") ?? d : d }
        return Date()
    }

    // MARK: Transfers

    public func download(_ path: String, to local: URL) throws {
        guard let fp = fopen(local.path, "wb") else { throw RemoteError.protocolError("cannot write \(local.path)") }
        let r = perform(url: url(full(path)), downloadTo: fp)
        fclose(fp)
        try check(r, path)
    }

    public var supportsRangeReads: Bool { true }

    public func read(_ path: String, offset: UInt64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let r = perform(url: url(full(path)), range: "\(offset)-\(offset + UInt64(length) - 1)")
        try check(r, path)
        return r.body.prefix(length)
    }

    public func upload(_ local: URL, to path: String) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard let fp = fopen(local.path, "rb") else { throw RemoteError.protocolError("cannot read \(local.path)") }
        let r = perform(url: url(full(path)), uploadFrom: fp, uploadSize: size)
        fclose(fp)
        try check(r, path)
    }

    // MARK: Commands

    private func command(_ cmds: [String], _ path: String) throws {
        let r = perform(url: url("/", directory: true), quote: cmds, nobody: true)
        if r.code == 21 { // QUOTE_ERROR: the server rejected the command
            throw RemoteError.permissionDenied(path)
        }
        try check(r, path)
    }

    public func makeDirectory(_ path: String) throws { try command(["MKD \(full(path))"], path) }
    public func removeFile(_ path: String) throws { try command(["DELE \(full(path))"], path) }

    public func removeDirectory(_ path: String) throws {
        if !(try list(path)).isEmpty { throw RemoteError.notEmpty(path) }
        try command(["RMD \(full(path))"], path)
    }

    public func move(_ from: String, to: String) throws {
        try command(["RNFR \(full(from))", "RNTO \(full(to))"], from)
    }

    /// Permission bits via SITE CHMOD, which most Unix FTP servers accept. Times cannot be set over FTP.
    public func setAttributes(_ path: String, mode: UInt32?, modified: Date?) throws {
        guard let mode else { return }
        try command(["SITE CHMOD \(String(mode & 0o7777, radix: 8)) \(full(path))"], path)
    }
}

private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}
