import Foundation

/// Google Drive v3. Drive addresses files by ID and allows duplicate names in one folder, so paths
/// are resolved through listings and cached; when names collide the oldest item wins.
/// Google Docs/Sheets/Slides have no downloadable bytes and are left out of listings.
public final class GoogleDriveBackend: RemoteFileSystem {
    private let oauth: GoogleOAuth
    private let refreshToken: String
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var ids: [String: String] = ["/": "root"]
    private let lock = NSLock()
    private let tokenLock = NSLock()

    private static let api = "https://www.googleapis.com/drive/v3"
    private static let upload = "https://www.googleapis.com/upload/drive/v3"
    private static let folderType = "application/vnd.google-apps.folder"

    public init(client: GoogleOAuth.Client, refreshToken: String) {
        oauth = GoogleOAuth(client: client)
        self.refreshToken = refreshToken
    }

    public func connect() throws { _ = try token(forceRefresh: true) }
    public func disconnect() {}

    // MARK: HTTP

    private func token(forceRefresh: Bool = false) throws -> String {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        if !forceRefresh, let accessToken, Date() < expiry { return accessToken }
        let (t, e) = try oauth.refresh(refreshToken)
        accessToken = t
        expiry = e
        return t
    }

    private enum Body { case none, json([String: Any]), file(URL) }

