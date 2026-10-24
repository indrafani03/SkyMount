import Foundation

/// Counters for diagnosing slow mounts; collected only when SKYMOUNT_DEBUG is set.
public final class Stats {
    public static let shared = Stats()
    public static let enabled = ProcessInfo.processInfo.environment["SKYMOUNT_DEBUG"] != nil

    private struct Entry { var count = 0; var seconds = 0.0 }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    public func record(_ name: String, since start: Date) {
        guard Self.enabled else { return }
        let elapsed = Date().timeIntervalSince(start)
        lock.lock()
        entries[name, default: Entry()].count += 1
        entries[name, default: Entry()].seconds += elapsed
        lock.unlock()
    }

    /// Returns a table of counters and resets them.
    public func drain() -> String {
        lock.lock()
        let snapshot = entries
        entries.removeAll()
        lock.unlock()
        return snapshot.sorted { $0.value.seconds > $1.value.seconds }
            .map { String(format: "%-22@ %6d  %8.2fs", $0.key as NSString, $0.value.count, $0.value.seconds) }
            .joined(separator: "\n")
    }
}
