import Foundation

/// What the menu bar app and its Finder extension exchange through their shared app group folder.
/// The app writes `status.json` and posts `statusChanged`; the extension drops one request file per
/// menu action into `requests/` and posts `requestPosted`.
public enum FinderBridge {
    public static let statusChanged = "id.inkpoint.skymount.status-changed"
    public static let requestPosted = "id.inkpoint.skymount.request"
    /// Info.plist key holding the app group ID, so it follows the signing team.
    public static let appGroupKey = "SkyMountAppGroup"

    public static func sharedFolder(bundle: Bundle = .main) -> URL? {
        guard let group = bundle.object(forInfoDictionaryKey: appGroupKey) as? String, !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Calls `handler` on the main queue whenever `name` is posted by any process.
    public static func observe(_ name: String, handler: @escaping () -> Void) {
        let box = Unmanaged.passRetained(HandlerBox(handler)).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), box, { _, observer, _, _, _ in
            guard let observer else { return }
            let box = Unmanaged<HandlerBox>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { box.handler() }
        }, name as CFString, nil, .deliverImmediately)
    }

    private final class HandlerBox {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }
}

public struct BridgeStatus: Codable, Equatable {
    public var volumes: [BridgeVolume]
    public init(volumes: [BridgeVolume]) { self.volumes = volumes }

    public static func read(from folder: URL) -> BridgeStatus? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("status.json")) else { return nil }
        return try? JSONDecoder().decode(BridgeStatus.self, from: data)
    }

    public func write(to folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent("status.json"), options: .atomic)
    }

    /// The volume holding a local path, and the path inside that volume ("/a/b.txt").
    public func locate(_ localPath: String) -> (BridgeVolume, String)? {
        for v in volumes {
            if localPath == v.mountPoint { return (v, "/") }
            if localPath.hasPrefix(v.mountPoint + "/") { return (v, String(localPath.dropFirst(v.mountPoint.count))) }
        }
        return nil
    }
}

/// Badge identifiers registered by the extension.
public enum BridgeBadge: String, CaseIterable {
    case offline, syncing, uploading, waiting, failed
}

public struct BridgeVolume: Codable, Equatable {
    public enum PinState: String, Codable { case syncing, synced, failed }
    public enum UploadState: String, Codable { case waiting, uploading, failed }

    public var mountPoint: String
    public var offline: Bool
    public var readOnly: Bool
    /// Pinned folders (or files) and how their sync stands.
    public var pinned: [String: PinState]
    public var uploads: [String: UploadState]
    public var downloads: [String]

    public init(mountPoint: String, offline: Bool, readOnly: Bool, pinned: [String: PinState],
                uploads: [String: UploadState], downloads: [String]) {
        self.mountPoint = mountPoint
        self.offline = offline
        self.readOnly = readOnly
        self.pinned = pinned
        self.uploads = uploads
        self.downloads = downloads
    }

    /// The pinned folder containing `path`, or `path` itself when it is pinned.
    public func pinnedRoot(of path: String) -> String? {
        var p = path
        while true {
            if pinned[p] != nil { return p }
            if p == "/" || p.isEmpty { return nil }
            let parent = (p as NSString).deletingLastPathComponent
            p = parent.isEmpty ? "/" : parent
        }
    }

    public func badge(for path: String) -> BridgeBadge? {
        switch uploads[path] {
        case .uploading: return .uploading
        case .waiting: return .waiting
        case .failed: return .failed
        case nil: break
        }
        if downloads.contains(path) { return .syncing }
        guard let root = pinnedRoot(of: path) else { return nil }
        switch pinned[root] {
        case .synced: return .offline
        case .syncing: return .syncing
        case .failed: return .failed
        case nil: return nil
        }
    }
}

public struct BridgeRequest: Codable {
    public enum Action: String, Codable { case pin, unpin, evict, refresh }
    public var action: Action
    /// Absolute local paths of the items the action was chosen for.
    public var paths: [String]

    public init(action: Action, paths: [String]) {
        self.action = action
        self.paths = paths
    }

    public static func folder(in shared: URL) -> URL { shared.appendingPathComponent("requests", isDirectory: true) }

    public func send(via shared: URL) throws {
        let dir = Self.folder(in: shared)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: dir.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        FinderBridge.post(FinderBridge.requestPosted)
    }

    /// Reads and removes every pending request, oldest first.
    public static func drain(from shared: URL) -> [BridgeRequest] {
        let dir = folder(in: shared)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        let sorted = names.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        return sorted.compactMap { url in
            defer { try? fm.removeItem(at: url) }
            return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(BridgeRequest.self, from: $0) }
        }
    }
}
