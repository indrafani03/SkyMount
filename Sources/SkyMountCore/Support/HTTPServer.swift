import Foundation
import Network

public struct HTTPRequest {
    public var method: String
    public var target: String
    public var headers: [String: String]
    public var body: Data
    /// Set when the body was large enough to be spooled to disk (uploads).
    public var bodyFile: URL?

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Body as a file, writing in-memory bodies out when needed.
    public func bodyAsFile() throws -> URL {
        if let bodyFile { return bodyFile }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skymount-\(UUID().uuidString)")
        try body.write(to: url)
        return url
    }
}

public struct HTTPResponse {
    public enum Body {
        case none
        case data(Data)
        case file(URL, offset: UInt64, length: UInt64)
    }

    public var status: Int
    public var headers: [(String, String)]
    public var body: Body

    public init(status: Int, headers: [(String, String)] = [], body: Body = .none) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    var contentLength: UInt64 {
        switch body {
        case .none: return 0
        case .data(let d): return UInt64(d.count)
        case .file(_, _, let length): return length
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 207: return "Multi-Status"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 412: return "Precondition Failed"
        case 416: return "Range Not Satisfiable"
        case 423: return "Locked"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// Loopback-only HTTP/1.1 server. Requests are handled on a concurrent queue because every
/// handler may block on network I/O to the cloud backend.
public final class HTTPServer {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "skymount.http.listener")
    private let work = DispatchQueue(label: "skymount.http.work", attributes: .concurrent)
    public private(set) var port: UInt16 = 0

    public init(handler: @escaping Handler) { self.handler = handler }

    public func start(host: NWEndpoint.Host = .ipv4(.loopback)) throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: host, port: .any)
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
            HTTPConnection(conn, handler: self.handler, work: self.work).start()
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 10) == .timedOut { throw RemoteError.network("local server did not start") }
        if let failure { throw failure }
        port = listener.port?.rawValue ?? 0
        self.listener = listener
        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

private final class HTTPConnection {
    private enum State {
        case head
        case body(HTTPRequest, remaining: Int, BodySink)
        case chunked(HTTPRequest, BodySink, chunkRemaining: Int?)
        case handling
    }

    private static let debug = ProcessInfo.processInfo.environment["SKYMOUNT_DEBUG"] != nil
    private let conn: NWConnection
    private let handler: HTTPServer.Handler
    private let work: DispatchQueue
    private let q = DispatchQueue(label: "skymount.http.conn")
    private var buffer = Data()
    private var state = State.head
    private var reading = false
    private var me: HTTPConnection?

    init(_ conn: NWConnection, handler: @escaping HTTPServer.Handler, work: DispatchQueue) {
        self.conn = conn
        self.handler = handler
        self.work = work
    }

    func start() {
        me = self
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        conn.start(queue: q)
        readMore()
    }

    private func close() {
        conn.cancel()
        me = nil
    }

    private func readMore() {
        guard !reading else { return }
        reading = true
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.reading = false
            if let data { self.buffer.append(data) }
            if error != nil || (complete && (data?.isEmpty ?? true)) {
                self.close()
                return
            }
            self.process()
        }
    }

