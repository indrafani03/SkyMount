import Foundation
import CryptoKit

enum NFSStatus: UInt32 {
    case ok = 0, perm = 1, noent = 2, io = 5, acces = 13, exist = 17, notdir = 20, isdir = 21, inval = 22
    case rofs = 30, nametoolong = 63, notempty = 66, stale = 70
    case badhandle = 10001, notsupp = 10004, serverfault = 10006, jukebox = 10008
}

struct NFSError: Error {
    let status: NFSStatus

    init(_ status: NFSStatus) { self.status = status }

    init(_ error: Error) {
        if let e = error as? NFSError { self = e; return }
        switch error as? RemoteError {
        case .notFound: status = .noent
        case .permissionDenied, .authentication: status = .acces
        case .alreadyExists: status = .exist
        case .notEmpty: status = .notempty
        case .unsupported: status = .notsupp
        default: status = .io
        }
    }
}

/// NFSv3 + MOUNTv3 server (RFC 1813) in front of a CachedFileSystem.
///
/// - Every procedure runs as a job. If it has not finished after a few seconds the reply is
///   NFS3ERR_JUKEBOX; the kernel retries the same request later and gets the finished result.
///   The server therefore always answers quickly, so slow networks never make the kernel declare
///   the mount dead.
/// - Writes go to a local working copy and are acknowledged UNSTABLE. COMMIT (sent on close/fsync)
///   uploads the file; files left dirty are uploaded after a few idle seconds. Each dirty file has a
///   journal entry on disk so an interrupted upload is retried at the next mount.
final class NFSServer {
    let fs: CachedFileSystem
    let exportPath: String
    var log: (String) -> Void = { _ in }

    private let secret: Data
    private let writeVerifier: Data
    private let fsid: UInt64
    private let uid = getuid()
    private let gid = getgid()
    private let rootTime = Date()

    private let lock = NSLock()
    private var pathByID: [UInt64: String] = [1: "/"]
    private var idByPath: [String: UInt64] = ["/": 1]

    private final class WorkingFile {
        let url: URL
        let journal: URL
        var dirty = false
        var generation = 0
        var modified = Date()
        /// Permission bits to apply after the upload. A file created read-only (git objects are
        /// 0444) must still accept the bytes written through the descriptor that created it.
        var pendingMode: UInt32?
        /// Client-chosen mtime to apply after the upload (cp -p, rsync, tar).
        var pendingMtime: Date?
        var uploading = false
        /// Failed uploads in a row; the next idle upload waits longer after each one.
        var failures = 0
        var retryAt = Date.distantPast
        var lastError: String?
        let lock = NSLock()        // guards the bytes and the counters
        let uploadLock = NSLock()  // one upload at a time
        init(url: URL) {
            self.url = url
            journal = url.appendingPathExtension("json")
        }
    }
    private var working: [UInt64: WorkingFile] = [:]
    private let workDir: URL

    private final class Job {
        let done = DispatchSemaphore(value: 0)
        var reply: XDRWriter?
        var finished = false
        let started = Date()
    }
    private var jobs: [String: Job] = [:]
    private let jobQueue = DispatchQueue(label: "skymount.nfs.jobs", attributes: .concurrent)
    private var timer: DispatchSourceTimer?
    /// EXCLUSIVE-create verifiers, so a retried create succeeds and a competing one fails.
    private var createVerifiers: [String: Data] = [:]
    /// Files created here that the server has not seen yet (path to file ID). They exist only as
    /// working copies until their first upload; temporary files deleted before then never travel.
    private var pendingNew: [String: UInt64] = [:]

