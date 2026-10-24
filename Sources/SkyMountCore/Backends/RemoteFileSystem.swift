import Foundation

public struct RemoteItem: Sendable {
    public var name: String
    public var isDirectory: Bool
    public var size: UInt64
    public var modified: Date
    /// Backend-specific identifier (Google Drive file ID); nil for path-addressed backends.
    public var id: String?
    /// Unix permission bits (0o7777) when the backend reports them; nil means "use a default".
    public var mode: UInt32?
    /// True for a symbolic link; the target is fetched with `readLink`.
    public var isSymlink: Bool

    public init(name: String, isDirectory: Bool, size: UInt64 = 0, modified: Date = Date(), id: String? = nil,
                mode: UInt32? = nil, isSymlink: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.id = id
        self.mode = mode
        self.isSymlink = isSymlink
    }
}

public enum RemoteError: Error, LocalizedError {
    case notFound(String)
    case permissionDenied(String)
    case alreadyExists(String)
    case notEmpty(String)
    case unsupported(String)
    case authentication(String)
    case network(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let p): return "Not found: \(p)"
        case .permissionDenied(let p): return "Permission denied: \(p)"
        case .alreadyExists(let p): return "Already exists: \(p)"
        case .notEmpty(let p): return "Folder is not empty: \(p)"
        case .unsupported(let m): return "Not supported: \(m)"
        case .authentication(let m): return "Sign-in failed: \(m)"
        case .network(let m): return "Network error: \(m)"
        case .protocolError(let m): return m
        }
    }
}

/// Operations every cloud backend implements. Paths are absolute within the mount ("/a/b.txt").
/// Implementations are called from many threads and must serialize internally if needed.
public protocol RemoteFileSystem: AnyObject {
    func connect() throws
    func disconnect()
    func list(_ path: String) throws -> [RemoteItem]
    func stat(_ path: String) throws -> RemoteItem
    func download(_ path: String, to local: URL) throws
    func upload(_ local: URL, to path: String) throws
    func makeDirectory(_ path: String) throws
    func removeFile(_ path: String) throws
    func removeDirectory(_ path: String) throws
    func move(_ from: String, to: String) throws

    /// Reads `length` bytes at `offset` without downloading the whole file. Only called when
    /// `supportsRangeReads` is true.
    func read(_ path: String, offset: UInt64, length: Int) throws -> Data
    var supportsRangeReads: Bool { get }
    /// Applies permission bits and/or modification time. Backends without them ignore the call.
    func setAttributes(_ path: String, mode: UInt32?, modified: Date?) throws
    /// True when setAttributes can set the modification time (SFTP, local folders).
    var canSetModificationTime: Bool { get }
    func readLink(_ path: String) throws -> String
    func makeSymlink(_ path: String, target: String) throws
    /// Called after wake from sleep or a network change; backends drop stale connections.
    func networkChanged()
}

public extension RemoteFileSystem {
    var supportsRangeReads: Bool { false }

    func read(_ path: String, offset: UInt64, length: Int) throws -> Data {
        throw RemoteError.unsupported("partial reads")
    }

    func setAttributes(_ path: String, mode: UInt32?, modified: Date?) throws {}

    var canSetModificationTime: Bool { false }

    func readLink(_ path: String) throws -> String { throw RemoteError.unsupported("symbolic links") }

    func makeSymlink(_ path: String, target: String) throws { throw RemoteError.unsupported("symbolic links") }

    func networkChanged() {}

    /// Stat by listing the parent folder, for backends without a cheap single-item lookup.
    func statViaParent(_ path: String) throws -> RemoteItem {
        if path == "/" { return RemoteItem(name: "/", isDirectory: true) }
        let name = RemotePath.name(path)
        guard let item = try list(RemotePath.parent(path)).first(where: { $0.name == name }) else {
            throw RemoteError.notFound(path)
        }
        return item
    }
}

public enum RemotePath {
    public static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + parts.joined(separator: "/")
    }

    public static func parent(_ path: String) -> String {
        let p = normalize(path)
        guard let idx = p.lastIndex(of: "/"), idx != p.startIndex else { return "/" }
        return String(p[..<idx])
    }

    public static func name(_ path: String) -> String {
        String(normalize(path).split(separator: "/").last ?? "")
    }

    public static func join(_ base: String, _ name: String) -> String {
        normalize(base + "/" + name)
    }

    /// Joins a configured remote root ("/home/u", "") with a mount-relative path.
    public static func under(_ root: String, _ path: String) -> String {
        let r = normalize(root)
        return r == "/" ? normalize(path) : normalize(r + "/" + path)
    }
}
