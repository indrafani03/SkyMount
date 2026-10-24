import Foundation
import CryptoKit

public struct S3Settings {
    public var endpoint: URL        // https://s3.amazonaws.com, https://s3.us-west-004.backblazeb2.com, MinIO URL...
    public var region: String
    public var bucket: String
    public var accessKey: String
    public var secretKey: String
    public var pathStyle: Bool      // true for MinIO and most S3-compatible services
    public var prefix: String       // folder inside the bucket used as the mount root

    public init(endpoint: URL, region: String, bucket: String, accessKey: String, secretKey: String,
                pathStyle: Bool, prefix: String) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.pathStyle = pathStyle
        self.prefix = prefix
    }
}

/// Amazon S3 and S3-compatible storage, signed with AWS Signature Version 4.
/// Folders are emulated with "/" delimiters and zero-byte "name/" marker objects.
public final class S3Backend: RemoteFileSystem {
    private let s: S3Settings

    public init(settings: S3Settings) { s = settings }

    public func connect() throws { _ = try list("/") }
    public func disconnect() {}

    // MARK: Keys

    private func key(_ path: String) -> String {
        String(RemotePath.under(s.prefix, path).dropFirst())
    }

    private func dirPrefix(_ path: String) -> String {
        let k = key(path)
        return k.isEmpty ? "" : k + "/"
    }

    // MARK: Requests

    private static let emptyHash = SHA256.hash(data: Data()).hex