    init(fs: CachedFileSystem, workDir: URL) {
        self.fs = fs
        self.workDir = workDir
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        secret = Self.random(8)
        writeVerifier = Self.random(8)
        fsid = secret.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        exportPath = "/" + Self.random(12).map { String(format: "%02x", $0) }.joined()

        let t = DispatchSource.makeTimerSource(queue: jobQueue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.housekeeping() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    private static func random(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }

    // MARK: Dispatch

    func handle(_ call: inout RPCCall) -> RPCResult {
        // Only the owning user may use the mount (AUTH_SYS identifies the caller). mount_nfs and some
        // kernel requests arrive as root, which can read everything on this Mac anyway.
        if call.procedure != 0, call.uid != uid, call.uid != 0 {
            log("rejected call from uid \(call.uid.map(String.init) ?? "none")")
            return .authError
        }
        switch call.program {
        case 100005:
            guard call.version == 3 else { return .programMismatch(low: 3, high: 3) }
            return mountProcedure(&call)
        case 100003:
            guard call.version == 3 else { return .programMismatch(low: 3, high: 3) }
            if call.procedure == 0 { return .success(XDRWriter()) }
            guard (1...21).contains(call.procedure) else { return .procedureUnavailable }
            return .success(runJob(call.procedure, call.args.remaining))
        default:
            return .programUnavailable
        }
    }

    private func mountProcedure(_ call: inout RPCCall) -> RPCResult {
        var w = XDRWriter()
        switch call.procedure {
        case 0, 3, 4: // NULL, UMNT, UMNTALL
            return .success(w)
        case 1: // MNT
            guard let path = try? call.args.string() else { return .garbageArguments }
            guard path == exportPath else {
                w.u32(NFSStatus.acces.rawValue)
                return .success(w)
            }
            w.u32(0)
            w.opaque(handle(1))
            w.u32(1)
            w.u32(1) // AUTH_SYS
            return .success(w)
        case 2, 5: // DUMP, EXPORT: advertise nothing; the export path is a per-mount secret.
            w.bool(false)
            return .success(w)
        default:
            return .procedureUnavailable
        }
    }

    /// Identical requests (the kernel's retry after JUKEBOX) share one job and its reply.
    private func runJob(_ procedure: UInt32, _ args: Data) -> XDRWriter {
        let key = "\(procedure):" + SHA256.hash(data: args).prefix(16).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let job: Job
        if let existing = jobs[key] {
            job = existing
        } else {
            job = Job()
            jobs[key] = job
            jobQueue.async { [self] in
                let reply = execute(procedure, args)
                lock.lock()
                job.reply = reply
                job.finished = true
                lock.unlock()
                job.done.signal()
            }
        }
        lock.unlock()

        if job.done.wait(timeout: .now() + 3) == .success {
            job.done.signal() // wake any other waiter of the same job
            lock.lock()
            if jobs[key] === job { jobs[key] = nil }
            let reply = job.reply!
            lock.unlock()
            return reply
        }
        Stats.shared.record("nfs.jukebox-reply", since: Date())
        var w = XDRWriter()
        w.u32(NFSStatus.jukebox.rawValue)
        for _ in 0..<Self.failureFields(procedure) { w.bool(false) }
        return w
    }

    private static let procedureNames = [1: "GETATTR", 2: "SETATTR", 3: "LOOKUP", 4: "ACCESS", 5: "READLINK",
                                         6: "READ", 7: "WRITE", 8: "CREATE", 9: "MKDIR", 10: "SYMLINK",
                                         12: "REMOVE", 13: "RMDIR", 14: "RENAME", 16: "READDIR", 17: "READDIRPLUS",
                                         18: "FSSTAT", 19: "FSINFO", 20: "PATHCONF", 21: "COMMIT"]

    private func execute(_ procedure: UInt32, _ args: Data) -> XDRWriter {
        let started = Date()
        defer { Stats.shared.record("nfs." + (Self.procedureNames[Int(procedure)] ?? "\(procedure)"), since: started) }
        var r = XDRReader(args)
        var w = XDRWriter(capacity: 1024)
        do {
            switch procedure {
            case 1: try getattr(&r, &w)
            case 2: try setattr(&r, &w)
            case 3: try lookup(&r, &w)
            case 4: try access(&r, &w)
            case 5: try readlink(&r, &w)
            case 6: try read(&r, &w)
            case 7: try write(&r, &w)
            case 8: try create(&r, &w)
            case 9: try mkdir(&r, &w)
            case 10: try symlink(&r, &w)
            case 12: try remove(&r, &w, directory: false)
            case 13: try remove(&r, &w, directory: true)
            case 14: try rename(&r, &w)
            case 16: try readdir(&r, &w, plus: false)
            case 17: try readdir(&r, &w, plus: true)
            case 18: try fsstat(&r, &w)
            case 19: try fsinfo(&r, &w)
            case 20: try pathconf(&r, &w)
            case 21: try commit(&r, &w)
            default: throw NFSError(.notsupp) // MKNOD, LINK
            }
        } catch {
            let status = error is XDRReader.Underflow ? .inval : NFSError(error).status
            if status == .io || status == .serverfault { log("NFS proc \(procedure): \(error.localizedDescription)") }
            w = XDRWriter()
            w.u32(status.rawValue)
            for _ in 0..<Self.failureFields(procedure) { w.bool(false) }
        }
        return w
    }

    /// RFC 1813 resfail bodies are absent attributes: post_op_attr = 1 bool, wcc_data = 2.
    private static func failureFields(_ procedure: UInt32) -> Int {
        switch procedure {
        case 1: return 0                              // GETATTR
        case 3, 4, 5, 6, 16, 17, 18, 19, 20: return 1 // LOOKUP, ACCESS, READLINK, READ, READDIR(PLUS), FS*
        case 14, 15: return 4                         // RENAME, LINK
        default: return 2                             // SETATTR, WRITE, CREATE, MKDIR, SYMLINK, REMOVE, RMDIR, COMMIT
        }
    }

    // MARK: Handles and IDs

    private func handle(_ id: UInt64) -> Data {
        var w = XDRWriter()
        w.u64(id)
        return secret + w.data
    }

    /// File IDs come from the path so they stay the same across remounts; git keeps inode numbers
    /// in its index and would otherwise re-read every file after each mount.
    private func id(for path: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let id = idByPath[path] { return id }
        var id = SHA256.hash(data: Data(path.utf8)).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } >> 1
        while id <= 1 || pathByID[id] != nil { id &+= 1 }
        idByPath[path] = id
        pathByID[id] = path
        return id
    }

    private func readHandle(_ r: inout XDRReader) throws -> (UInt64, String) {
        let fh = try r.opaque(max: 64)
        guard fh.count == 16, fh.prefix(8) == secret else { throw NFSError(.badhandle) }
        var hr = XDRReader(fh.suffix(8))
        let id = try hr.u64()
        lock.lock()
        defer { lock.unlock() }
        guard let path = pathByID[id] else { throw NFSError(.stale) }
        return (id, path)
    }

    private func readName(_ r: inout XDRReader) throws -> String {
        let name = try r.string()
        if name.isEmpty || name.contains("/") || name == "." || name == ".." { throw NFSError(.inval) }
        if name.utf8.count > 255 { throw NFSError(.nametoolong) }
        return name
    }

    private func forget(_ path: String) {
        lock.lock()
        var dropped: WorkingFile?
        if let id = idByPath.removeValue(forKey: path) {
            pathByID[id] = nil
            dropped = working.removeValue(forKey: id)
        }
        createVerifiers[path] = nil
        pendingNew[path] = nil
        lock.unlock()
        if let dropped {
            try? FileManager.default.removeItem(at: dropped.url)
            try? FileManager.default.removeItem(at: dropped.journal)
        }
    }

    private func renamePaths(from: String, to: String) {
        lock.lock()
        if let old = idByPath[to], old != idByPath[from] {
            idByPath[to] = nil
            pathByID[old] = nil
            if let wf = working.removeValue(forKey: old) {
                try? FileManager.default.removeItem(at: wf.url)
                try? FileManager.default.removeItem(at: wf.journal)
            }
        }
        pendingNew[to] = nil // whatever was pending at the destination has just been replaced
        var moved: [(WorkingFile, String)] = []
        for (path, id) in idByPath where path == from || path.hasPrefix(from + "/") {
            let newPath = to + path.dropFirst(from.count)
            idByPath[path] = nil
            idByPath[newPath] = id
            pathByID[id] = newPath
            if pendingNew[path] == id {
                pendingNew[path] = nil
                pendingNew[newPath] = id
            }
            if let wf = working[id], wf.dirty { moved.append((wf, newPath)) }
        }
        lock.unlock()
        for (wf, path) in moved { writeJournal(wf, path: path) }
    }

    // MARK: Attributes

    private func item(_ path: String) throws -> RemoteItem {
        if path == "/" { return RemoteItem(name: "/", isDirectory: true, modified: rootTime) }
        if let pending = pendingItem(path) { return pending }
        return try fs.stat(path)
    }

    private func pendingItem(_ path: String) -> RemoteItem? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = pendingNew[path], let wf = working[id] else { return nil }
        return RemoteItem(name: RemotePath.name(path), isDirectory: false, modified: wf.modified, mode: wf.pendingMode)
    }

