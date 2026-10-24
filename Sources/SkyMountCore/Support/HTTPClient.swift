import Foundation

/// Blocking wrappers over URLSession for backend code that runs on WebDAV worker threads.
public enum HTTPClient {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 6 * 3600
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    public static func data(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        try wait { done in session.dataTask(with: req) { d, r, e in done(d, r, e) } }
    }

    public static func upload(_ req: URLRequest, fromFile file: URL) throws -> (Data, HTTPURLResponse) {
        try wait { done in session.uploadTask(with: req, fromFile: file) { d, r, e in done(d, r, e) } }
    }

    /// Streams the response body to `dest` (overwriting it). Non-2xx bodies are returned as data instead.
    public static func download(_ req: URLRequest, to dest: URL) throws -> (Data, HTTPURLResponse) {
        var moveError: Error?
        let (data, resp) = try wait { done in
            session.downloadTask(with: req) { tmp, r, e in
                var body = Data()
                if let tmp, let http = r as? HTTPURLResponse {
                    if (200..<300).contains(http.statusCode) {
                        try? FileManager.default.removeItem(at: dest)
                        do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { moveError = error }
                    } else {
                        body = (try? Data(contentsOf: tmp)) ?? Data()
                    }
                }
                done(body, r, e)
            }
        }
        if let moveError { throw moveError }
        return (data, resp)
    }

    private static func wait(_ start: (@escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionTask) throws
        -> (Data, HTTPURLResponse)
    {
        let sem = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?)
        let task = start { d, r, e in
            result = (d, r, e)
            sem.signal()
        }
        task.resume()
        sem.wait()
        if let e = result.2 { throw RemoteError.network(e.localizedDescription) }
        guard let http = result.1 as? HTTPURLResponse else { throw RemoteError.network("no HTTP response") }
        return (result.0 ?? Data(), http)
    }
}