    /// Authenticated call with one token refresh on 401 and backoff on rate limits / 5xx.
    private func call(_ method: String, _ url: String, query: [String: String] = [:], body: Body = .none,
                      headers: [String: String] = [:], downloadTo: URL? = nil, path: String) throws
        -> (Data, HTTPURLResponse)
    {
        var comps = URLComponents(string: url)!
        var q = query
        q["supportsAllDrives"] = "true"
        comps.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Drive query syntax uses '+' literally; URLComponents leaves it unescaped.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

        var refreshed = false
        for attempt in 0..<5 {
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            let result: (Data, HTTPURLResponse)
            switch body {
            case .none:
                if let downloadTo {
                    result = try HTTPClient.download(req, to: downloadTo)
                } else {
                    result = try HTTPClient.data(req)
                }
            case .json(let obj):
                req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: obj)
                result = try HTTPClient.data(req)
            case .file(let file):
                result = try HTTPClient.upload(req, fromFile: file)
            }
            let (data, resp) = result
            switch resp.statusCode {
            case 200..<300:
                return result
            case 401 where !refreshed:
                refreshed = true
                _ = try token(forceRefresh: true)
                continue
            case 429, 500, 502, 503, 504:
                Thread.sleep(forTimeInterval: pow(2, Double(attempt)) * 0.5)
                continue
            case 403 where Self.reason(data).contains("RateLimit"):
                Thread.sleep(forTimeInterval: pow(2, Double(attempt)) * 0.5)
                continue
            case 416:
                return (Data(), resp) // range past the end of the file
            case 404:
                throw RemoteError.notFound(path)
            case 403:
                throw RemoteError.permissionDenied(path)
            default:
                throw RemoteError.protocolError("Drive \(resp.statusCode): \(Self.message(data))")
            }
        }
        throw RemoteError.network("Google Drive kept rejecting requests (rate limited)")
    }

    private static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func message(_ data: Data) -> String {
        ((json(data)["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    private static func reason(_ data: Data) -> String {
        let errors = ((json(data)["error"] as? [String: Any])?["errors"] as? [[String: Any]]) ?? []
        return errors.compactMap { $0["reason"] as? String }.joined(separator: ",")
    }

    // MARK: Path to ID

    private func cachedID(_ path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return ids[RemotePath.normalize(path)]
    }

    private func remember(_ path: String, _ id: String?) {
        lock.lock()
        ids[RemotePath.normalize(path)] = id
        lock.unlock()
    }

    private func forget(under path: String) {
        let p = RemotePath.normalize(path)
        lock.lock()
        ids = ids.filter { $0.key != p && !$0.key.hasPrefix(p + "/") }
        lock.unlock()
    }

    private func resolve(_ path: String) throws -> String {
        let p = RemotePath.normalize(path)
        if let id = cachedID(p) { return id }
        _ = try list(RemotePath.parent(p))
        guard let id = cachedID(p) else { throw RemoteError.notFound(p) }
        return id
    }

    // MARK: Listing

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public func list(_ path: String) throws -> [RemoteItem] {
        let p = RemotePath.normalize(path)
        let folderID = try resolve(p)
        var items: [String: RemoteItem] = [:]
        var pageToken: String?
        repeat {
            var q = [
                "q": "'\(folderID)' in parents and trashed = false",
                "fields": "nextPageToken,files(id,name,mimeType,size,modifiedTime)",
                "pageSize": "1000",
                "orderBy": "createdTime",
                "includeItemsFromAllDrives": "true",
            ]
            if let pageToken { q["pageToken"] = pageToken }
            let (data, _) = try call("GET", "\(Self.api)/files", query: q, path: p)
            let json = Self.json(data)
            for f in (json["files"] as? [[String: Any]]) ?? [] {
                guard let id = f["id"] as? String, let name = f["name"] as? String,
                      let mime = f["mimeType"] as? String, !name.contains("/") else { continue }
                let isDir = mime == Self.folderType
                if !isDir && mime.hasPrefix("application/vnd.google-apps.") { continue }
                if items[name] != nil { continue }
                let modified = (f["modifiedTime"] as? String).flatMap(Self.dateFormatter.date(from:)) ?? Date()
                items[name] = RemoteItem(name: name, isDirectory: isDir,
                                         size: UInt64(f["size"] as? String ?? "0") ?? 0, modified: modified, id: id)
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil

        lock.lock()
        for item in items.values { ids[RemotePath.join(p, item.name)] = item.id }
        lock.unlock()
        return Array(items.values)
    }

    public func stat(_ path: String) throws -> RemoteItem { try statViaParent(path) }

    // MARK: Content

    public func download(_ path: String, to local: URL) throws {
        let id = try resolve(path)
        _ = try call("GET", "\(Self.api)/files/\(id)", query: ["alt": "media"], downloadTo: local, path: path)
        guard FileManager.default.fileExists(atPath: local.path) else {
            throw RemoteError.network("download of \(path) did not complete")
        }
    }

    public var supportsRangeReads: Bool { true }

    public func read(_ path: String, offset: UInt64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let id = try resolve(path)
        let (data, _) = try call("GET", "\(Self.api)/files/\(id)", query: ["alt": "media"],
                                 headers: ["Range": "bytes=\(offset)-\(offset + UInt64(length) - 1)"], path: path)
        return data.prefix(length)
    }

    public func upload(_ local: URL, to path: String) throws {
        let p = RemotePath.normalize(path)
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.intValue ?? 0
        let existing = try? resolve(p)

        // Resumable upload: one call creates the session, the PUT sends the bytes.
        let (_, start): (Data, HTTPURLResponse)
        if let existing {
            (_, start) = try call("PATCH", "\(Self.upload)/files/\(existing)", query: ["uploadType": "resumable"],
                                  body: .json([:]), headers: ["X-Upload-Content-Length": String(size)], path: p)
        } else {
            let parent = try resolve(RemotePath.parent(p))
            (_, start) = try call("POST", "\(Self.upload)/files", query: ["uploadType": "resumable"],
                                  body: .json(["name": RemotePath.name(p), "parents": [parent]]),
                                  headers: ["X-Upload-Content-Length": String(size)], path: p)
        }
        guard let session = start.value(forHTTPHeaderField: "Location"), let url = URL(string: session) else {
            throw RemoteError.protocolError("Drive did not open an upload session")
        }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (data, resp) = try HTTPClient.upload(put, fromFile: local)
        guard (200..<300).contains(resp.statusCode) else {
            throw RemoteError.protocolError("Drive upload failed (\(resp.statusCode)): \(Self.message(data))")
        }
        if let id = Self.json(data)["id"] as? String { remember(p, id) }
    }

    // MARK: Namespace

    public func makeDirectory(_ path: String) throws {
        let p = RemotePath.normalize(path)
        if (try? resolve(p)) != nil { throw RemoteError.alreadyExists(p) }
        let parent = try resolve(RemotePath.parent(p))
        let (data, _) = try call("POST", "\(Self.api)/files", query: ["fields": "id"],
                                 body: .json(["name": RemotePath.name(p), "mimeType": Self.folderType,
                                              "parents": [parent]]), path: p)
        remember(p, Self.json(data)["id"] as? String)
    }

    /// Moves the item to the Drive trash (recoverable for 30 days) instead of deleting it.
    private func trash(_ path: String) throws {
        let id = try resolve(path)
        _ = try call("PATCH", "\(Self.api)/files/\(id)", query: ["fields": "id"], body: .json(["trashed": true]),
                     path: path)
        forget(under: path)
    }

    public func removeFile(_ path: String) throws { try trash(path) }
    public func removeDirectory(_ path: String) throws { try trash(path) }

    public func move(_ from: String, to: String) throws {
        let src = RemotePath.normalize(from), dst = RemotePath.normalize(to)
        let id = try resolve(src)
        // Drive happily keeps two items with one name; replace the destination like a filesystem would.
        if let existing = try? resolve(dst), existing != id { try trash(dst) }
        var query = ["fields": "id"]
        let oldParent = try resolve(RemotePath.parent(src))
        let newParent = try resolve(RemotePath.parent(dst))
        if oldParent != newParent {
            query["addParents"] = newParent
            query["removeParents"] = oldParent
        }
        _ = try call("PATCH", "\(Self.api)/files/\(id)", query: query, body: .json(["name": RemotePath.name(dst)]),
                     path: src)
        forget(under: src)
        remember(dst, id)
    }
}