    private func writeAttributes(_ w: inout XDRWriter, id: UInt64, item: RemoteItem) {
        var size = item.size
        var modified = item.modified
        lock.lock()
        let wf = working[id]
        lock.unlock()
        var pendingMode: UInt32?
        if let wf, let attrs = try? FileManager.default.attributesOfItem(atPath: wf.url.path) {
            size = (attrs[.size] as? NSNumber)?.uint64Value ?? size
            modified = wf.modified
            pendingMode = wf.pendingMode
        }
        let type: UInt32 = item.isSymlink ? 5 : item.isDirectory ? 2 : 1 // NF3LNK / NF3DIR / NF3REG
        var mode = pendingMode ?? item.mode ?? (item.isDirectory ? 0o755 : item.isSymlink ? 0o777 : 0o644)
        if fs.readOnly { mode &= ~0o222 }
        w.u32(type)
        w.u32(mode & 0o7777)
        w.u32(item.isDirectory ? 2 : 1)
        w.u32(uid)
        w.u32(gid)
        w.u64(size)
        w.u64((size + 4095) & ~4095)
        w.u32(0); w.u32(0) // rdev
        w.u64(fsid)
        w.u64(id)
        for _ in 0..<3 { writeTime(&w, modified) }
    }

    private func writeTime(_ w: inout XDRWriter, _ d: Date) {
        let t = max(0, d.timeIntervalSince1970)
        w.u32(UInt32(t))
        w.u32(UInt32((t - floor(t)) * 1_000_000_000))
    }

