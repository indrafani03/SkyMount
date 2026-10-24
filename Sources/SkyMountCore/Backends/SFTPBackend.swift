import Foundation
import CShims

public struct SFTPSettings {
    public var host: String
    public var port: Int
    public var username: String
    public var remoteRoot: String
    public var password: String?
    public var privateKeyPath: String?
    public var keyPassphrase: String?
    /// SHA-256 host key fingerprint accepted earlier (trust on first use); nil on the first connection.
    public var knownFingerprint: String?
    /// Parallel SSH sessions. Folder scans (git status, opening a project) run this many requests at once.
    public var sessions: Int

    public init(host: String, port: Int, username: String, remoteRoot: String, password: String?,
                privateKeyPath: String?, keyPassphrase: String?, knownFingerprint: String?, sessions: Int = 8) {
        self.host = host
        self.port = port
        self.username = username
        self.remoteRoot = remoteRoot
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.keyPassphrase = keyPassphrase
        self.knownFingerprint = knownFingerprint
        self.sessions = max(1, sessions)
    }
}

/// SFTP over libssh2 in blocking mode, with a small pool of sessions because one libssh2 session
/// handles one request at a time. Dropped connections are re-established on the next call.
public final class SFTPBackend: RemoteFileSystem {
    private var settings: SFTPSettings
    private let onNewFingerprint: (String) -> Void
    private let settingsLock = NSLock()

    private let pool: [Session]
    private var free: [Int]
    private let poolLock = NSLock()
    private let available: DispatchSemaphore
    private var keepalive: DispatchSourceTimer?

    private static let initOnce: Void = { libssh2_init(0) }()

    /// `onNewFingerprint` is called once when a server is seen for the first time, so the caller can persist it.
    public init(settings: SFTPSettings, onNewFingerprint: @escaping (String) -> Void) {
        _ = Self.initOnce
        self.settings = settings
        self.onNewFingerprint = onNewFingerprint
        pool = (0..<settings.sessions).map { _ in Session() }
        free = Array(0..<settings.sessions)
        available = DispatchSemaphore(value: settings.sessions)
    }

    deinit { disconnect() }

    // MARK: Session pool

    fileprivate final class Session {
        var sock: Int32 = -1
        var session: OpaquePointer?
        var sftp: OpaquePointer?
        var connected: Bool { sftp != nil }

        func close() {
            if let sftp { libssh2_sftp_shutdown(sftp) }
            sftp = nil
            if let session {
                libssh2_session_disconnect_ex(session, 11, "bye", "")
                libssh2_session_free(session)
            }
            session = nil
            if sock >= 0 { Darwin.close(sock) }
            sock = -1
        }

        func lastError() -> String {
            guard let session else { return "not connected" }
            var msg: UnsafeMutablePointer<CChar>?
            var len: Int32 = 0
            libssh2_session_last_error(session, &msg, &len, 0)
            return msg.map { String(cString: $0) } ?? "unknown error"
        }

        /// Maps the last failure to a RemoteError; `.network` means the connection itself is broken.
        func error(_ path: String) -> RemoteError {
            guard let session else { return .network("not connected") }
            if libssh2_session_last_errno(session) != LIBSSH2_ERROR_SFTP_PROTOCOL {
                return .network(lastError())
            }
            switch UInt(libssh2_sftp_last_error(sftp)) {
            case UInt(LIBSSH2_FX_NO_SUCH_FILE), UInt(LIBSSH2_FX_NO_SUCH_PATH): return .notFound(path)
            case UInt(LIBSSH2_FX_PERMISSION_DENIED): return .permissionDenied(path)
            case UInt(LIBSSH2_FX_FILE_ALREADY_EXISTS): return .alreadyExists(path)
            case UInt(LIBSSH2_FX_DIR_NOT_EMPTY), UInt(LIBSSH2_FX_FAILURE): return .notEmpty(path)
            case let code: return .protocolError("SFTP error \(code) on \(path)")
            }
        }
    }

    private func acquire() -> Session {
        available.wait()
        poolLock.lock()
        defer { poolLock.unlock() }
        return pool[free.removeLast()]
    }

    private func release(_ s: Session) {
        poolLock.lock()
        free.append(pool.firstIndex { $0 === s }!)
        poolLock.unlock()
        available.signal()
    }

