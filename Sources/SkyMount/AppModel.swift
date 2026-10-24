import AppKit
import Network
import ServiceManagement
import SkyMountCore
import SkyMountShared

enum MountStatus: Equatable {
    case idle
    case working(String)
    case mounted(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Not mounted"
        case .working(let what): return what
        case .mounted: return "Mounted"
        case .failed: return "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "externaldrive"
        case .working: return "arrow.triangle.2.circlepath"
        case .mounted: return "externaldrive.fill.badge.checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var connections: [ConnectionConfig] = ConnectionStore.load()
    @Published private(set) var status: [UUID: MountStatus] = [:]
    @Published var saveError: String?
    /// Connection selected in the Connections window.
    @Published var selection: UUID?

    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginItemError: String?

    /// Offline folders, uploads and downloads per mounted connection, for the menu.
    @Published private(set) var activity: [UUID: VolumeActivity] = [:]
    /// True while anything uploads, downloads or syncs an offline folder, and for two seconds
    /// after, so a run of small files does not make the menu bar icon flicker.
    @Published private(set) var isTransferring = false
    private var lastTransfer = Date.distantPast

    private var volumes: [UUID: VolumeMount] = [:]
    /// Automatic mounts that failed for lack of a network (Wi-Fi not up yet right after login):
    /// how many tries so far, and the scheduled next one.
    private var autoMountTries: [UUID: Int] = [:]
    private var autoMountRetries: [UUID: Task<Void, Never>] = [:]
    private var watcher: Timer?
    private var activityTimer: Timer?
    /// Shared with the Finder extension; nil when running outside the signed app bundle.
    private let bridgeFolder = FinderBridge.sharedFolder()
    private var lastBridgeStatus: BridgeStatus?
    private let pathMonitor = NWPathMonitor()
    private var lastPath: String?

    init() {
        watcher = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.dropEjectedVolumes() }
        }
        // Connections opened before sleep or on another network are dead; reconnect on next use.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)|\(path.availableInterfaces.map(\.name).joined(separator: ","))"
            Task { @MainActor in
                guard let self else { return }
                if let last = self.lastPath, last != signature, path.status == .satisfied { self.networkChanged() }
                self.lastPath = signature
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshActivity() }
        }
        if let bridgeFolder {
            try? FileManager.default.createDirectory(at: bridgeFolder, withIntermediateDirectories: true)
            _ = BridgeRequest.drain(from: bridgeFolder) // menu clicks from before this launch are stale
            FinderBridge.observe(FinderBridge.requestPosted) { [weak self] in
                Task { @MainActor in self?.handleFinderRequests() }
            }
        }
        for c in connections where c.autoMount { mount(c.id, automatic: true) }
    }

    // MARK: Finder extension

    private func refreshActivity() async {
        let mounted = volumes
        let snapshot = await Task.detached { mounted.mapValues(\.activity) }.value
        if snapshot != activity { activity = snapshot }
        let busy = snapshot.values.contains { a in
            !a.uploads.isEmpty || !a.downloads.isEmpty
                || a.pinned.values.contains { if case .syncing = $0 { return true } else { return false } }
        }
        if busy { lastTransfer = Date() }
        let showing = busy || Date().timeIntervalSince(lastTransfer) < 2
        if showing != isTransferring { isTransferring = showing }
        publishBridgeStatus()
    }

    private func publishBridgeStatus() {
        guard let bridgeFolder else { return }
        let status = BridgeStatus(volumes: volumes.compactMap { id, volume in
            guard let point = volume.mountPoint, let a = activity[id] else { return nil }
            return BridgeVolume(
                mountPoint: point, offline: a.offline, readOnly: volume.fs.readOnly,
                pinned: a.pinned.mapValues {
                    switch $0 {
                    case .syncing: return .syncing
                    case .synced: return .synced
                    case .failed: return .failed
                    }
                },
                uploads: a.uploads.mapValues {
                    switch $0 {
                    case .waiting: return .waiting
                    case .uploading: return .uploading
                    case .failed: return .failed
                    }
                },
                downloads: a.downloads)
        }.sorted { $0.mountPoint < $1.mountPoint })
        guard status != lastBridgeStatus else { return }
        do {
            try status.write(to: bridgeFolder)
            lastBridgeStatus = status
            FinderBridge.post(FinderBridge.statusChanged)
        } catch {
            NSLog("SkyMount: could not share status with Finder: %@", error.localizedDescription)
        }
    }

    private func handleFinderRequests() {
        guard let bridgeFolder else { return }
        for request in BridgeRequest.drain(from: bridgeFolder) {
            for local in request.paths {
                guard let volume = volumes.values.first(where: { $0.volumePath(forLocalPath: local) != nil }),
                      let path = volume.volumePath(forLocalPath: local) else { continue }
                apply(request.action, to: path, in: volume)
            }
        }
        Task { await refreshActivity() }
    }

    private func apply(_ action: BridgeRequest.Action, to path: String, in volume: VolumeMount) {
        switch action {
        case .pin: volume.fs.pin(path)
        case .unpin: volume.fs.unpin(path)
        case .evict: Task.detached { volume.fs.evict(path) }
        case .refresh: volume.refreshFolders()
        }
    }

    /// Stops keeping a folder offline from the menu.
    func unpin(_ path: String, in id: UUID) {
        volumes[id]?.fs.unpin(path)
        Task { await refreshActivity() }
    }

    private func networkChanged() {
        let mounted = Array(volumes.values)
        Task.detached { mounted.forEach { $0.networkChanged() } }
        // The network just came up: automatic mounts waiting for it go now.
        for id in autoMountTries.keys { mount(id, automatic: true) }
    }

    private func scheduleAutoMountRetry(_ id: UUID) {
        let tries = autoMountTries[id, default: 0] + 1
        autoMountTries[id] = tries
        let delay = min(300, 10 * pow(2, Double(min(tries, 6) - 1))) // 10 s, 20 s, 40 s ... 5 min
        autoMountRetries[id]?.cancel()
        autoMountRetries[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.mount(id, automatic: true)
        }
    }

    private func stopAutoMountRetry(_ id: UUID) {
        autoMountRetries.removeValue(forKey: id)?.cancel()
        autoMountTries[id] = nil
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Could not change the login item: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func status(of id: UUID) -> MountStatus { status[id] ?? .idle }
    var anyMounted: Bool { status.values.contains { if case .mounted = $0 { return true } else { return false } } }

    // MARK: Editing

    func upsert(_ config: ConnectionConfig) {
        if let i = connections.firstIndex(where: { $0.id == config.id }) {
            connections[i] = config
        } else {
            connections.append(config)
        }
        persist()
    }

    func delete(_ id: UUID) {
        unmount(id)
        if let c = connections.first(where: { $0.id == id }) {
            SecretField.allCases.forEach { c.setSecret($0, nil) }
        }
        connections.removeAll { $0.id == id }
        status[id] = nil
        persist()
    }

    private func persist() {
        do {
            try ConnectionStore.save(connections)
            saveError = nil
        } catch {
            saveError = "Could not save connections: \(error.localizedDescription)"
        }
    }

    private func storeFingerprint(_ fingerprint: String, for id: UUID) {
        guard var c = connections.first(where: { $0.id == id }) else { return }
        c.sftpHostFingerprint = fingerprint
        upsert(c)
    }

    func resetHostKey(_ id: UUID) {
        guard var c = connections.first(where: { $0.id == id }) else { return }
        c.sftpHostFingerprint = nil
        upsert(c)
    }

    // MARK: Mounting

    func toggle(_ id: UUID) {
        if case .mounted = status(of: id) { unmount(id) } else { mount(id) }
    }

    /// `automatic` mounts (at launch) are retried while the server cannot be reached.
    func mount(_ id: UUID, automatic: Bool = false) {
        guard let config = connections.first(where: { $0.id == id }) else { return }
        if case .working = status(of: id) { return }
        if case .mounted = status(of: id) { return }
        if !automatic { stopAutoMountRetry(id) }
        if let problem = config.validationProblem() {
            status[id] = .failed(problem)
            return
        }
        status[id] = .working("Connecting…")
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkyMount/\(id.uuidString)", isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let pendingDir = support.appendingPathComponent("SkyMount/Pending/\(id.uuidString)", isDirectory: true)
        let pinsURL = support.appendingPathComponent("SkyMount/Offline/\(id.uuidString).json")

        let fingerprintSink: (String) -> Void = { [weak self] fp in
            Task { @MainActor in self?.storeFingerprint(fp, for: id) }
        }
        Task { [weak self] in
            let result = await Task.detached { () -> Result<(VolumeMount, String), Error> in
                Result {
                    let backend = try BackendFactory.make(config, onFingerprint: fingerprintSink)
                    let volume = VolumeMount(volumeName: config.displayName, backend: backend, cacheRoot: cacheRoot,
                                             pendingDir: pendingDir, listingTTL: config.listingTTL,
                                             readOnly: config.readOnly, pinsURL: pinsURL)
                    let point = try volume.mount(log: { NSLog("SkyMount %@: %@", config.displayName, $0) })
                    return (volume, point)
                }
            }.value
            switch result {
            case .success(let (volume, point)):
                self?.volumes[id] = volume
                self?.status[id] = .mounted(point)
                self?.stopAutoMountRetry(id)
            case .failure(let error):
                if automatic, config.autoMount, case RemoteError.network = error {
                    self?.status[id] = .failed("Waiting for the network: \(error.localizedDescription)")
                    self?.scheduleAutoMountRetry(id)
                } else {
                    self?.status[id] = .failed(error.localizedDescription)
                    if automatic { self?.stopAutoMountRetry(id) }
                }
            }
        }
    }

    func unmount(_ id: UUID) {
        stopAutoMountRetry(id)
        guard let volume = volumes.removeValue(forKey: id) else {
            if case .failed = status(of: id) { status[id] = .idle }
            return
        }
        status[id] = .working("Uploading changes and unmounting…")
        Task { [weak self] in
            await Task.detached { volume.unmount() }.value
            self?.status[id] = .idle
        }
    }

    func unmountAllBlocking() {
        for volume in volumes.values { volume.unmount() }
        volumes.removeAll()
    }

    /// Re-reads folders on next access, for changes made on the server (a git pull, a deploy).
    func refreshFolders(_ id: UUID) {
        volumes[id]?.refreshFolders()
    }

    func showInFinder(_ id: UUID) {
        guard case .mounted(let point) = status(of: id) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: point))
    }

    /// Volumes ejected from Finder disappear without telling us; release their servers.
    private func dropEjectedVolumes() {
        for (id, volume) in volumes where !volume.isMounted {
            volumes[id] = nil
            Task.detached { volume.unmount() }
            status[id] = .idle
        }
    }

    // MARK: Checks

    /// Connects and lists the root folder without mounting. Returns a human-readable result.
    nonisolated func test(_ config: ConnectionConfig) async -> Result<String, Error> {
        do {
            let backend = try BackendFactory.make(config) { _ in }
            try backend.connect()
            let count = try backend.list("/").count
            backend.disconnect()
            return .success("Connected. The top folder has \(count) item\(count == 1 ? "" : "s").")
        } catch {
            return .failure(error)
        }
    }
}