    private func postOpAttr(_ w: inout XDRWriter, id: UInt64, path: String) {
        if let it = try? item(path) {
            w.bool(true)
            writeAttributes(&w, id: id, item: it)
        } else {
            w.bool(false)
        }
    }

    /// wcc_data with no pre-operation attributes.
    private func wcc(_ w: inout XDRWriter, id: UInt64, path: String) {
        w.bool(false)
        postOpAttr(&w, id: id, path: path)
    }

    private func requireWritable() throws {
        if fs.readOnly { throw NFSError(.rofs) }
    }

    /// sattr3; returns the mode, size and mtime the client asked for.
    private func readSattr(_ r: inout XDRReader) throws
        -> (mode: UInt32?, size: UInt64?, mtime: Date?, mtimeFromClient: Bool)
    {
        let mode: UInt32? = try r.bool() ? try r.u32() : nil
        if try r.bool() { _ = try r.u32() } // uid
        if try r.bool() { _ = try r.u32() } // gid
        let size: UInt64? = try r.bool() ? try r.u64() : nil
        if try r.u32() == 2 { _ = try r.u32(); _ = try r.u32() } // atime
        var mtime: Date?
        var fromClient = false
        switch try r.u32() {
        case 1: mtime = Date()
        case 2:
            mtime = Date(timeIntervalSince1970: Double(try r.u32()) + Double(try r.u32()) / 1e9)
            fromClient = true
        default: break
        }
        return (mode, size, mtime, fromClient)
    }

    // MARK: Working copies

    private func workingFile(_ id: UInt64, _ path: String, empty: Bool = false) throws -> WorkingFile {
        lock.lock()
        if let wf = working[id] {
            lock.unlock()
            return wf
        }
        lock.unlock()
        let url = workDir.appendingPathComponent(UUID().uuidString)
        if empty {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        } else {
            try FileManager.default.copyItem(at: try fs.localCopy(path), to: url)
        }
        let wf = WorkingFile(url: url)
        lock.lock()
        defer { lock.unlock() }
        if let raced = working[id] {
            try? FileManager.default.removeItem(at: url)
            return raced
        }
        working[id] = wf
        return wf
    }

    private func markDirty(_ wf: WorkingFile, id: UInt64) {
        let wasDirty = wf.dirty
        wf.generation += 1
        wf.dirty = true
        wf.modified = Date()
        if !wasDirty {
            lock.lock()
            let path = pathByID[id]
            lock.unlock()
            if let path { writeJournal(wf, path: path) }
        }
    }

    private func writeJournal(_ wf: WorkingFile, path: String) {
        if let data = try? JSONSerialization.data(withJSONObject: ["path": path]) {
            try? data.write(to: wf.journal, options: .atomic)
        }
    }