    private func process() {
        loop: while true {
            switch state {
            case .handling:
                return
            case .head:
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { break loop }
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                guard let req = Self.parseHead(head) else {
                    send(HTTPResponse(status: 400), keepAlive: false)
                    return
                }
                if Self.debug {
                    print("[http] \(req.method) \(req.target) cl=\(req.header("content-length") ?? "-") "
                          + "te=\(req.header("transfer-encoding") ?? "-") expect=\(req.header("expect") ?? "-")")
                }
                if req.header("transfer-encoding")?.lowercased().contains("chunked") == true {
                    state = .chunked(req, BodySink(), chunkRemaining: nil)
                } else if let len = Int(req.header("content-length") ?? "0"), len > 0 {
                    state = .body(req, remaining: len, BodySink())
                } else {
                    dispatch(req)
                    return
                }
            case .body(var req, let remaining, let sink):
                guard !buffer.isEmpty else { break loop }
                let n = min(remaining, buffer.count)
                sink.write(buffer.prefix(n))
                buffer.removeFirst(n)
                if remaining - n == 0 {
                    sink.finish(into: &req)
                    dispatch(req)
                    return
                }
                state = .body(req, remaining: remaining - n, sink)
            case .chunked(var req, let sink, let chunkRemaining):
                if let left = chunkRemaining {
                    // Need the chunk bytes plus the trailing CRLF.
                    if left > 0 {
                        guard !buffer.isEmpty else { break loop }
                        let n = min(left, buffer.count)
                        sink.write(buffer.prefix(n))
                        buffer.removeFirst(n)
                        state = .chunked(req, sink, chunkRemaining: left - n)
                        continue
                    }
                    guard buffer.count >= 2 else { break loop }
                    buffer.removeFirst(2)
                    state = .chunked(req, sink, chunkRemaining: nil)
                } else {
                    guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else { break loop }
                    let line = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
                    let size = Int(line.split(separator: ";").first.map(String.init) ?? "", radix: 16) ?? 0
                    if size == 0 {
                        // Skip optional trailers up to the blank line.
                        guard let trailerEnd = buffer.range(of: Data("\r\n".utf8)) else {
                            buffer.removeAll()
                            sink.finish(into: &req)
                            dispatch(req)
                            return
                        }
                        buffer.removeSubrange(buffer.startIndex..<trailerEnd.upperBound)
                        sink.finish(into: &req)
                        dispatch(req)
                        return
                    }
                    state = .chunked(req, sink, chunkRemaining: size)
                }
            }
        }
        readMore()
    }

    private static func parseHead(_ head: String) -> HTTPRequest? {
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPRequest(method: String(first[0]).uppercased(), target: String(first[1]),
                           headers: headers, body: Data(), bodyFile: nil)
    }

    private func dispatch(_ req: HTTPRequest) {
        state = .handling
        let keepAlive = req.header("connection")?.lowercased() != "close"
        work.async { [self] in
            var resp = handler(req)
            if req.method == "HEAD", case .file = resp.body {
                resp.headers.append(("Content-Length", String(resp.contentLength)))
                resp.body = .none
                q.async { self.send(resp, keepAlive: keepAlive, lengthAlreadySet: true) }
                return
            }
            if let file = req.bodyFile { try? FileManager.default.removeItem(at: file) }
            q.async { self.send(resp, keepAlive: keepAlive) }
        }
    }

    private func send(_ resp: HTTPResponse, keepAlive: Bool, lengthAlreadySet: Bool = false) {
        var head = "HTTP/1.1 \(resp.status) \(HTTPResponse.reason(resp.status))\r\n"
        for (k, v) in resp.headers { head += "\(k): \(v)\r\n" }
        if !lengthAlreadySet { head += "Content-Length: \(resp.contentLength)\r\n" }
        head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"

        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            if keepAlive {
                self.state = .head
                self.process()
            } else {
                self.close()
            }
        }

        switch resp.body {
        case .none:
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in finish() })
        case .data(let d):
            conn.send(content: Data(head.utf8) + d, completion: .contentProcessed { _ in finish() })
        case .file(let url, let offset, let length):
            conn.send(content: Data(head.utf8), completion: .idempotent)
            guard let fh = try? FileHandle(forReadingFrom: url) else { close(); return }
            try? fh.seek(toOffset: offset)
            sendFile(fh, remaining: length, done: finish)
        }
    }

    private func sendFile(_ fh: FileHandle, remaining: UInt64, done: @escaping () -> Void) {
        guard remaining > 0 else {
            try? fh.close()
            done()
            return
        }
        let chunk = (try? fh.read(upToCount: Int(min(remaining, 1 << 20)))) ?? Data()
        if chunk.isEmpty {
            try? fh.close()
            close()
            return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { try? fh.close(); self.close(); return }
            self.sendFile(fh, remaining: remaining - UInt64(chunk.count), done: done)
        })
    }
}

/// Collects a request body in memory, spilling to a temporary file past 1 MB.
private final class BodySink {
    private var data = Data()
    private var file: FileHandle?
    private var url: URL?

    func write(_ chunk: Data) {
        if file == nil, data.count + chunk.count > 1 << 20 {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("skymount-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: u.path, contents: data)
            file = try? FileHandle(forWritingTo: u)
            _ = try? file?.seekToEnd()
            url = u
            data = Data()
        }
        if let file { file.write(chunk) } else { data.append(chunk) }
    }

    func finish(into req: inout HTTPRequest) {
        if let file {
            try? file.close()
            req.bodyFile = url
        } else {
            req.body = data
        }
    }
}
