import Foundation

/// State of a folder kept offline ("pinned").
public enum PinState: Equatable, Sendable {
    /// Downloading what is missing or changed: `done` of `total` files checked so far.
    case syncing(done: Int, total: Int)
    /// Every file is on this Mac and matched the server at `checked`.
    case synced(checked: Date)
    /// The last pass stopped early; files already downloaded are still available.
    case failed(String)
}

/// What must outlive a mount session:
/// - the folders the user keeps offline (application support, so a cache purge never forgets them),
/// - folder listings inside those folders and the size/mtime of every cached file (caches), so a
///   remount reuses downloaded contents and a lost connection still shows pinned folders.
final class OfflineStore {
    private struct Stamp: Codable { var size: UInt64; var modified: Date }
    private struct Entry: Codable {
        var name: String
        var isDirectory: Bool
        var size: UInt64
        var modified: Date
        var id: String?
        var mode: UInt32?
        var isSymlink: Bool
    }
    private struct Index: Codable {
        var listings: [String: [Entry]] = [:]
        var stamps: [String: Stamp] = [:]
    }

    private let pinsURL: URL?
    private let indexURL: URL
    private let lock = NSLock()
    private var pins: Set<String> = []
    private var index = Index()
    private var dirty = false

    init(pinsURL: URL?, indexURL: URL) {
        self.pinsURL = pinsURL
        self.indexURL = indexURL
        if let pinsURL, let data = try? Data(contentsOf: pinsURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            pins = Set(list)
        }
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode(Index.self, from: data) {
            index = saved
        }
    }

    // MARK: Pins

    var pinnedRoots: [String] {
        lock.lock()
        defer { lock.unlock() }
        return pins.sorted()
    }

    /// The pinned folder containing `path` (or `path` itself), if any.
    func pinnedRoot(of path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return Self.root(of: path, in: pins)
    }

    private static func root(of path: String, in pins: Set<String>) -> String? {
        var p = path
        while true {
            if pins.contains(p) { return p }
            if p == "/" { return nil }
            p = RemotePath.parent(p)
        }
    }

    func setPinned(_ path: String, _ pinned: Bool) {
        lock.lock()
        if pinned {
            pins.insert(path)
            // A pinned folder inside this one is now covered by it.
            pins = pins.filter { $0 == path || !Self.isInside($0, path) }
        } else {
            pins.remove(path)
            index.listings = index.listings.filter { Self.keepsListing($0.key, pins) }
            dirty = true
        }
        let list = pins.sorted()
        lock.unlock()
        if let pinsURL, let data = try? JSONEncoder().encode(list) {
            try? FileManager.default.createDirectory(at: pinsURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: pinsURL, options: .atomic)
        }
    }

    static func isInside(_ path: String, _ folder: String) -> Bool {
        folder == "/" ? path != "/" : path.hasPrefix(folder + "/")
    }

    // MARK: Index

    /// Folders worth keeping a listing of: pinned ones, everything inside them, and the folders
    /// leading to them (without those, a pinned folder cannot be reached while offline).
    private static func keepsListing(_ path: String, _ pins: Set<String>) -> Bool {
        root(of: path, in: pins) != nil || pins.contains { isInside($0, path) }
    }

    func recordListing(_ path: String, _ items: [RemoteItem]) {
        lock.lock()
        defer { lock.unlock() }
        guard Self.keepsListing(path, pins) else { return }
        index.listings[path] = items.map {
            Entry(name: $0.name, isDirectory: $0.isDirectory, size: $0.size, modified: $0.modified, id: $0.id,
                  mode: $0.mode, isSymlink: $0.isSymlink)
        }
        dirty = true
    }

    func savedListing(_ path: String) -> [RemoteItem]? {
        lock.lock()
        defer { lock.unlock() }
        return index.listings[path]?.map {
            RemoteItem(name: $0.name, isDirectory: $0.isDirectory, size: $0.size, modified: $0.modified, id: $0.id,
                       mode: $0.mode, isSymlink: $0.isSymlink)
        }
    }

    func savedStamps() -> [String: (size: UInt64, modified: Date)] {
        lock.lock()
        defer { lock.unlock() }
        return index.stamps.mapValues { ($0.size, $0.modified) }
    }

    func recordStamp(_ path: String, size: UInt64, modified: Date) {
        lock.lock()
        index.stamps[path] = Stamp(size: size, modified: modified)
        dirty = true
        lock.unlock()
    }

    func removeStamps(_ paths: [String]) {
        lock.lock()
        for p in paths { index.stamps[p] = nil }
        dirty = true
        lock.unlock()
    }

    func removeAllStamps() {
        lock.lock()
        index.stamps.removeAll()
        dirty = true
        lock.unlock()
    }

    /// Writes the index if it changed since the last save.
    func save() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = index
        dirty = false
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
