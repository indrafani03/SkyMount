import Cocoa
import FinderSync
import SkyMountShared

/// Finder extension: badges for files kept offline or waiting to upload, and a context menu to keep
/// folders offline, free their space, or re-read them from the server. Everything it knows comes
/// from the menu bar app through the shared app group folder.
@objc(SkyMountFinderSync)
final class SkyMountFinderSync: FIFinderSync {
    private let shared = FinderBridge.sharedFolder(bundle: Bundle(for: SkyMountFinderSync.self))
    private var status = BridgeStatus(volumes: [])
    /// Badges already given to items Finder showed, so a status change only touches what changed.
    private var shown: [URL: String] = [:]
    /// Finder asks for badges from several threads; status and shown are only touched under it.
    private let lock = NSLock()

    override init() {
        super.init()
        let controller = FIFinderSyncController.default()
        for badge in BridgeBadge.allCases {
            controller.setBadgeImage(Self.image(for: badge), label: Self.label(for: badge), forBadgeIdentifier: badge.rawValue)
        }
        reload()
        FinderBridge.observe(FinderBridge.statusChanged) { [weak self] in self?.reload() }
    }

    private func reload() {
        guard let shared else { return }
        let fresh = BridgeStatus.read(from: shared) ?? BridgeStatus(volumes: [])
        lock.lock()
        status = fresh
        var changed: [(URL, String)] = []
        for (url, old) in shown {
            let new = badge(for: url)
            if new != old {
                changed.append((url, new))
                shown[url] = new
            }
        }
        lock.unlock()
        let urls = Set(fresh.volumes.map { URL(fileURLWithPath: $0.mountPoint) })
        let controller = FIFinderSyncController.default()
        if controller.directoryURLs != urls { controller.directoryURLs = urls }
        for (url, id) in changed { controller.setBadgeIdentifier(id, for: url) }
    }

    /// Call with `lock` held.
    private func badge(for url: URL) -> String {
        guard let (volume, path) = status.locate(url.path) else { return "" }
        return volume.badge(for: path)?.rawValue ?? ""
    }

    // MARK: Badges

    override func requestBadgeIdentifier(for url: URL) {
        lock.lock()
        let id = badge(for: url)
        shown[url] = id
        lock.unlock()
        FIFinderSyncController.default().setBadgeIdentifier(id, for: url)
    }

    override func endObservingDirectory(at url: URL) {
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        lock.lock()
        shown = shown.filter { !$0.key.path.hasPrefix(prefix) }
        lock.unlock()
    }

    // MARK: Menu

    private var targets: [URL] = []

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        switch menuKind {
        case .contextualMenuForItems:
            targets = controller.selectedItemURLs() ?? []
        case .contextualMenuForContainer:
            targets = controller.targetedURL().map { [$0] } ?? []
        default:
            return nil
        }
        lock.lock()
        let located = targets.compactMap { status.locate($0.path) }
        lock.unlock()
        guard !located.isEmpty, located.count == targets.count else { return nil }

        let menu = NSMenu(title: "")
        let notPinned = located.contains { $0.0.pinnedRoot(of: $0.1) == nil }
        let pinnedRoots = located.contains { $0.0.pinned[$0.1] != nil }
        if notPinned {
            add("Keep Offline", #selector(pin(_:)), symbol: "arrow.down.circle", to: menu)
        }
        if pinnedRoots {
            add("Stop Keeping Offline", #selector(unpin(_:)), symbol: "xmark.circle", to: menu)
        }
        if notPinned {
            add("Free Up Space", #selector(evict(_:)), symbol: "icloud.and.arrow.up", to: menu)
        }
        add("Refresh from Server", #selector(refresh(_:)), symbol: "arrow.clockwise", to: menu)
        return menu
    }

    private func add(_ title: String, _ action: Selector, symbol: String, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    @objc private func pin(_ sender: Any?) { send(.pin) }
    @objc private func unpin(_ sender: Any?) { send(.unpin) }
    @objc private func evict(_ sender: Any?) { send(.evict) }
    @objc private func refresh(_ sender: Any?) { send(.refresh) }

    private func send(_ action: BridgeRequest.Action) {
        guard let shared, !targets.isEmpty else { return }
        try? BridgeRequest(action: action, paths: targets.map(\.path)).send(via: shared)
    }

    // MARK: Badge artwork

    private static func label(for badge: BridgeBadge) -> String {
        switch badge {
        case .offline: return "Available offline"
        case .syncing: return "Downloading"
        case .uploading: return "Uploading"
        case .waiting: return "Waiting to upload"
        case .failed: return "Upload or sync failed"
        }
    }

    /// A filled circle with a white glyph: colour carries the state at small sizes, the glyph
    /// tells waiting, moving and failed apart for people who do not see the colour.
    private static func image(for badge: BridgeBadge) -> NSImage {
        let (symbol, color): (String, NSColor) = {
            switch badge {
            case .offline: return ("checkmark", .systemGreen)
            case .syncing: return ("arrow.down", .systemBlue)
            case .uploading: return ("arrow.up", .systemBlue)
            case .waiting: return ("clock", .systemGray)
            case .failed: return ("exclamationmark", .systemRed)
            }
        }()
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            NSColor.white.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let g = glyph.size
                glyph.draw(in: NSRect(x: (rect.width - g.width) / 2, y: (rect.height - g.height) / 2,
                                      width: g.width, height: g.height))
            }
            return true
        }
    }
}