    /// Uploads a dirty working file, to `target` instead of its current path when given (a rename
    /// of a file the server has never seen). Writes that land during the upload keep it dirty.
    private func flush(_ id: UInt64, as target: String? = nil) throws {
        lock.lock()
        let wf = working[id]
        let path = target ?? pathByID[id]
        lock.unlock()
        guard let wf, let path else { return }
        wf.uploadLock.lock()
        defer { wf.uploadLock.unlock() }
        guard wf.dirty else { return }

        wf.lock.lock()
        let generation = wf.generation
        let snapshot = workDir.appendingPathComponent("upload-\(UUID().uuidString)")
        let copied = (try? FileManager.default.copyItem(at: wf.url, to: snapshot)) != nil
        wf.lock.unlock()
        guard copied else { throw NFSError(.io) }

        wf.lock.lock()
        let mode = wf.pendingMode, mtime = wf.pendingMtime
        wf.uploading = true
        wf.lock.unlock()
        do {
            try fs.write(path, from: snapshot, mode: mode, modified: mtime)
        } catch {
            try? FileManager.default.removeItem(at: snapshot)
            wf.lock.lock()
            wf.uploading = false
            wf.failures += 1
            // 5 s, 10 s, 20 s ... capped at 5 minutes, so an unreachable server is not hammered.
            wf.retryAt = Date().addingTimeInterval(min(300, 5 * pow(2, Double(min(wf.failures, 7) - 1))))
            wf.lastError = error.localizedDescription
            wf.lock.unlock()
            log("upload of \(path) failed: \(error.localizedDescription)")
            throw error
        }
        lock.lock()
        pendingNew = pendingNew.filter { $0.value != id }
        lock.unlock()
        wf.lock.lock()
        defer { wf.lock.unlock() }
        wf.uploading = false
        wf.failures = 0
        wf.retryAt = .distantPast
        wf.lastError = nil
        guard wf.generation == generation else { return }
        wf.pendingMode = nil
        wf.pendingMtime = nil
        wf.dirty = false
        lock.lock()
        if working[id] === wf { working[id] = nil }
        lock.unlock()
        try? FileManager.default.removeItem(at: wf.url)
        try? FileManager.default.removeItem(at: wf.journal)
    }

    private func isDirty(_ id: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return working[id]?.dirty ?? false
    }

    private func housekeeping() {
        lock.lock()
        let now = Date()
        let idle = working.filter {
            $0.value.dirty && now.timeIntervalSince($0.value.modified) > 3 && now >= $0.value.retryAt
        }.map(\.key)
        // Replies nobody came back for (the client gave up) are dropped after two minutes.
        jobs = jobs.filter { !$0.value.finished || Date().timeIntervalSince($0.value.started) < 120 }
        lock.unlock()
        for id in idle {
            jobQueue.async { [weak self] in try? self?.flush(id) }
        }
    }

    /// Every file with changes not yet on the server, and how its upload is going.
    func pendingUploads() -> [String: UploadState] {
        lock.lock()
        let entries = working.compactMap { id, wf in pathByID[id].map { ($0, wf) } }
        lock.unlock()
        var result: [String: UploadState] = [:]
        for (path, wf) in entries {
            wf.lock.lock()
            if wf.dirty || wf.uploading {
                result[path] = wf.uploading ? .uploading : wf.lastError.map { .failed($0) } ?? .waiting
            }
            wf.lock.unlock()
        }
        return result
    }

    /// Ends the wait after failed uploads, so they go out on the next pass (the server is back).
    func retryFailedUploadsSoon() {
        lock.lock()
        let files = Array(working.values)
        lock.unlock()
        for wf in files {
            wf.lock.lock()
            wf.retryAt = .distantPast
            wf.lock.unlock()
        }
    }

    /// Uploads everything still pending; used before unmounting.
    func flushAll() {
        lock.lock()
        let ids = Array(working.keys)
        lock.unlock()
        for id in ids { try? flush(id) }
    }