    private func request(_ method: String, key: String, query: [String: String] = [:],
                         headers extra: [String: String] = [:], payloadHash: String = emptyHash,
                         now: Date = Date()) -> URLRequest {
        var comps = URLComponents(url: s.endpoint, resolvingAgainstBaseURL: false)!
        var path = ""
        if s.pathStyle {
            path = "/" + Self.encode(s.bucket, keepSlash: false) + "/" + Self.encode(key, keepSlash: true)
        } else {
            comps.host = "\(s.bucket).\(comps.host ?? "")"
            path = "/" + Self.encode(key, keepSlash: true)
        }
        if path.hasSuffix("//") { path.removeLast() }
        comps.percentEncodedPath = path
        let canonicalQuery = query.sorted { $0.key < $1.key }
            .map { "\(Self.encode($0.key, keepSlash: false))=\(Self.encode($0.value, keepSlash: false))" }
            .joined(separator: "&")
        comps.percentEncodedQuery = canonicalQuery.isEmpty ? nil : canonicalQuery

        let url = comps.url!
        var host = comps.host ?? ""
        if let port = comps.port, !(comps.scheme == "https" && port == 443), !(comps.scheme == "http" && port == 80) {
            host += ":\(port)"
        }

        let amzDate = Self.stamp(now, "yyyyMMdd'T'HHmmss'Z'")
        let day = Self.stamp(now, "yyyyMMdd")
        var headers = extra
        headers["host"] = host
        headers["x-amz-date"] = amzDate
        headers["x-amz-content-sha256"] = payloadHash

        let signedNames = headers.keys.map { $0.lowercased() }.sorted()
        let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        let canonicalHeaders = signedNames.map { "\($0):\(lowered[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let signedHeaders = signedNames.joined(separator: ";")
        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(day)/\(s.region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(SHA256.hash(data: Data(canonicalRequest.utf8)).hex)"

        var k = SymmetricKey(data: Data("AWS4\(s.secretKey)".utf8))
        for part in [day, s.region, "s3", "aws4_request"] {
            k = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: k)))
        }
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: k)).hex

        var req = URLRequest(url: url)
        req.httpMethod = method
        for (name, value) in headers where name != "host" { req.setValue(value, forHTTPHeaderField: name) }
        req.setValue("AWS4-HMAC-SHA256 Credential=\(s.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                     forHTTPHeaderField: "Authorization")
        return req
    }

    private func check(_ resp: HTTPURLResponse, _ body: Data, _ path: String) throws {
        switch resp.statusCode {
        case 200..<300: return
        case 404: throw RemoteError.notFound(path)
        case 401, 403:
            let code = Self.xmlValue("Code", in: body) ?? "AccessDenied"
            throw code == "AccessDenied" ? RemoteError.permissionDenied(path)
                                         : RemoteError.authentication("\(code): \(Self.xmlValue("Message", in: body) ?? "")")
        default:
            throw RemoteError.protocolError("S3 \(resp.statusCode): \(Self.xmlValue("Message", in: body) ?? path)")
        }
    }

    // MARK: Listing

    private struct Page { var files: [RemoteItem]; var dirs: [String]; var keys: [String]; var next: String? }

    private func listPage(prefix: String, delimiter: Bool, token: String?, maxKeys: Int? = nil) throws -> Page {
        var q = ["list-type": "2", "prefix": prefix]
        if delimiter { q["delimiter"] = "/" }
        if let token { q["continuation-token"] = token }
        if let maxKeys { q["max-keys"] = String(maxKeys) }
        let (body, resp) = try HTTPClient.data(request("GET", key: "", query: q))
        try check(resp, body, prefix)
        let parsed = ListParser.parse(body)
        var page = Page(files: [], dirs: [], keys: parsed.contents.map(\.key), next: parsed.nextToken)
        for c in parsed.contents where c.key != prefix {
            page.files.append(RemoteItem(name: String(c.key.dropFirst(prefix.count)), isDirectory: false,
                                         size: c.size, modified: c.modified))
        }
        page.dirs = parsed.prefixes.map { String($0.dropFirst(prefix.count).dropLast()) }.filter { !$0.isEmpty }
        return page
    }

    public func list(_ path: String) throws -> [RemoteItem] {
        let prefix = dirPrefix(path)
        var items: [RemoteItem] = []
        var token: String?
        repeat {
            let page = try listPage(prefix: prefix, delimiter: true, token: token)
            items += page.files
            items += page.dirs.map { RemoteItem(name: $0, isDirectory: true) }
            token = page.next
        } while token != nil
        return items
    }

    private func allKeys(under prefix: String) throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            let page = try listPage(prefix: prefix, delimiter: false, token: token)
            keys += page.keys
            token = page.next
        } while token != nil
        return keys
    }

    public func stat(_ path: String) throws -> RemoteItem {
        if RemotePath.normalize(path) == "/" { return RemoteItem(name: "/", isDirectory: true) }
        let (body, resp) = try HTTPClient.data(request("HEAD", key: key(path)))
        if resp.statusCode == 200 {
            let size = UInt64(resp.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
            let modified = resp.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.parseHTTPDate) ?? Date()
            return RemoteItem(name: RemotePath.name(path), isDirectory: false, size: size, modified: modified)
        }
        if resp.statusCode != 404 { try check(resp, body, path) }
        let page = try listPage(prefix: dirPrefix(path), delimiter: false, token: nil, maxKeys: 1)
        guard !page.keys.isEmpty else { throw RemoteError.notFound(path) }
        return RemoteItem(name: RemotePath.name(path), isDirectory: true)
    }

    // MARK: Objects

    public func download(_ path: String, to local: URL) throws {
        let (body, resp) = try HTTPClient.download(request("GET", key: key(path)), to: local)
        try check(resp, body, path)
    }

    public var supportsRangeReads: Bool { true }

    public func read(_ path: String, offset: UInt64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let range = "bytes=\(offset)-\(offset + UInt64(length) - 1)"
        let (body, resp) = try HTTPClient.data(request("GET", key: key(path), headers: ["range": range]))
        if resp.statusCode == 416 { return Data() }
        try check(resp, body, path)
        return body
    }

    public func upload(_ local: URL, to path: String) throws {
        var req = request("PUT", key: key(path), headers: ["content-type": "application/octet-stream"],
                          payloadHash: "UNSIGNED-PAYLOAD")
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.intValue ?? 0
        req.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (body, resp) = try HTTPClient.upload(req, fromFile: local)
        try check(resp, body, path)
    }

    public func makeDirectory(_ path: String) throws {
        let (body, resp) = try HTTPClient.data(request("PUT", key: dirPrefix(path)))
        try check(resp, body, path)
    }

    private func deleteKey(_ k: String, _ path: String) throws {
        let (body, resp) = try HTTPClient.data(request("DELETE", key: k))
        if resp.statusCode != 404 { try check(resp, body, path) }
    }

    public func removeFile(_ path: String) throws { try deleteKey(key(path), path) }

    public func removeDirectory(_ path: String) throws {
        let prefix = dirPrefix(path)
        let page = try listPage(prefix: prefix, delimiter: false, token: nil, maxKeys: 2)
        if page.keys.contains(where: { $0 != prefix }) { throw RemoteError.notEmpty(path) }
        try deleteKey(prefix, path)
    }

    private func copyKey(_ from: String, _ to: String, _ path: String) throws {
        let source = "/" + Self.encode(s.bucket, keepSlash: false) + "/" + Self.encode(from, keepSlash: true)
        let (body, resp) = try HTTPClient.data(request("PUT", key: to, headers: ["x-amz-copy-source": source]))
        try check(resp, body, path)
    }

    public func move(_ from: String, to: String) throws {
        if try stat(from).isDirectory {
            // S3 has no rename: copy every object under the folder, then delete the originals.
            let src = dirPrefix(from), dst = dirPrefix(to)
            let keys = try allKeys(under: src)
            for k in keys { try copyKey(k, dst + k.dropFirst(src.count), from) }
            for k in keys { try deleteKey(k, from) }
        } else {
            try copyKey(key(from), key(to), from)
            try deleteKey(key(from), from)
        }
    }

    /// Checks the signer against the GET Object example from the AWS SigV4 documentation.
    public static func signatureSelfTest() -> Bool {
        let b = S3Backend(settings: S3Settings(
            endpoint: URL(string: "https://s3.amazonaws.com")!, region: "us-east-1", bucket: "examplebucket",
            accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            pathStyle: false, prefix: ""))
        let req = b.request("GET", key: "test.txt", headers: ["range": "bytes=0-9"],
                            now: Date(timeIntervalSince1970: 1_369_353_600))
        let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
        return auth.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    // MARK: Helpers

    static func encode(_ s: String, keepSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if keepSlash { allowed.insert("/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func stamp(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f.string(from: d)
    }

    private static func parseHTTPDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }

    static func xmlValue(_ tag: String, in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let a = text.range(of: "<\(tag)>"), let b = text.range(of: "</\(tag)>", range: a.upperBound..<text.endIndex)
        else { return nil }
        return String(text[a.upperBound..<b.lowerBound])
    }
}

/// Minimal ListObjectsV2 response parser.
private final class ListParser: NSObject, XMLParserDelegate {
    struct Object { var key = ""; var size: UInt64 = 0; var modified = Date() }
    var contents: [Object] = []
    var prefixes: [String] = []
    var nextToken: String?

    private var current: Object?
    private var inCommonPrefixes = false
    private var text = ""
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ data: Data) -> ListParser {
        let p = ListParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "Contents" { current = Object() }
        if name == "CommonPrefixes" { inCommonPrefixes = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "Key": current?.key = text
        case "Size": current?.size = UInt64(text) ?? 0
        case "LastModified":
            current?.modified = iso.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? Date()
        case "Contents":
            if let c = current { contents.append(c) }
            current = nil
        case "Prefix" where inCommonPrefixes: prefixes.append(text)
        case "CommonPrefixes": inCommonPrefixes = false
        case "NextContinuationToken": nextToken = text
        default: break
        }
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
