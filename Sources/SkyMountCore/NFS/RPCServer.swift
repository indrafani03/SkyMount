import Foundation
import Network

struct RPCCall {
    var xid: UInt32
    var program: UInt32
    var version: UInt32
    var procedure: UInt32
    /// AUTH_SYS uid, when the caller sent AUTH_SYS credentials.
    var uid: UInt32?
    var args: XDRReader
    /// Source port of the caller; below 1024 means a privileged sender such as the kernel NFS client.
    var peerPort: UInt16
}

enum RPCResult {
    case success(XDRWriter)
    case programUnavailable
    case programMismatch(low: UInt32, high: UInt32)
    case procedureUnavailable
    case garbageArguments
    case authError
}

/// ONC RPC v2 over TCP (RFC 5531) on the loopback interface. Calls on one connection run
/// concurrently and replies go out as they finish, matched by XID.
final class RPCServer {
    typealias Handler = (inout RPCCall) -> RPCResult

    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "skymount.rpc.listener")
    let work = DispatchQueue(label: "skymount.rpc.work", attributes: .concurrent)

    init(handler: @escaping Handler) { self.handler = handler }

    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            RPCConnection(conn, handler: self.handler, work: self.work).start()
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 10) == .timedOut { throw RemoteError.network("local NFS server did not start") }
        if let failure { throw failure }
        self.listener = listener
        return listener.port?.rawValue ?? 0
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

private final class RPCConnection {
    private let conn: NWConnection
    private let handler: RPCServer.Handler
    private let work: DispatchQueue
    private let q = DispatchQueue(label: "skymount.rpc.conn")
    private var buffer = Data()
    private var record = Data()
    private var peerPort: UInt16 = 0
    private var me: RPCConnection?

    init(_ conn: NWConnection, handler: @escaping RPCServer.Handler, work: DispatchQueue) {
        self.conn = conn
        self.handler = handler
        self.work = work
        if case .hostPort(_, let port) = conn.endpoint { peerPort = port.rawValue }
    }

    func start() {
        me = self
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.me = nil
            default: break
            }
        }
        conn.start(queue: q)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.drain()
            if error != nil || complete {
                self.conn.cancel()
                return
            }
            self.receive()
        }
    }

    /// Splits the byte stream into record-marked fragments and dispatches complete records.
    private func drain() {
        while buffer.count >= 4 {
            let header = buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let length = Int(header & 0x7fff_ffff)
            guard buffer.count >= 4 + length else { return }
            record.append(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)
            if header & 0x8000_0000 != 0 {
                let rec = record
                record = Data()
                work.async { [weak self] in self?.handle(rec) }
            }
        }
    }

    private func handle(_ rec: Data) {
        var r = XDRReader(rec)
        guard let xid = try? r.u32(), (try? r.u32()) == 0 /* CALL */ else { return }
        var reply = XDRWriter(capacity: 512)
        reply.u32(xid)
        reply.u32(1) // REPLY

        guard (try? r.u32()) == 2, let prog = try? r.u32(), let vers = try? r.u32(), let proc = try? r.u32(),
              let credFlavor = try? r.u32(), let credBody = try? r.opaque(max: 400),
              (try? r.u32()) != nil, (try? r.opaque(max: 400)) != nil
        else {
            reply.u32(1) // MSG_DENIED
            reply.u32(0) // RPC_MISMATCH
            reply.u32(2); reply.u32(2)
            send(reply.data)
            return
        }

        var uid: UInt32?
        if credFlavor == 1 { // AUTH_SYS: stamp, machinename, uid, gid, gids
            var c = XDRReader(credBody)
            _ = try? c.u32()
            _ = try? c.string()
            uid = try? c.u32()
        }

        var call = RPCCall(xid: xid, program: prog, version: vers, procedure: proc, uid: uid, args: r, peerPort: peerPort)
        let result = handler(&call)

        if case .authError = result {
            reply.u32(1) // MSG_DENIED
            reply.u32(1) // AUTH_ERROR
            reply.u32(5) // AUTH_TOOWEAK
            send(reply.data)
            return
        }
        reply.u32(0)  // MSG_ACCEPTED
        reply.u32(0); reply.u32(0) // verifier AUTH_NONE
        switch result {
        case .success(let body):
            reply.u32(0)
            var data = reply.data
            data.append(body.data)
            send(data)
            return
        case .programUnavailable: reply.u32(1)
        case .programMismatch(let low, let high): reply.u32(2); reply.u32(low); reply.u32(high)
        case .procedureUnavailable: reply.u32(3)
        case .garbageArguments: reply.u32(4)
        case .authError: break
        }
        send(reply.data)
    }

    private func send(_ payload: Data) {
        var framed = XDRWriter(capacity: payload.count + 4)
        framed.u32(0x8000_0000 | UInt32(payload.count))
        var data = framed.data
        data.append(payload)
        conn.send(content: data, completion: .idempotent)
    }
}
