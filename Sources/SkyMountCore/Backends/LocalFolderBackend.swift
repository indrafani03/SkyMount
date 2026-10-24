import Foundation

/// Serves a local folder. Used by `smctl` to exercise the NFS + mount pipeline without a cloud account.
public final class LocalFolderBackend: RemoteFileSystem {
    private let root: URL
    private let fm = FileManager.default

    public init(root: URL) { self.root = root }

    private func url(_ path: String) -> URL {
        root.appendingPathComponent(String(RemotePath.normalize(path).dropFirst()))
    }

    /// lstat semantics: attributesOfItem does not follow symbolic links.
    private func item(at url: URL, name: String) throws -> RemoteItem {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try fm.attributesOfItem(atPath: url.path) } catch { throw RemoteError.notFound(url.path) }
        let type = attrs[.type] as? FileAttributeType
        return RemoteItem(name: name, isDirectory: type == .typeDirectory,
                          size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                          modified: attrs[.modificationDate] as? Date ?? Date(),
                          mode: (attrs[.posixPermissions] as? NSNumber)?.uint32Value,
                          isSymlink: type == .typeSymbolicLink)
    }

    public func connect() throws {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw RemoteError.notFound(root.path)
        }
    }

    public func disconnect() {}

    public func list(_ path: String) throws -> [RemoteItem] {
        let dir = url(path)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { throw RemoteError.notFound(path) }
        return names.compactMap { try? item(at: dir.appendingPathComponent($0), name: $0) }
    }

    public func stat(_ path: String) throws -> RemoteItem {
        try item(at: url(path), name: path == "/" ? "/" : RemotePath.name(path))
    }

    public var supportsRangeReads: Bool { true }

    public func read(_ path: String, offset: UInt64, length: Int) throws -> Data {
        guard let fh = try? FileHandle(forReadingFrom: url(path)) else { throw RemoteError.notFound(path) }
        defer { try? fh.close() }
        try fh.seek(toOffset: offset)
        return try fh.read(upToCount: length) ?? Data()
    }

    public func download(_ path: String, to local: URL) throws {
        try? fm.removeItem(at: local)
        do { try fm.copyItem(at: url(path), to: local) } catch { throw RemoteError.notFound(path) }
    }

    /// Rewrites the existing file in place so its permission bits survive, like an SFTP server does.
    public func upload(_ local: URL, to path: String) throws {
        let dest = url(path)
        if fm.fileExists(atPath: dest.path), let out = try? FileHandle(forWritingTo: dest) {
            defer { try? out.close() }
            try out.truncate(atOffset: 0)
            try out.write(contentsOf: try Data(contentsOf: local))
        } else {
            try fm.copyItem(at: local, to: dest)
        }
    }

    public func makeDirectory(_ path: String) throws {
        if fm.fileExists(atPath: url(path).path) { throw RemoteError.alreadyExists(path) }
        try fm.createDirectory(at: url(path), withIntermediateDirectories: false)
    }

    public func removeFile(_ path: String) throws {
        do { try fm.removeItem(at: url(path)) } catch { throw RemoteError.notFound(path) }
    }

    public func removeDirectory(_ path: String) throws {
        if let c = try? fm.contentsOfDirectory(atPath: url(path).path), !c.isEmpty { throw RemoteError.notEmpty(path) }
        try removeFile(path)
    }

    public func move(_ from: String, to: String) throws {
        if rename(url(from).path, url(to).path) != 0 {
            throw errno == ENOENT ? RemoteError.notFound(from) : RemoteError.protocolError(String(cString: strerror(errno)))
        }
    }

    public var canSetModificationTime: Bool { true }

    public func setAttributes(_ path: String, mode: UInt32?, modified: Date?) throws {
        var attrs: [FileAttributeKey: Any] = [:]
        if let mode { attrs[.posixPermissions] = NSNumber(value: mode & 0o7777) }
        if let modified { attrs[.modificationDate] = modified }
        if !attrs.isEmpty { try fm.setAttributes(attrs, ofItemAtPath: url(path).path) }
    }

    public func readLink(_ path: String) throws -> String {
        do { return try fm.destinationOfSymbolicLink(atPath: url(path).path) } catch { throw RemoteError.notFound(path) }
    }

    public func makeSymlink(_ path: String, target: String) throws {
        if fm.fileExists(atPath: url(path).path) { throw RemoteError.alreadyExists(path) }
        try fm.createSymbolicLink(atPath: url(path).path, withDestinationPath: target)
    }
}
