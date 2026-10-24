import Foundation

public enum UploadState: Equatable, Sendable {
    case waiting
    case uploading
    case failed(String)
}

/// What Finder badges show for one volume. Paths are relative to the volume root ("/a/b.txt").
public struct VolumeActivity: Equatable, Sendable {
    public var pinned: [String: PinState] = [:]
    public var uploads: [String: UploadState] = [:]
    public var downloads: [String] = []
    public var offline = false
}

/// One mounted volume: backend + cache + loopback NFSv3 server + the kernel NFS mount.
public final class VolumeMount {
    public let volumeName: String
    public let fs: CachedFileSystem
    public private(set) var mountPoint: String?
    /// Changes uploaded at mount time that an earlier session could not send.
    public private(set) var recoveredUploads: [String] = []
    private let pendingDir: URL
    private var rpc: RPCServer?
    private var nfs: NFSServer?

    /// Parent folder for mount points; ordinary users cannot create folders in /Volumes.
    public static let mountRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("SkyMount", isDirectory: true)

    /// `pendingDir` holds unsent writes and must survive restarts, so it should not live in Caches.
    /// `pinsURL` remembers the folders kept offline and should not live in Caches either.
    public init(volumeName: String, backend: RemoteFileSystem, cacheRoot: URL, pendingDir: URL,
                listingTTL: TimeInterval = 30, readOnly: Bool = false, pinsURL: URL? = nil) {
        self.volumeName = Self.sanitize(volumeName)
        self.pendingDir = pendingDir
        self.fs = CachedFileSystem(backend: backend, cacheRoot: cacheRoot, listingTTL: listingTTL, readOnly: readOnly,
                                   pinsURL: pinsURL)
    }

    public var activity: VolumeActivity {
        VolumeActivity(pinned: fs.pinnedFolders, uploads: nfs?.pendingUploads() ?? [:],
                       downloads: fs.activeDownloads, offline: fs.isOffline)
    }

    /// Converts a path inside the mount point to a volume path, nil when it is outside.
    public func volumePath(forLocalPath local: String) -> String? {
        guard let mountPoint else { return nil }
        if local == mountPoint { return "/" }
        guard local.hasPrefix(mountPoint + "/") else { return nil }
        return RemotePath.normalize(String(local.dropFirst(mountPoint.count)))
    }

    /// Blocking: connects the backend, starts the server and mounts. Call off the main thread.
    public func mount(log: @escaping (String) -> Void = { _ in }) throws -> String {
        try fs.backend.connect()

        let nfs = NFSServer(fs: fs, workDir: pendingDir)
        nfs.log = log
        fs.onReachable = { [weak nfs] in nfs?.retryFailedUploadsSoon() }
        recoveredUploads = nfs.recoverPendingUploads().uploaded
        if !recoveredUploads.isEmpty { log("uploaded \(recoveredUploads.count) change(s) left from the last session") }
        let rpc = RPCServer { call in nfs.handle(&call) }
        let port = try rpc.start()
        self.nfs = nfs
        self.rpc = rpc

        let point = try Self.freshMountPoint(for: volumeName)
        let options = [
            "tcp", "vers=3", "port=\(port)", "mountport=\(port)",
            "locallocks",          // file locks work, handled by the kernel
            "soft", "intr", "timeo=50", "retrans=6",
            "deadtimeout=60",      // a vanished server unmounts itself instead of hanging Finder
            "mutejukebox",         // slow downloads (JUKEBOX replies) are not "server not responding"
            "rsize=1048576", "wsize=1048576", "readahead=8",
            "actimeo=3",
            // no "nonegnamecache": with it, git-on-mount tests panicked the kernel NFS client
            // (Kernel tag check fault in com.apple.filesystems.nfs, macOS 27.0.1, 2026-10-24)
        ].joined(separator: ",")

        // Finder lists an NFS volume under its server's host name, so mount through a name under
        // .localhost (RFC 6761 keeps it on this Mac) rather than showing "127.0.0.1".
        var failure = "mount_nfs failed"
        var mounted = false
        for host in [Self.loopbackHost(for: volumeName), "127.0.0.1"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/sbin/mount_nfs")
            proc.arguments = ["-o", options, "\(host):\(nfs.exportPath)", point]
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                stopServer()
                throw RemoteError.protocolError("could not run mount_nfs: \(error.localizedDescription)")
            }
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                mounted = true
                break
            }
            let message = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { failure = message }
            log("mount through \(host) failed: \(failure)")
        }
        guard mounted else {
            stopServer()
            try? FileManager.default.removeItem(atPath: point)
            throw RemoteError.protocolError(failure)
        }
        mountPoint = point
        return point
    }

    /// Uploads pending writes, unmounts and stops the server.
    public func unmount() {
        nfs?.flushAll()
        fs.saveState()
        if let mountPoint {
            if Darwin.unmount(mountPoint, 0) != 0 { _ = Darwin.unmount(mountPoint, MNT_FORCE) }
            try? FileManager.default.removeItem(atPath: mountPoint)
        }
        mountPoint = nil
        stopServer()
        fs.backend.disconnect()
    }

    public func refreshFolders() {
        fs.refreshFolders()
    }

    /// After wake or a network change: drop stale connections and re-read folders.
    public func networkChanged() {
        fs.networkChanged()
    }

    private func stopServer() {
        rpc?.stop()
        rpc = nil
        nfs = nil
    }

    /// True while the volume is still mounted (it disappears when ejected in Finder).
    /// Reads the mount table without touching the volume, so a stuck mount cannot block the caller.
    public var isMounted: Bool {
        guard let mountPoint else { return false }
        return Self.mountedPaths().contains(mountPoint)
    }

    static func mountedPaths() -> Set<String> {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        var paths = Set<String>()
        for i in 0..<Int(n) {
            var entry = buf[i]
            paths.insert(withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            })
        }
        return paths
    }

    /// ~/SkyMount/<name>, or "<name> 2", "<name> 3"… when the name is taken by another mount or files.
    static func freshMountPoint(for name: String) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let mounted = mountedPaths()
        for n in 1...50 {
            let candidate = mountRoot.appendingPathComponent(n == 1 ? name : "\(name) \(n)").path
            if mounted.contains(candidate) { continue }
            if fm.fileExists(atPath: candidate) {
                guard (try? fm.contentsOfDirectory(atPath: candidate))?.isEmpty == true else { continue }
                return candidate
            }
            try fm.createDirectory(atPath: candidate, withIntermediateDirectories: false)
            return candidate
        }
        throw RemoteError.protocolError("no free mount point for \(name)")
    }

    /// "My Server" becomes "My-Server.localhost": letters, digits and hyphens only, as host names allow.
    static func loopbackHost(for name: String) -> String {
        var label = ""
        for scalar in name.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                label.unicodeScalars.append(scalar)
            } else if !label.hasSuffix("-") {
                label += "-"
            }
        }
        label = String(label.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(63))
        return (label.isEmpty ? "SkyMount" : label) + ".localhost"
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "SkyMount" : cleaned
    }
}