    /// Uploads changes left behind by a session that ended before they were sent.
    /// Failed ones stay on disk for the next attempt.
    @discardableResult
    func recoverPendingUploads() -> (uploaded: [String], failed: [String]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: workDir.path) else { return ([], []) }
        var uploaded: [String] = [], failed: [String] = []
        for name in names where name.hasSuffix(".json") {
            let journal = workDir.appendingPathComponent(name)
            let data = workDir.appendingPathComponent(String(name.dropLast(5)))
            guard let raw = try? Data(contentsOf: journal),
                  let entry = try? JSONSerialization.jsonObject(with: raw) as? [String: String],
                  let path = entry["path"], fm.fileExists(atPath: data.path) else {
                try? fm.removeItem(at: journal)
                continue
            }
            let snapshot = workDir.appendingPathComponent("upload-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: data, to: snapshot)
                try fs.write(path, from: snapshot)
                try? fm.removeItem(at: data)
                try? fm.removeItem(at: journal)
                uploaded.append(path)
            } catch {
                try? fm.removeItem(at: snapshot)
                failed.append(path)
                log("could not upload saved change to \(path): \(error.localizedDescription)")
            }
        }
        // Data files without a journal were never dirty or were already uploaded.
        for name in (try? fm.contentsOfDirectory(atPath: workDir.path)) ?? []
        where !name.hasSuffix(".json") && !fm.fileExists(atPath: workDir.appendingPathComponent(name + ".json").path) {
            try? fm.removeItem(at: workDir.appendingPathComponent(name))
        }
        return (uploaded, failed)
    }

    // MARK: Procedures

    private func getattr(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (id, path) = try readHandle(&r)
        let it = try item(path)
        w.u32(0)
        writeAttributes(&w, id: id, item: it)
    }

    private func setattr(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (id, path) = try readHandle(&r)
        let attrs = try readSattr(&r)
        if try r.bool() { _ = try r.u32(); _ = try r.u32() } // guard ctime
        if attrs.mode != nil || attrs.size != nil || attrs.mtime != nil { try requireWritable() }
        if let newSize = attrs.size {
            let it = try item(path)
            if it.isDirectory { throw NFSError(.isdir) }
            let wf = try workingFile(id, path, empty: newSize == 0)
            wf.lock.lock()
            let ok = truncate(wf.url.path, off_t(newSize)) == 0
            markDirty(wf, id: id)
            wf.lock.unlock()
            if !ok { throw NFSError(.io) }
        }
        var mode = attrs.mode
        var mtime = attrs.mtime
        lock.lock()
        if let wf = working[id], wf.dirty {
            // Applied together with the upload; setting them now would cost a request and the
            // upload would reset the mtime anyway. "Set to server time" needs nothing at all.
            wf.lock.lock()
            if let m = mode { wf.pendingMode = m & 0o7777 }
            if let t = mtime, attrs.mtimeFromClient { wf.pendingMtime = t }
            wf.lock.unlock()
            mode = nil
            mtime = nil
        }
        lock.unlock()
        if mode != nil || mtime != nil {
            try fs.setAttributes(path, mode: mode, modified: mtime)
        }
        w.u32(0)
        wcc(&w, id: id, path: path)
    }

    private func lookup(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (dirID, dir) = try readHandle(&r)
        let name = try readName(&r)
        let path = RemotePath.join(dir, name)
        let it = try item(path)
        let id = id(for: path)
        w.u32(0)
        w.opaque(handle(id))
        w.bool(true)
        writeAttributes(&w, id: id, item: it)
        postOpAttr(&w, id: dirID, path: dir)
    }

    private func access(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (id, path) = try readHandle(&r)
        let requested = try r.u32()
        let it = try item(path)
        var allowed: UInt32 = 0x01 | 0x02 // READ, LOOKUP
        if !fs.readOnly { allowed |= 0x04 | 0x08 | 0x10 } // MODIFY, EXTEND, DELETE
        if it.isDirectory || (it.mode ?? 0) & 0o111 != 0 { allowed |= 0x20 } // EXECUTE / search
        w.u32(0)
        w.bool(true)
        writeAttributes(&w, id: id, item: it)
        w.u32(requested & allowed)
    }

    private func readlink(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (id, path) = try readHandle(&r)
        let target = try fs.readLink(path)
        w.u32(0)
        postOpAttr(&w, id: id, path: path)
        w.string(target)
    }

    private func read(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (id, path) = try readHandle(&r)
        let offset = try r.u64()
        let count = min(Int(try r.u32()), 1 << 20)
        let it = try item(path)
        if it.isDirectory { throw NFSError(.isdir) }
        lock.lock()
        let wf = working[id]
        lock.unlock()

        let data: Data
        let total: UInt64
        if let wf {
            wf.lock.lock()
            total = ((try? FileManager.default.attributesOfItem(atPath: wf.url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
            data = offset < total ? try CachedFileSystem.pread(wf.url, offset: offset, length: count) : Data()
            wf.lock.unlock()
        } else {
            total = it.size
            data = offset < total ? try fs.read(path, offset: offset, length: count) : Data()
        }
        w.u32(0)
        w.bool(true)
        writeAttributes(&w, id: id, item: it)
        w.u32(UInt32(data.count))
        w.bool(offset + UInt64(data.count) >= total)
        w.opaque(data)
    }

    private func write(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (id, path) = try readHandle(&r)
        let offset = try r.u64()
        _ = try r.u32() // count
        _ = try r.u32() // stable_how
        let data = try r.opaque()
        try requireWritable()
        let wf = try workingFile(id, path)
        wf.lock.lock()
        defer { wf.lock.unlock() }
        guard let fh = try? FileHandle(forWritingTo: wf.url) else { throw NFSError(.io) }
        try fh.seek(toOffset: offset)
        try fh.write(contentsOf: data)
        try fh.close()
        markDirty(wf, id: id)
        w.u32(0)
        w.bool(false)
        w.bool(false) // post-op attrs omitted; the kernel asks with GETATTR when it needs them
        w.u32(UInt32(data.count))
        w.u32(0) // UNSTABLE: data is safe only after COMMIT, which triggers the upload
        w.fixed(writeVerifier)
    }

    private func create(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (dirID, dir) = try readHandle(&r)
        let name = try readName(&r)
        let how = try r.u32() // 0 UNCHECKED, 1 GUARDED (both carry sattr3), 2 EXCLUSIVE (verifier)
        var attrs: (mode: UInt32?, size: UInt64?, mtime: Date?, mtimeFromClient: Bool) = (nil, nil, nil, false)
        var verifier: Data?
        if how == 2 { verifier = try r.fixed(8) } else { attrs = try readSattr(&r) }
        try requireWritable()
        let path = RemotePath.join(dir, name)
        let exists = (try? item(path)) != nil

        if exists {
            switch how {
            case 1:
                throw NFSError(.exist)
            case 2:
                // Lock files (git's index.lock) rely on this: only a retry of the same create succeeds.
                lock.lock()
                let mine = createVerifiers[path] == verifier
                lock.unlock()
                if !mine { throw NFSError(.exist) }
            default:
                if attrs.size == 0 {
                    let id = id(for: path)
                    let wf = try workingFile(id, path, empty: true)
                    wf.lock.lock()
                    _ = truncate(wf.url.path, 0)
                    markDirty(wf, id: id)
                    wf.lock.unlock()
                }
            }
        } else {
            // Local until the first upload (COMMIT, idle flush, or a rename to its final name).
            let newID = id(for: path)
            let wf = try workingFile(newID, path, empty: true)
            wf.lock.lock()
            if let mode = attrs.mode, mode & 0o7777 != 0o644 { wf.pendingMode = mode & 0o7777 }
            markDirty(wf, id: newID)
            wf.lock.unlock()
            lock.lock()
            pendingNew[path] = newID
            if let verifier { createVerifiers[path] = verifier }
            lock.unlock()
        }
        let id = id(for: path)
        w.u32(0)
        w.bool(true)
        w.opaque(handle(id))
        postOpAttr(&w, id: id, path: path)
        wcc(&w, id: dirID, path: dir)
    }

    private func mkdir(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (dirID, dir) = try readHandle(&r)
        let name = try readName(&r)
        let attrs = try readSattr(&r)
        try requireWritable()
        let path = RemotePath.join(dir, name)
        if (try? item(path)) != nil { throw NFSError(.exist) }
        try fs.makeDirectory(path)
        if let mode = attrs.mode, mode & 0o7777 != 0o755 { try? fs.setAttributes(path, mode: mode, modified: nil) }
        let id = id(for: path)
        w.u32(0)
        w.bool(true)
        w.opaque(handle(id))
        postOpAttr(&w, id: id, path: path)
        wcc(&w, id: dirID, path: dir)
    }

    private func symlink(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (dirID, dir) = try readHandle(&r)
        let name = try readName(&r)
        _ = try readSattr(&r)
        let target = try r.string()
        try requireWritable()
        let path = RemotePath.join(dir, name)
        if (try? item(path)) != nil { throw NFSError(.exist) }
        try fs.makeSymlink(path, target: target)
        let id = id(for: path)
        w.u32(0)
        w.bool(true)
        w.opaque(handle(id))
        postOpAttr(&w, id: id, path: path)
        wcc(&w, id: dirID, path: dir)
    }

    private func remove(_ r: inout XDRReader, _ w: inout XDRWriter, directory: Bool) throws {
        let (dirID, dir) = try readHandle(&r)
        let name = try readName(&r)
        try requireWritable()
        let path = RemotePath.join(dir, name)
        lock.lock()
        let neverUploaded = pendingNew[path] != nil
        lock.unlock()
        if neverUploaded && !directory {
            forget(path)
            w.u32(0)
            wcc(&w, id: dirID, path: dir)
            return
        }
        let it = try item(path)
        if directory {
            guard it.isDirectory, !it.isSymlink else { throw NFSError(.notdir) }
            if !(try fs.list(path)).isEmpty { throw NFSError(.notempty) }
        } else if it.isDirectory && !it.isSymlink {
            throw NFSError(.isdir)
        }
        try fs.remove(path)
        forget(path)
        w.u32(0)
        wcc(&w, id: dirID, path: dir)
    }

    private func rename(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (fromID, fromDir) = try readHandle(&r)
        let fromName = try readName(&r)
        let (toID, toDir) = try readHandle(&r)
        let toName = try readName(&r)
        try requireWritable()
        let from = RemotePath.join(fromDir, fromName), to = RemotePath.join(toDir, toName)
        let source = try item(from)
        if let target = try? item(to) {
            if target.isDirectory != source.isDirectory { throw NFSError(target.isDirectory ? .isdir : .notdir) }
            if target.isDirectory, !(try fs.list(to)).isEmpty { throw NFSError(.notempty) }
        }
        let movingID = id(for: from)
        lock.lock()
        let neverUploaded = pendingNew[from] != nil
        lock.unlock()
        if neverUploaded {
            // The server has never seen the source: upload it under its final name instead.
            try flush(movingID, as: to)
        } else {
            // Pending writes must reach the old name before the backend moves it.
            try flush(movingID)
            try fs.move(from, to: to)
        }
        renamePaths(from: from, to: to)
        w.u32(0)
        wcc(&w, id: fromID, path: fromDir)
        wcc(&w, id: toID, path: toDir)
    }

    private func readdir(_ r: inout XDRReader, _ w: inout XDRWriter, plus: Bool) throws {
        let (dirID, dir) = try readHandle(&r)
        let cookie = try r.u64()
        _ = try r.fixed(8) // cookie verifier: listings are re-read, cookies are positions
        if plus { _ = try r.u32() } // dircount
        let maxBytes = Int(try r.u32())
        let it = try item(dir)
        guard it.isDirectory else { throw NFSError(.notdir) }

        var entries: [(String, UInt64, RemoteItem?)] = [(".", dirID, it), ("..", id(for: RemotePath.parent(dir)), nil)]
        var children = try fs.list(dir)
        lock.lock()
        let pendingHere = pendingNew.keys.filter { RemotePath.parent($0) == dir }
        lock.unlock()
        for p in pendingHere where !children.contains(where: { $0.name == RemotePath.name(p) }) {
            if let it = pendingItem(p) { children.append(it) }
        }
        for child in children.sorted(by: { $0.name < $1.name }) {
            entries.append((child.name, id(for: RemotePath.join(dir, child.name)), child))
        }

        w.u32(0)
        w.bool(true)
        writeAttributes(&w, id: dirID, item: it)
        w.fixed(Data(count: 8))
        var eof = true
        let budget = max(512, maxBytes - 128)
        for (index, entry) in entries.enumerated() where UInt64(index) >= cookie {
            var e = XDRWriter()
            e.bool(true)
            e.u64(entry.1)
            e.string(entry.0)
            e.u64(UInt64(index + 1))
            if plus {
                if let child = entry.2 {
                    e.bool(true)
                    writeAttributes(&e, id: entry.1, item: child)
                    e.bool(true)
                    e.opaque(handle(entry.1))
                } else {
                    e.bool(false)
                    e.bool(false)
                }
            }
            if w.data.count + e.data.count > budget {
                eof = false
                break
            }
            w.fixed(e.data)
        }
        w.bool(false)
        w.bool(eof)
    }

    private func fsstat(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (id, path) = try readHandle(&r)
        w.u32(0)
        postOpAttr(&w, id: id, path: path)
        // Cloud quotas differ per backend; report a large volume so Finder allows copies.
        let total: UInt64 = 1 << 40
        w.u64(total); w.u64(total / 2); w.u64(total / 2)
        w.u64(1 << 30); w.u64(1 << 29); w.u64(1 << 29)
        w.u32(0)
    }

    private func fsinfo(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (id, path) = try readHandle(&r)
        w.u32(0)
        postOpAttr(&w, id: id, path: path)
        let chunk: UInt32 = 1 << 20
        w.u32(chunk); w.u32(chunk); w.u32(4096) // rtmax, rtpref, rtmult
        w.u32(chunk); w.u32(chunk); w.u32(4096) // wtmax, wtpref, wtmult
        w.u32(64 * 1024) // dtpref
        w.u64(UInt64.max >> 1)
        w.u32(0); w.u32(1_000_000) // time_delta: 1 ms
        w.u32(0x02 | 0x08 | 0x10) // FSF3_SYMLINK | FSF3_HOMOGENEOUS | FSF3_CANSETTIME
    }

    private func pathconf(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (id, path) = try readHandle(&r)
        w.u32(0)
        postOpAttr(&w, id: id, path: path)
        w.u32(1)      // linkmax
        w.u32(255)    // name_max
        w.bool(true)  // no_trunc
        w.bool(true)  // chown_restricted
        w.bool(false) // case_insensitive
        w.bool(true)  // case_preserving
    }

    private func commit(_ r: inout XDRReader, _ w: inout XDRWriter) throws {
        let (id, path) = try readHandle(&r)
        try flush(id)
        w.u32(0)
        wcc(&w, id: id, path: path)
        w.fixed(writeVerifier)
    }
}
