using System.Net.Http.Headers;

namespace SkyMount.Core;

/// Blocking HTTP for backend code, which runs on file system threads that wait for the answer anyway.
/// Responses of any status are returned; only a failed connection throws (as a network error).
public static class Http
{
    static readonly HttpClient client = new(new SocketsHttpHandler
    {
        MaxConnectionsPerServer = 6,
        ConnectTimeout = TimeSpan.FromSeconds(20),
        PooledConnectionLifetime = TimeSpan.FromMinutes(10),
    }) { Timeout = Timeout.InfiniteTimeSpan };

    static readonly TimeSpan Idle = TimeSpan.FromSeconds(60);

    public static (byte[] Body, HttpResponseMessage Response) Send(HttpRequestMessage req)
    {
        using var cts = new CancellationTokenSource(Idle);
        return Wrap(() =>
        {
            var resp = client.Send(req, HttpCompletionOption.ResponseContentRead, cts.Token);
            return (resp.Content.ReadAsByteArrayAsync(cts.Token).GetAwaiter().GetResult(), resp);
        });
    }

    /// Sends a file as the body.
    public static (byte[] Body, HttpResponseMessage Response) Upload(HttpRequestMessage req, string file, string? contentType)
    {
        using var stream = File.OpenRead(file);
        req.Content = new StreamContent(stream);
        if (contentType != null) req.Content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        // ponytail: whole-transfer limit scaled to the size (at least 64 KB/s), not an idle timeout;
        // a stalled upload waits it out. Add a progress watchdog if that shows up.
        using var cts = new CancellationTokenSource(Idle + TimeSpan.FromSeconds(stream.Length / 65536.0));
        return Wrap(() =>
        {
            var resp = client.Send(req, HttpCompletionOption.ResponseContentRead, cts.Token);
            return (resp.Content.ReadAsByteArrayAsync(cts.Token).GetAwaiter().GetResult(), resp);
        });
    }

    /// Streams a 2xx body to `dest`; other bodies are returned as data. Fails when the server sends
    /// nothing for a minute.
    public static (byte[] Body, HttpResponseMessage Response) Download(HttpRequestMessage req, string dest)
    {
        using var cts = new CancellationTokenSource(Idle);
        return Wrap(() =>
        {
            var resp = client.Send(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            if (!resp.IsSuccessStatusCode) return (resp.Content.ReadAsByteArrayAsync(cts.Token).GetAwaiter().GetResult(), resp);
            using var src = resp.Content.ReadAsStream(cts.Token);
            using var dst = File.Create(dest);
            var buf = new byte[256 * 1024];
            while (true)
            {
                cts.CancelAfter(Idle);
                var n = src.ReadAsync(buf, cts.Token).AsTask().GetAwaiter().GetResult();
                if (n == 0) return ([], resp);
                dst.Write(buf, 0, n);
            }
        });
    }

    static T Wrap<T>(Func<T> body)
    {
        try { return body(); }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or IOException)
        {
            throw RemoteException.Network(e is OperationCanceledException ? "the server stopped answering" : e.Message);
        }
    }
}
