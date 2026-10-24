import Foundation
import SkyMountCore

/// A local folder whose "connection" can be cut, to test pinned folders without a server or a mount.
final class SwitchableBackend: RemoteFileSystem {
    let inner: LocalFolderBackend
    var online = true
    private(set) var downloads = 0

    init(root: URL) { inner = LocalFolderBackend(root: root) }

    private func check() throws { if !online { throw RemoteError.network("test: offline") } }

    func connect() throws { try check(); try inner.connect() }
    func disconnect() {}
    func list(_ path: String) throws -> [RemoteItem] { try check(); return try inner.list(path) }
    func stat(_ path: String) throws -> RemoteItem { try check(); return try inner.stat(path) }
    func download(_ path: String, to local: URL) throws { try check(); downloads += 1; try inner.download(path, to: local) }
    func upload(_ local: URL, to path: String) throws { try check(); try inner.upload(local, to: path) }
    func makeDirectory(_ path: String) throws { try check(); try inner.makeDirectory(path) }
    func removeFile(_ path: String) throws { try check(); try inner.removeFile(path) }
    func removeDirectory(_ path: String) throws { try check(); try inner.removeDirectory(path) }
    func move(_ from: String, to: String) throws { try check(); try inner.move(from, to: to) }
}

/// Pins a folder, cuts the connection and checks that pinned files stay readable, that the pin
/// survives a new session, that eviction spares pinned files, and that server changes are picked up.
func offlineTest() -> Bool {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("smctl-offline-\(getpid())")
    defer { try? fm.removeItem(at: base) }
    let server = base.appendingPathComponent("server")
    let cache = base.appendingPathComponent("cache")
    let pins = base.appendingPathComponent("pins.json")
    for dir in ["docs/sub", "other"] {
        try? fm.createDirectory(at: server.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for (path, text) in [("docs/a.txt", "alpha"), ("docs/sub/b.txt", "bravo"), ("other/c.txt", "charlie")] {
        try? Data(text.utf8).write(to: server.appendingPathComponent(path))
    }

    var ok = true
    func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL")  \(name)")
        ok = ok && condition
    }
    func read(_ fs: CachedFileSystem, _ path: String) -> String? {
        (try? fs.localCopy(path)).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
    func waitSynced(_ fs: CachedFileSystem, _ path: String) -> PinState? {
        for _ in 0..<100 {
            if case .synced = fs.pinnedFolders[path] { break }
            if case .failed = fs.pinnedFolders[path] { break }
            usleep(50_000)
        }
        return fs.pinnedFolders[path]
    }

    let backend = SwitchableBackend(root: server)
    do {
        let fs = CachedFileSystem(backend: backend, cacheRoot: cache, listingTTL: 0, readOnly: false, pinsURL: pins)
        fs.pin("/docs")
        let state = waitSynced(fs, "/docs")
        check("pinned folder syncs (\(String(describing: state)))", { if case .synced = state { return true }; return false }())
        check("pinned file downloaded once each", backend.downloads == 2)
        _ = read(fs, "/other/c.txt")
        fs.saveState()

        backend.online = false
        check("offline: pinned file readable", read(fs, "/docs/sub/b.txt") == "bravo")
        check("offline: pinned folder listed", (try? fs.list("/docs").map(\.name).sorted()) == ["a.txt", "sub"])
        check("offline: flag set", fs.isOffline)
        backend.online = true
    }

    // A new session (remount) with the network down: the pin and its contents come back from disk.
    backend.online = false
    let downloadsBefore = backend.downloads
    do {
        let fs = CachedFileSystem(backend: backend, cacheRoot: cache, listingTTL: 0, readOnly: false, pinsURL: pins)
        check("remount: pin remembered", fs.isPinned("/docs/sub/b.txt"))
        check("remount offline: pinned file readable", read(fs, "/docs/a.txt") == "alpha")
        check("remount offline: unpinned folder unavailable", (try? fs.list("/other")) == nil)
        check("remount offline: nothing downloaded", backend.downloads == downloadsBefore)
        backend.online = true

        _ = read(fs, "/other/c.txt")
        let evicted = fs.evict("/")
        check("evict frees unpinned copies only (\(evicted))", evicted == 1)
        backend.online = false
        check("after evict: pinned file still offline", read(fs, "/docs/a.txt") == "alpha")
        backend.online = true

        try? Data("alpha v2".utf8).write(to: server.appendingPathComponent("docs/a.txt"))
        try? Data("delta".utf8).write(to: server.appendingPathComponent("docs/sub/d.txt"))
        fs.resyncPinned()
        usleep(200_000)
        _ = waitSynced(fs, "/docs")
        backend.online = false
        check("resync: changed file updated", read(fs, "/docs/a.txt") == "alpha v2")
        check("resync: new file downloaded", read(fs, "/docs/sub/d.txt") == "delta")
        backend.online = true

        fs.unpin("/docs")
        check("unpin: no longer pinned", !fs.isPinned("/docs/a.txt") && fs.pinnedFolders.isEmpty)
        check("unpin: copies become evictable", fs.evict("/docs") == 3)
    }
    return ok
}
