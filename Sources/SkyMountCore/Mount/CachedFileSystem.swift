import Foundation
import CryptoKit

/// Sits between the NFS server and a backend:
/// - caches folder listings and answers single-item lookups from them. A listing older than
///   `listingTTL` is still served while a background refresh fetches a new one, so browsing and
///   `git status` never wait on the network for folders they have seen,
/// - lists subfolders one level ahead in the background, in parallel,
/// - keeps downloaded file contents on disk and reuses them while size and mtime still match,
/// - keeps Finder metadata files (`._*`, `.DS_Store`) local so they never reach the cloud,
/// - keeps pinned folders fully downloaded and serves them from disk while the server is unreachable.
public final class CachedFileSystem {
    public let backend: RemoteFileSystem
    public let readOnly: Bool
    private let listingTTL: TimeInterval
    private let contentDir: URL
    private let shadowDir: URL

    private struct Listing { var items: [String: RemoteItem]; var fetched: Date }
    private var listings: [String: Listing] = [:]
    private var inFlight: [String: DispatchGroup] = [:]
    /// Bumped on every local change to a folder; a listing fetched across a change is stale.
    private var versions: [String: Int] = [:]
    private var refreshing = Set<String>()
    private var contentStamps: [String: (size: UInt64, modified: Date)] = [:]
    private var pathLocks: [String: NSLock] = [:]
    private let lock = NSLock()
    private let store: OfflineStore
    private var pinStates: [String: PinState] = [:]
    private var downloading: [String: Int] = [:]
    private var maintenance: DispatchSourceTimer?
    /// True after a request failed for lack of a connection, until one succeeds again.
    public private(set) var isOffline = false
    /// Called (on a background queue) when the server answers again after being unreachable.
    public var onReachable: (() -> Void)?
    /// Background refreshes and prefetches.
    private let background: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 6 // the SFTP pool has 8, leaving room for requests someone waits on
        q.qualityOfService = .utility
        return q
    }()

    /// `pinsURL` stores the folders kept offline; nil keeps none (command-line tools).
    public init(backend: RemoteFileSystem, cacheRoot: URL, listingTTL: TimeInterval, readOnly: Bool,
                pinsURL: URL? = nil) {
        self.backend = backend
        self.listingTTL = listingTTL
        self.readOnly = readOnly
        contentDir = cacheRoot.appendingPathComponent("content", isDirectory: true)
        shadowDir = cacheRoot.appendingPathComponent("finder-metadata", isDirectory: true)
        try? FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: shadowDir, withIntermediateDirectories: true)
        store = OfflineStore(pinsURL: pinsURL, indexURL: cacheRoot.appendingPathComponent("index.json"))
        // Contents downloaded in an earlier session stay valid while size and mtime still match.
        let fm = FileManager.default
        contentStamps = store.savedStamps().filter {
            fm.fileExists(atPath: contentDir.appendingPathComponent(Self.key($0.key)).path)
        }
        for root in store.pinnedRoots { pinStates[root] = .syncing(done: 0, total: 0) }

        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 5)
        var ticks = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.store.save()
            self.probeIfOffline()
            // Pinned folders are checked against the server at start and every ten minutes.
            if ticks % 120 == 0 { self.syncAllPinned() }
            ticks += 1
        }
        t.resume()
        maintenance = t
    }

    deinit { maintenance?.cancel() }

    private func noteReachable() {
        lock.lock()
        let wasOffline = isOffline
        isOffline = false
        lock.unlock()
        if wasOffline {
            onReachable?()
            syncAllPinned()
        }
    }

    private var probing = false

    /// While offline, requests are answered from disk without waiting on the network; this checks
    /// in the background whether the server is back.
    private func probeIfOffline() {
        lock.lock()
        guard isOffline, !probing else { lock.unlock(); return }
        probing = true
        lock.unlock()
        background.addOperation { [weak self] in
            guard let self else { return }
            if let items = try? self.backend.list("/") {
                self.lock.lock()
                self.listings["/"] = Listing(items: Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }),
                                             fetched: Date())
                self.lock.unlock()
                self.noteReachable()
            }
            self.lock.lock()
            self.probing = false
            self.lock.unlock()
        }
    }

    /// The last known listing of `path` (memory first, then disk), used while offline.
    private func offlineListing(_ path: String) -> [RemoteItem]? {
        lock.lock()
        if let l = listings[path] {
            lock.unlock()
            return Array(l.items.values)
        }
        lock.unlock()
        guard let saved = store.savedListing(path) else { return nil }
        lock.lock()
        listings[path] = Listing(items: Dictionary(saved.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }),
                                 fetched: Date())
        lock.unlock()
        return saved
    }

    private static func isConnectivity(_ error: Error) -> Bool {
        if case RemoteError.network = error { return true }
        return false
    }

    // MARK: Finder metadata kept local

    public static func isLocalOnly(_ path: String) -> Bool {
        let name = RemotePath.name(path)
        return name.hasPrefix("._") || name == ".DS_Store"
    }

    private func shadowURL(_ path: String) -> URL {
        shadowDir.appendingPathComponent(Self.key(path))
    }

    // MARK: Metadata

    public func list(_ path: String) throws -> [RemoteItem] {
        let path = RemotePath.normalize(path)
        lock.lock()
        if let l = listings[path] {
            let age = Date().timeIntervalSince(l.fetched)
            // Serve stale listings while refreshing, unless they are very old (e.g. after a long idle).
            if age < listingTTL * 10 {
                if age >= listingTTL, refreshing.insert(path).inserted {
                    background.addOperation { [weak self] in
                        _ = try? self?.fetchListing(path, prefetchChildren: false)
                        self?.lock.lock()
                        self?.refreshing.remove(path)
                        self?.lock.unlock()
                    }
                }
                lock.unlock()
                return Array(l.items.values)
            }
        }
        lock.unlock()
        return try fetchListing(path, prefetchChildren: true)
    }

    /// Fetches one listing; concurrent callers for the same folder share the request.
    private func fetchListing(_ path: String, prefetchChildren: Bool) throws -> [RemoteItem] {
        lock.lock()
        if let group = inFlight[path] {
            lock.unlock()
            group.wait()
            lock.lock()
            defer { lock.unlock() }
            if let l = listings[path] { return Array(l.items.values) }
            throw RemoteError.notFound(path)
        }
        let group = DispatchGroup()
        group.enter()
        inFlight[path] = group
        lock.unlock()
        defer {
            lock.lock()
            inFlight[path] = nil
            lock.unlock()
            group.leave()
        }

        lock.lock()
        let offline = isOffline
        lock.unlock()
        if offline {
            if let cached = offlineListing(path) { return cached }
            throw RemoteError.network("the server is unreachable")
        }

        var items: [RemoteItem] = []
        for attempt in 0..<3 {
            lock.lock()
            let version = versions[path, default: 0]
            lock.unlock()
            let started = Date()
            do {
                items = try backend.list(path)
            } catch {
                if case RemoteError.notFound = error {
                    lock.lock()
                    listings[path] = nil
                    lock.unlock()
                }
                if Self.isConnectivity(error) {
                    lock.lock()
                    isOffline = true
                    lock.unlock()
                    // Without a connection the last known listing beats an error: Finder keeps
                    // showing the folder and pinned files stay readable.
                    if let cached = offlineListing(path) { return cached }
                }
                throw error
            }
            noteReachable()
            Stats.shared.record("backend.list", since: started)
            lock.lock()
            // A local create/delete/rename landed while the request was out: its result may predate
            // that change and would resurrect deleted files. Fetch again.
            if versions[path, default: 0] != version && attempt < 2 {
                lock.unlock()
                continue
            }
            break
        }
        listings[path] = Listing(items: Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }),
                                 fetched: Date())
        lock.unlock()
        store.recordListing(path, items)
        lock.lock()
        let toPrefetch = prefetchChildren
            ? items.filter { $0.isDirectory && !$0.isSymlink }.map { RemotePath.join(path, $0.name) }
                .filter { listings[$0] == nil && inFlight[$0] == nil }
            : []
        lock.unlock()
        // One level ahead only: prefetched folders do not prefetch their own children.
        for child in toPrefetch.prefix(64) {
            background.addOperation { [weak self] in _ = try? self?.fetchListing(child, prefetchChildren: false) }
        }
        return items
    }

    public func stat(_ path: String) throws -> RemoteItem {
        let path = RemotePath.normalize(path)
        if path == "/" { return RemoteItem(name: "/", isDirectory: true) }
        if Self.isLocalOnly(path) {
            let url = shadowURL(path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                throw RemoteError.notFound(path)
            }
            return RemoteItem(name: RemotePath.name(path), isDirectory: false,
                              size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                              modified: attrs[.modificationDate] as? Date ?? Date())
        }
        // One listing of the parent answers every sibling lookup Finder makes afterwards.
        let name = RemotePath.name(path)
        let parent = RemotePath.parent(path)
        if let item = try list(parent).first(where: { $0.name == name }) { return item }
        // "Not found" from a stale listing would hide files created on the server (and the kernel
        // caches negative answers), so confirm misses against a fresh listing.
        lock.lock()
        let age = listings[parent].map { Date().timeIntervalSince($0.fetched) } ?? .infinity
        lock.unlock()
        if age >= listingTTL, let item = try fetchListing(parent, prefetchChildren: false).first(where: { $0.name == name }) {
            return item
        }
        throw RemoteError.notFound(path)
    }

    public func invalidate(_ path: String) {
        let path = RemotePath.normalize(path)
        lock.lock()
        listings.removeValue(forKey: path)
        versions[path, default: 0] += 1
        lock.unlock()
    }

    private func patchParent(of path: String, with item: RemoteItem?) {
        let parent = RemotePath.parent(path)
        let name = RemotePath.name(path)
        lock.lock()
        versions[parent, default: 0] += 1
        if var l = listings[parent] {
            l.items[name] = item
            listings[parent] = l
        }
        lock.unlock()
    }

    // MARK: Content

    private static func key(_ path: String) -> String {
        SHA256.hash(data: Data(RemotePath.normalize(path).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func pathLock(_ path: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let l = pathLocks[path] { return l }
        let l = NSLock()
        pathLocks[path] = l
        return l
    }

    /// Local file holding the current remote contents, downloading only when the cached copy is stale.
    public func localCopy(_ path: String) throws -> URL {
        let path = RemotePath.normalize(path)
        if Self.isLocalOnly(path) {
            let url = shadowURL(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw RemoteError.notFound(path) }
            return url
        }
        let item = try stat(path)
        if item.isDirectory { throw RemoteError.unsupported("cannot read a folder as a file") }
        let target = contentDir.appendingPathComponent(Self.key(path))
        let pl = pathLock(path)
        pl.lock()
        defer { pl.unlock() }

        lock.lock()
        let stamp = contentStamps[path]
        lock.unlock()
        if let stamp, stamp.size == item.size, stamp.modified == item.modified,
           FileManager.default.fileExists(atPath: target.path) {
            return target
        }
        lock.lock()
        let offline = isOffline
        lock.unlock()
        if offline { throw RemoteError.network("the server is unreachable and \(path) is not kept offline") }
        noteMiss(path)
        let partial = target.appendingPathExtension("part")
        let tdownload = Date()
        lock.lock()
        downloading[path, default: 0] += 1
        lock.unlock()
        defer {
            Stats.shared.record("backend.download", since: tdownload)
            lock.lock()
            downloading[path, default: 1] -= 1
            if downloading[path] == 0 { downloading[path] = nil }
            lock.unlock()
        }
        do {
            try backend.download(path, to: partial)
        } catch {
            if Self.isConnectivity(error) {
                lock.lock()
                isOffline = true
                lock.unlock()
            }
            throw error
        }
        _ = try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        lock.lock()
        contentStamps[path] = (item.size, item.modified)
        lock.unlock()
        store.recordStamp(path, size: item.size, modified: item.modified)
        return target
    }

    /// Uploads `file` as the new contents of `path`; the file is moved into the content cache.
    /// Uploads `file` as the new contents of `path`, then applies `mode` and `modified` when given.
    public func write(_ path: String, from file: URL, mode: UInt32? = nil, modified: Date? = nil) throws {
        let path = RemotePath.normalize(path)
        if Self.isLocalOnly(path) {
            let url = shadowURL(path)
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: file, to: url)
            return
        }
        try ensureWritable(path)
        let pl = pathLock(path)
        pl.lock()
        defer { pl.unlock() }
        let tupload = Date()
        defer { Stats.shared.record("backend.upload", since: tupload) }
        do {
            try backend.upload(file, to: path)
        } catch RemoteError.permissionDenied {
            // A file can be read-only on the server yet still be written by its owner through a
            // descriptor opened before the chmod (git creates objects 0444, then writes them).
            // Lift owner-write for the upload and put the original mode back.
            guard let mode = (try? backend.stat(path))?.mode, mode & 0o200 == 0 else { throw RemoteError.permissionDenied(path) }
            try backend.setAttributes(path, mode: mode | 0o200, modified: nil)
            defer { try? backend.setAttributes(path, mode: mode, modified: nil) }
            try backend.upload(file, to: path)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)??.uint64Value ?? 0
        let item: RemoteItem
        if backend.canSetModificationTime {
            // Setting mode and mtime ourselves (one request) tells us the exact result, so no stat
            // is needed to keep the cached copy valid. Whole seconds match what servers store.
            let stamp = modified ?? Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            lock.lock()
            let previousMode = mode ?? listings[RemotePath.parent(path)]?.items[RemotePath.name(path)]?.mode
            lock.unlock()
            try backend.setAttributes(path, mode: mode, modified: stamp)
            item = RemoteItem(name: RemotePath.name(path), isDirectory: false, size: size, modified: stamp,
                              mode: previousMode ?? 0o644)
        } else {
            if let mode { try? backend.setAttributes(path, mode: mode, modified: nil) }
            // One stat for the authoritative mtime keeps the cached copy valid without re-listing the folder.
            item = (try? backend.stat(path)) ?? RemoteItem(name: RemotePath.name(path), isDirectory: false, size: size)
        }
        patchParent(of: path, with: item)
        dropBlocks(path)

        let target = contentDir.appendingPathComponent(Self.key(path))
        _ = try? FileManager.default.removeItem(at: target)
        if (try? FileManager.default.moveItem(at: file, to: target)) != nil {
            lock.lock()
            contentStamps[path] = (item.size, item.modified)
            lock.unlock()
            store.recordStamp(path, size: item.size, modified: item.modified)
        }
    }

    // MARK: Namespace changes

    private func ensureWritable(_ path: String) throws {
        if readOnly { throw RemoteError.permissionDenied(path) }
    }

    public func makeDirectory(_ path: String) throws {
        try ensureWritable(path)
        try backend.makeDirectory(RemotePath.normalize(path))
        patchParent(of: path, with: RemoteItem(name: RemotePath.name(path), isDirectory: true))
    }

    /// Deletes a file, or a folder together with everything inside it (WebDAV DELETE semantics).
    public func remove(_ path: String) throws {
        let path = RemotePath.normalize(path)
        if Self.isLocalOnly(path) {
            try? FileManager.default.removeItem(at: shadowURL(path))
            return
        }
        try ensureWritable(path)
        let item = try stat(path)
        if item.isDirectory {
            do {
                try backend.removeDirectory(path)
            } catch RemoteError.notEmpty {
                invalidate(path)
                for child in try list(path) { try remove(RemotePath.join(path, child.name)) }
                try backend.removeDirectory(path)
            }
            invalidate(path)
        } else {
            try backend.removeFile(path)
        }
        patchParent(of: path, with: nil)
    }

    public func move(_ from: String, to: String) throws {
        let from = RemotePath.normalize(from), to = RemotePath.normalize(to)
        if Self.isLocalOnly(from) || Self.isLocalOnly(to) {
            let src = shadowURL(from), dst = shadowURL(to)
            _ = try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.moveItem(at: src, to: dst)
            return
        }
        try ensureWritable(to)
        try backend.move(from, to: to)
        invalidate(RemotePath.parent(from))
        invalidate(RemotePath.parent(to))
        invalidate(from)
    }

    public func copy(_ from: String, to: String) throws {
        let src = try localCopy(from)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: src, to: tmp)
        try write(to, from: tmp)
    }

    // MARK: Sibling prefetch

    /// Small files read one after another in a folder (git re-hashing a work tree, a build reading
    /// sources) are fetched in parallel ahead of the reader.
    static let prefetchMaxSize: UInt64 = 256 << 10
    private var recentMisses: [String: (count: Int, last: Date)] = [:]
    private var prefetching = Set<String>()

    private func noteMiss(_ path: String) {
        let dir = RemotePath.parent(path)
        lock.lock()
        var entry = recentMisses[dir] ?? (0, .distantPast)
        entry = Date().timeIntervalSince(entry.last) < 2 ? (entry.count + 1, Date()) : (1, Date())
        recentMisses[dir] = entry
        let start = entry.count == 2 && prefetching.insert(dir).inserted
        let siblings = start ? (listings[dir]?.items.values.filter {
            !$0.isDirectory && !$0.isSymlink && $0.size <= Self.prefetchMaxSize
        } ?? []) : []
        var candidates = siblings.map { RemotePath.join(dir, $0.name) }.sorted()
        if start, let parentListing = listings[RemotePath.parent(dir)] {
            // Readers that go through a tree in path order (git) reach the next folders soon.
            let name = RemotePath.name(dir)
            let next = parentListing.items.values.filter { $0.isDirectory && !$0.isSymlink && $0.name > name }
                .map(\.name).sorted().prefix(2)
            for folder in next {
                let folderPath = RemotePath.join(RemotePath.parent(dir), folder)
                let files = listings[folderPath]?.items.values.filter {
                    !$0.isDirectory && !$0.isSymlink && $0.size <= Self.prefetchMaxSize
                } ?? []
                candidates += files.map { RemotePath.join(folderPath, $0.name) }.sorted()
            }
        }
        let uncached = candidates.filter { contentStamps[$0] == nil }
        lock.unlock()
        guard start else { return }
        let done = BlockOperation { [weak self] in
            self?.lock.lock()
            self?.prefetching.remove(dir)
            self?.lock.unlock()
        }
        for sibling in uncached.prefix(96) where sibling != path {
            let op = BlockOperation { [weak self] in _ = try? self?.localCopy(sibling) }
            done.addDependency(op)
            background.addOperation(op)
        }
        background.addOperation(done)
    }

    // MARK: Partial reads

    /// Files above this size are read block by block when the backend supports ranges.
    static let blockThreshold: UInt64 = 8 << 20
    static let blockSize: UInt64 = 1 << 20

    private final class BlockFile {
        let url: URL
        let size: UInt64
        let modified: Date
        var present = Set<UInt64>()
        let lock = NSLock()
        init(url: URL, size: UInt64, modified: Date) { self.url = url; self.size = size; self.modified = modified }
    }
    private var blockFiles: [String: BlockFile] = [:]

    private func dropBlocks(_ path: String) {
        lock.lock()
        let bf = blockFiles.removeValue(forKey: path)
        lock.unlock()
        if let bf { try? FileManager.default.removeItem(at: bf.url) }
    }

    /// Reads part of a file. Small files are fetched whole and cached; large ones only fetch the
    /// 1 MB blocks that are actually read (git pack files, logs, media).
    public func read(_ path: String, offset: UInt64, length: Int) throws -> Data {
        let path = RemotePath.normalize(path)
        let item = try stat(path)
        if item.isDirectory { throw RemoteError.unsupported("cannot read a folder as a file") }

        lock.lock()
        let stamp = contentStamps[path]
        lock.unlock()
        let haveWhole = stamp.map { $0.size == item.size && $0.modified == item.modified } ?? false
        if haveWhole || Self.isLocalOnly(path) || item.size <= Self.blockThreshold || !backend.supportsRangeReads {
            return try Self.pread(try localCopy(path), offset: offset, length: length)
        }
        guard offset < item.size, length > 0 else { return Data() }

        lock.lock()
        var bf = blockFiles[path]
        if bf == nil || bf!.size != item.size || bf!.modified != item.modified {
            if let old = bf { try? FileManager.default.removeItem(at: old.url) }
            let url = contentDir.appendingPathComponent(Self.key(path) + ".blocks")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            bf = BlockFile(url: url, size: item.size, modified: item.modified)
            blockFiles[path] = bf
        }
        lock.unlock()
        let file = bf!

        let end = min(item.size, offset + UInt64(length))
        file.lock.lock()
        defer { file.lock.unlock() }
        for block in (offset / Self.blockSize)...((end - 1) / Self.blockSize) where !file.present.contains(block) {
            let start = block * Self.blockSize
            let tread = Date()
            let data = try backend.read(path, offset: start, length: Int(min(Self.blockSize, item.size - start)))
            Stats.shared.record("backend.read", since: tread)
            guard let fh = try? FileHandle(forWritingTo: file.url) else { throw RemoteError.protocolError("cache write failed") }
            try fh.seek(toOffset: start)
            try fh.write(contentsOf: data)
            try fh.close()
            file.present.insert(block)
        }
        return try Self.pread(file.url, offset: offset, length: Int(end - offset))
    }

    static func pread(_ url: URL, offset: UInt64, length: Int) throws -> Data {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw RemoteError.protocolError("cache read failed") }
        defer { try? fh.close() }
        try fh.seek(toOffset: offset)
        return try fh.read(upToCount: length) ?? Data()
    }

    // MARK: Attributes and links

    public func setAttributes(_ path: String, mode: UInt32?, modified: Date?) throws {
        let path = RemotePath.normalize(path)
        if Self.isLocalOnly(path) { return }
        try ensureWritable(path)
        try backend.setAttributes(path, mode: mode, modified: modified)
        if var item = try? stat(path) {
            if let mode { item.mode = mode }
            if let modified { item.modified = modified }
            patchParent(of: path, with: item)
            lock.lock()
            var updated: (size: UInt64, modified: Date)?
            if modified != nil, var stamp = contentStamps[path] {
                // The bytes did not change, so the cached copy stays valid under the new mtime.
                stamp.modified = item.modified
                contentStamps[path] = stamp
                updated = stamp
            }
            lock.unlock()
            if let updated { store.recordStamp(path, size: updated.size, modified: updated.modified) }
        }
    }

    public func readLink(_ path: String) throws -> String {
        try backend.readLink(RemotePath.normalize(path))
    }

    public func makeSymlink(_ path: String, target: String) throws {
        try ensureWritable(path)
        try backend.makeSymlink(RemotePath.normalize(path), target: target)
        if let item = try? backend.stat(RemotePath.normalize(path)) {
            patchParent(of: path, with: item)
        } else {
            invalidate(RemotePath.parent(path))
        }
    }

    /// Forgets every folder listing so the next access reads fresh ones (e.g. after a git pull on the server).
    public func refreshFolders() {
        lock.lock()
        listings.removeAll()
        isOffline = false // asked for fresh folders: try the server again now
        lock.unlock()
    }

    /// After sleep or a network change: reconnect lazily and re-read folders.
    public func networkChanged() {
        backend.networkChanged()
        lock.lock()
        listings.removeAll()
        isOffline = false
        lock.unlock()
        // Changes made on the server while this Mac was away reach pinned folders now.
        syncAllPinned()
    }

    public func clearContentCache() {
        lock.lock()
        contentStamps.removeAll()
        listings.removeAll()
        lock.unlock()
        store.removeAllStamps()
        try? FileManager.default.removeItem(at: contentDir)
        try? FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
    }

    /// Writes what must outlive this session; called before unmounting.
    public func saveState() {
        store.save()
    }

    // MARK: Offline folders

    public var pinnedFolders: [String: PinState] {
        lock.lock()
        defer { lock.unlock() }
        return pinStates
    }

    /// Paths with a download in progress.
    public var activeDownloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(downloading.keys)
    }

    public func isPinned(_ path: String) -> Bool {
        store.pinnedRoot(of: RemotePath.normalize(path)) != nil
    }

    /// Keeps a folder (or a single file) and everything inside it downloaded, and in step with the server.
    public func pin(_ path: String) {
        let path = RemotePath.normalize(path)
        store.setPinned(path, true)
        lock.lock()
        pinStates = pinStates.filter { $0.key == path || !OfflineStore.isInside($0.key, path) }
        pinStates[path] = .syncing(done: 0, total: 0)
        lock.unlock()
        background.addOperation { [weak self] in self?.syncPinned(path) }
    }

    /// Stops keeping a folder offline. Its files stay cached until evicted or replaced.
    public func unpin(_ path: String) {
        let path = RemotePath.normalize(path)
        store.setPinned(path, false)
        lock.lock()
        pinStates[path] = nil
        lock.unlock()
    }

    /// Frees the disk space used by cached copies under `path`. Pinned files are kept.
    @discardableResult
    public func evict(_ path: String) -> Int {
        let path = RemotePath.normalize(path)
        lock.lock()
        let victims = contentStamps.keys.filter {
            ($0 == path || OfflineStore.isInside($0, path)) && downloading[$0] == nil
        }
        lock.unlock()
        let removable = victims.filter { store.pinnedRoot(of: $0) == nil }
        lock.lock()
        for p in removable { contentStamps[p] = nil }
        lock.unlock()
        store.removeStamps(removable)
        for p in removable {
            try? FileManager.default.removeItem(at: contentDir.appendingPathComponent(Self.key(p)))
            dropBlocks(p)
        }
        return removable.count
    }

    private func syncAllPinned() {
        for root in store.pinnedRoots {
            lock.lock()
            let busy: Bool
            if case .syncing(_, let total) = pinStates[root], total > 0 { busy = true } else { busy = false }
            lock.unlock()
            if !busy { background.addOperation { [weak self] in self?.syncPinned(root) } }
        }
    }

    /// Re-pins everything after the connection comes back, and checks pinned folders again.
    public func resyncPinned() {
        lock.lock()
        isOffline = false
        lock.unlock()
        syncAllPinned()
    }

    /// Walks a pinned folder with fresh listings and downloads every file that is missing or changed.
    private func syncPinned(_ root: String) {
        guard store.pinnedRoot(of: root) == root else { return }
        var files: [String] = []
        var folders = [root]
        do {
            var ancestor = root
            while ancestor != "/" {
                ancestor = RemotePath.parent(ancestor)
                _ = try fetchListing(ancestor, prefetchChildren: false)
            }
            let rootItem = try stat(root)
            if !rootItem.isDirectory {
                files = [root]
                folders = []
            }
            while let folder = folders.popLast() {
                invalidate(folder)
                for item in try fetchListing(folder, prefetchChildren: false) {
                    let child = RemotePath.join(folder, item.name)
                    if item.isSymlink { continue }
                    if item.isDirectory { folders.append(child) } else if !Self.isLocalOnly(child) { files.append(child) }
                }
                setPinState(root, .syncing(done: 0, total: files.count))
            }
            if isOffline { throw RemoteError.network("offline") }
            for (i, file) in files.enumerated() {
                guard store.pinnedRoot(of: file) != nil else { return } // unpinned meanwhile
                _ = try localCopy(file)
                setPinState(root, .syncing(done: i + 1, total: files.count))
            }
            setPinState(root, .synced(checked: Date()))
        } catch {
            setPinState(root, .failed(error.localizedDescription))
        }
        store.save()
    }

    private func setPinState(_ root: String, _ state: PinState) {
        lock.lock()
        if pinStates[root] != nil { pinStates[root] = state }
        lock.unlock()
    }
}
