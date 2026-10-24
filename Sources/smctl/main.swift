import Foundation
import SkyMountCore

// Developer tool: mount a backend without the menu bar app.
//   smctl local <folder> <volume-name>
//   smctl sftp <host> <port> <user> <private-key> <remote-root> <volume-name>
//   smctl selftest
//   smctl offlinetest

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let usage = """
    usage: smctl local <folder> <volume-name>
           smctl sftp <host> <port> <user> <private-key> <remote-root> <volume-name>
           smctl ftp <host> <port> <user> <password> <remote-root> <volume-name> tls|plain
           smctl s3 <endpoint> <region> <bucket> <access-key> <secret> path|virtual <prefix> <volume-name>
           smctl selftest
           smctl offlinetest
    """

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
if args.count == 2, args[1] == "selftest" {
    let ok = S3Backend.signatureSelfTest()
    print("S3 SigV4 (AWS documented example): \(ok ? "PASS" : "FAIL")")
    exit(ok ? 0 : 1)
}
if args.count == 2, args[1] == "offlinetest" {
    exit(offlineTest() ? 0 : 1)
}

let backend: RemoteFileSystem
let volumeName: String
switch args.count > 1 ? args[1] : "" {
case "local" where args.count == 4:
    backend = LocalFolderBackend(root: URL(fileURLWithPath: args[2]))
    volumeName = args[3]
case "sftp" where args.count == 8:
    backend = SFTPBackend(settings: SFTPSettings(
        host: args[2], port: Int(args[3]) ?? 22, username: args[4], remoteRoot: args[6], password: nil,
        privateKeyPath: args[5], keyPassphrase: nil, knownFingerprint: nil),
        onNewFingerprint: { print("host key: \($0)") })
    volumeName = args[7]
case "ftp" where args.count == 9:
    backend = FTPBackend(settings: FTPSettings(host: args[2], port: Int(args[3]) ?? 21, username: args[4],
                                               password: args[5], remoteRoot: args[6], useTLS: args[8] == "tls"))
    volumeName = args[7]
case "s3" where args.count == 10:
    guard let endpoint = URL(string: args[2]) else { fail("invalid endpoint") }
    backend = S3Backend(settings: S3Settings(endpoint: endpoint, region: args[3], bucket: args[4], accessKey: args[5],
                                             secretKey: args[6], pathStyle: args[7] == "path", prefix: args[8]))
    volumeName = args[9]
default:
    fail(usage)
}

// Pending writes are keyed by volume name so a killed smctl recovers them on the next run.
let tmp = FileManager.default.temporaryDirectory
let volume = VolumeMount(volumeName: volumeName, backend: backend,
                         cacheRoot: tmp.appendingPathComponent("smctl-cache-\(getpid())"),
                         pendingDir: tmp.appendingPathComponent("smctl-pending-\(volumeName)"),
                         listingTTL: Double(ProcessInfo.processInfo.environment["SKYMOUNT_TTL"] ?? "") ?? 15)

let started = Date()
DispatchQueue.global().async {
    do {
        let point = try volume.mount(log: { print("[nfs] \($0)") })
        print(String(format: "mounted at %@ after %.1f s", point, Date().timeIntervalSince(started)))
    } catch {
        fail("mount failed: \(error.localizedDescription)")
    }
}

signal(SIGINT, SIG_IGN)
let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sig.setEventHandler {
    volume.unmount()
    print("unmounted")
    exit(0)
}
sig.resume()

if Stats.enabled {
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
        let table = Stats.shared.drain()
        if !table.isEmpty { print("---- last 10 s\n\(table)") }
    }
}

// Exit on its own when the volume is ejected from Finder.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    if volume.mountPoint != nil, !volume.isMounted {
        volume.unmount()
        print("volume ejected")
        exit(0)
    }
}
RunLoop.main.run()