    /// Runs `body` on a pooled session. Broken connections are reopened and the call retried twice.
    private func withSFTP<T>(_ body: (Session, OpaquePointer) throws -> T) throws -> T {
        let s = acquire()
        defer { release(s) }
        var attempt = 0
        while true {
            do {
                if !s.connected { try open(s) }
                return try body(s, s.sftp!)
            } catch let e as RemoteError {
                guard case .network = e, attempt < 2 else { throw e }
                s.close()
                attempt += 1
                Thread.sleep(forTimeInterval: Double(attempt))
            }
        }
    }

    private func open(_ s: Session) throws {
        s.close()
        settingsLock.lock()
        let cfg = settings
        settingsLock.unlock()

        s.sock = try Self.openSocket(host: cfg.host, port: cfg.port)
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw RemoteError.network("could not create SSH session")
        }
        s.session = session
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, 30_000)
        if libssh2_session_handshake(session, s.sock) != 0 {
            let message = s.lastError()
            s.close()
            throw RemoteError.network("SSH handshake with \(cfg.host) failed: \(message)")
        }
        do {
            try verifyHostKey(session)
            try authenticate(session, s, cfg)
        } catch {
            s.close()
            throw error
        }
        libssh2_keepalive_config(session, 1, 20)
        guard let sftp = libssh2_sftp_init(session) else {
            let message = s.lastError()
            s.close()
            throw RemoteError.protocolError("server has no SFTP subsystem: \(message)")
        }
        s.sftp = sftp
    }

    private func verifyHostKey(_ session: OpaquePointer) throws {
        guard let raw = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256) else {
            throw RemoteError.protocolError("server sent no host key")
        }
        let fingerprint = "SHA256:" + Data(bytes: raw, count: 32).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        settingsLock.lock()
        defer { settingsLock.unlock() }
        if let known = settings.knownFingerprint {
            guard known == fingerprint else {
                throw RemoteError.authentication(
                    "host key for \(settings.host) changed (expected \(known), got \(fingerprint)). "
                    + "If the server was reinstalled, reset the saved key in the connection settings.")
            }
        } else {
            settings.knownFingerprint = fingerprint
            onNewFingerprint(fingerprint)
        }
    }

    private func authenticate(_ session: OpaquePointer, _ s: Session, _ cfg: SFTPSettings) throws {
        let user = cfg.username
        let ulen = UInt32(user.utf8.count)
        var rc: Int32 = -1
        if let key = cfg.privateKeyPath, !key.isEmpty {
            let expanded = (key as NSString).expandingTildeInPath
            rc = libssh2_userauth_publickey_fromfile_ex(session, user, ulen, nil, expanded, cfg.keyPassphrase)
        } else if let password = cfg.password {
            rc = libssh2_userauth_password_ex(session, user, ulen, password, UInt32(password.utf8.count), nil)
        }
        if rc != 0 { throw RemoteError.authentication("\(user)@\(cfg.host): \(s.lastError())") }
    }

    public func connect() throws {
        _ = try withSFTP { _, _ in () }
        startKeepalive()
    }

    public func disconnect() {
        keepalive?.cancel()
        keepalive = nil
        for _ in pool { available.wait() }
        pool.forEach { $0.close() }
        for _ in pool { available.signal() }
    }

    /// Drops idle connections so the next request reconnects (after sleep or a network change).
    public func networkChanged() {
        poolLock.lock()
        let idle = free.map { pool[$0] }
        idle.forEach { $0.close() }
        poolLock.unlock()
    }

    /// Keeps idle sessions alive through NAT/firewall timeouts; a failed probe closes the session.
    private func startKeepalive() {
        guard keepalive == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.poolLock.lock()
            let idle = self.free.map { self.pool[$0] }.filter(\.connected)
            for s in idle {
                var next: Int32 = 0
                if libssh2_keepalive_send(s.session, &next) != 0 { s.close() }
            }
            self.poolLock.unlock()
        }
        timer.resume()
        keepalive = timer
    }

    private static func openSocket(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            throw RemoteError.network("cannot resolve \(host)")
        }
        defer { freeaddrinfo(res) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                var tv = timeval(tv_sec: 15, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { return fd }
                Darwin.close(fd)
            }
            ai = a.pointee.ai_next
        }
        throw RemoteError.network("cannot connect to \(host):\(port)")
    }

    // MARK: Helpers

    private func full(_ path: String) -> String {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return RemotePath.under(settings.remoteRoot, path)
    }

    private static func isType(_ a: LIBSSH2_SFTP_ATTRIBUTES, _ type: Int32) -> Bool {
        a.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0
            && (a.permissions & UInt(LIBSSH2_SFTP_S_IFMT)) == UInt(type)
    }

    private static func item(name: String, _ a: LIBSSH2_SFTP_ATTRIBUTES, symlink: Bool = false) -> RemoteItem {
        let modified = a.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0
            ? Date(timeIntervalSince1970: TimeInterval(a.mtime)) : Date()
        let mode = a.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 ? UInt32(a.permissions & 0o7777) : nil
        return RemoteItem(name: name, isDirectory: isType(a, LIBSSH2_SFTP_S_IFDIR), size: UInt64(a.filesize),
                          modified: modified, mode: mode, isSymlink: symlink)
    }

    private func readLink(_ s: Session, _ sftp: OpaquePointer, _ p: String, _ path: String) throws -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = libssh2_sftp_symlink_ex(sftp, p, UInt32(p.utf8.count), &buf, UInt32(buf.count), LIBSSH2_SFTP_READLINK)
        if n < 0 { throw s.error(path) }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Listing

    public func list(_ path: String) throws -> [RemoteItem] {
        let p = full(path)
        return try withSFTP { s, sftp in
            guard let dir = libssh2_sftp_open_ex(sftp, p, UInt32(p.utf8.count), 0, 0, LIBSSH2_SFTP_OPENDIR) else {
                throw s.error(path)
            }
            var entries: [(String, LIBSSH2_SFTP_ATTRIBUTES)] = []
            var buf = [CChar](repeating: 0, count: 1024)
            var attrs = LIBSSH2_SFTP_ATTRIBUTES()
            while true {
                let n = libssh2_sftp_readdir_ex(dir, &buf, buf.count, nil, 0, &attrs)
                if n < 0 {
                    libssh2_sftp_close_handle(dir)
                    throw s.error(path)
                }
                if n == 0 { break }
                let name = String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if name != "." && name != ".." { entries.append((name, attrs)) }
            }
            libssh2_sftp_close_handle(dir)
            // readdir reports lstat attributes, so links stay links, exactly as git stored them.
            return entries.map { name, a in Self.item(name: name, a, symlink: Self.isType(a, LIBSSH2_SFTP_S_IFLNK)) }
        }
    }

    public func stat(_ path: String) throws -> RemoteItem {
        let p = full(path)
        return try withSFTP { s, sftp in
            var attrs = LIBSSH2_SFTP_ATTRIBUTES()
            if libssh2_sftp_stat_ex(sftp, p, UInt32(p.utf8.count), LIBSSH2_SFTP_LSTAT, &attrs) != 0 { throw s.error(path) }
            return Self.item(name: RemotePath.name(path), attrs, symlink: Self.isType(attrs, LIBSSH2_SFTP_S_IFLNK))
        }
    }

    // MARK: Content

    public var supportsRangeReads: Bool { true }

    public func read(_ path: String, offset: UInt64, length: Int) throws -> Data {
        let p = full(path)
        return try withSFTP { s, sftp in
            guard let h = libssh2_sftp_open_ex(sftp, p, UInt32(p.utf8.count), UInt(LIBSSH2_FXF_READ), 0,
                                               LIBSSH2_SFTP_OPENFILE) else { throw s.error(path) }
            defer { libssh2_sftp_close_handle(h) }
            libssh2_sftp_seek64(h, offset)
            var out = Data(capacity: length)
            var buf = [CChar](repeating: 0, count: min(length, 256 * 1024))
            while out.count < length {
                let n = libssh2_sftp_read(h, &buf, min(buf.count, length - out.count))
                if n < 0 { throw s.error(path) }
                if n == 0 { break }
                buf.withUnsafeBytes { out.append(contentsOf: $0.prefix(n)) }
            }
            return out
        }
    }

    public func download(_ path: String, to local: URL) throws {
        let p = full(path)
        try withSFTP { s, sftp in
            guard let h = libssh2_sftp_open_ex(sftp, p, UInt32(p.utf8.count), UInt(LIBSSH2_FXF_READ), 0,
                                               LIBSSH2_SFTP_OPENFILE) else { throw s.error(path) }
            defer { libssh2_sftp_close_handle(h) }
            FileManager.default.createFile(atPath: local.path, contents: nil)
            let out = try FileHandle(forWritingTo: local)
            defer { try? out.close() }
            var buf = [CChar](repeating: 0, count: 256 * 1024)
            while true {
                let n = libssh2_sftp_read(h, &buf, buf.count)
                if n < 0 { throw s.error(path) }
                if n == 0 { break }
                buf.withUnsafeBytes { out.write(Data($0.prefix(n))) }
            }
        }
    }

    /// Overwrites in place: the server keeps the file's owner and permission bits.
    public func upload(_ local: URL, to path: String) throws {
        let p = full(path)
        try withSFTP { s, sftp in
            let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
            guard let h = libssh2_sftp_open_ex(sftp, p, UInt32(p.utf8.count), flags, 0o644,
                                               LIBSSH2_SFTP_OPENFILE) else { throw s.error(path) }
            defer { libssh2_sftp_close_handle(h) }
            let input = try FileHandle(forReadingFrom: local)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try chunk.withUnsafeBytes { raw in
                    var offset = 0
                    let base = raw.bindMemory(to: CChar.self).baseAddress!
                    while offset < chunk.count {
                        let n = libssh2_sftp_write(h, base + offset, chunk.count - offset)
                        if n < 0 { throw s.error(path) }
                        offset += n
                    }
                }
            }
        }
    }

    // MARK: Namespace and metadata

    public func makeDirectory(_ path: String) throws {
        let p = full(path)
        try withSFTP { s, sftp in
            if libssh2_sftp_mkdir_ex(sftp, p, UInt32(p.utf8.count), 0o755) != 0 { throw s.error(path) }
        }
    }

    public func removeFile(_ path: String) throws {
        let p = full(path)
        try withSFTP { s, sftp in
            if libssh2_sftp_unlink_ex(sftp, p, UInt32(p.utf8.count)) != 0 { throw s.error(path) }
        }
    }

    public func removeDirectory(_ path: String) throws {
        let p = full(path)
        try withSFTP { s, sftp in
            if libssh2_sftp_rmdir_ex(sftp, p, UInt32(p.utf8.count)) != 0 { throw s.error(path) }
        }
    }

    public func move(_ from: String, to: String) throws {
        let src = full(from), dst = full(to)
        try withSFTP { s, sftp in
            let flags = Int(LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE)
            if libssh2_sftp_rename_ex(sftp, src, UInt32(src.utf8.count), dst, UInt32(dst.utf8.count), flags) == 0 {
                return
            }
            // OpenSSH (SFTP v3) refuses to overwrite: remove the target and retry once.
            _ = libssh2_sftp_unlink_ex(sftp, dst, UInt32(dst.utf8.count))
            if libssh2_sftp_rename_ex(sftp, src, UInt32(src.utf8.count), dst, UInt32(dst.utf8.count), flags) != 0 {
                throw s.error(from)
            }
        }
    }

    public var canSetModificationTime: Bool { true }

    public func setAttributes(_ path: String, mode: UInt32?, modified: Date?) throws {
        guard mode != nil || modified != nil else { return }
        let p = full(path)
        try withSFTP { s, sftp in
            var attrs = LIBSSH2_SFTP_ATTRIBUTES()
            if let mode {
                attrs.flags |= UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
                attrs.permissions = UInt(mode & 0o7777)
            }
            if let modified {
                attrs.flags |= UInt(LIBSSH2_SFTP_ATTR_ACMODTIME)
                attrs.mtime = UInt(max(0, modified.timeIntervalSince1970))
                attrs.atime = attrs.mtime
            }
            if libssh2_sftp_stat_ex(sftp, p, UInt32(p.utf8.count), LIBSSH2_SFTP_SETSTAT, &attrs) != 0 {
                throw s.error(path)
            }
        }
    }

    public func readLink(_ path: String) throws -> String {
        let p = full(path)
        return try withSFTP { s, sftp in try readLink(s, sftp, p, path) }
    }

    public func makeSymlink(_ path: String, target: String) throws {
        let link = full(path)
        try withSFTP { s, sftp in
            // OpenSSH's sftp-server takes (target, link) in the reverse of the draft's order, and
            // libssh2 passes its first argument first, so the target goes first here.
            var linkBuf = Array(link.utf8CString)
            let rc = libssh2_sftp_symlink_ex(sftp, target, UInt32(target.utf8.count),
                                             &linkBuf, UInt32(link.utf8.count), LIBSSH2_SFTP_SYMLINK)
            if rc != 0 { throw s.error(path) }
        }
    }
}
