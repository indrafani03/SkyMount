using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace SkyMount.Core;

/// Google Drive v3. Drive addresses files by ID and allows duplicate names in one folder, so paths
/// are resolved through listings and cached; when names collide the oldest item wins.
/// Google Docs, Sheets and Slides have no downloadable bytes and are left out of listings.
public sealed class GoogleDriveBackend(GoogleOAuth.Client client, string refreshToken) : IRemoteFileSystem
{
    readonly GoogleOAuth oauth = new(client);
    readonly object gate = new(), tokenLock = new();
    readonly Dictionary<string, string> ids = new() { ["/"] = "root" };
    string? accessToken;
    DateTime expiry = DateTime.MinValue;

    const string Api = "https://www.googleapis.com/drive/v3";
    const string UploadApi = "https://www.googleapis.com/upload/drive/v3";
    const string FolderType = "application/vnd.google-apps.folder";

    public void Connect() => Token(forceRefresh: true);
    public void Disconnect() { }

    // HTTP

    string Token(bool forceRefresh = false)
    {
        lock (tokenLock)
        {
            if (!forceRefresh && accessToken != null && DateTime.UtcNow < expiry) return accessToken;
            (accessToken, expiry) = oauth.Refresh(refreshToken);
            return accessToken;
        }
    }

    /// Authenticated call with one token refresh on 401 and backoff on rate limits and server errors.
    (byte[] Body, HttpResponseMessage Response) Call(string method, string url, string path,
        Dictionary<string, string>? query = null, JsonObject? json = null, string? downloadTo = null,
        Dictionary<string, string>? headers = null)
    {
        var q = new Dictionary<string, string>(query ?? []) { ["supportsAllDrives"] = "true" };
        var full = url + "?" + GoogleOAuth.Form(q);
        var refreshed = false;
        for (var attempt = 0; attempt < 5; attempt++)
        {
            var req = new HttpRequestMessage(new HttpMethod(method), full);
            req.Headers.Authorization = new("Bearer", Token());
            foreach (var (k, v) in headers ?? []) req.Headers.TryAddWithoutValidation(k, v);
            if (json != null) req.Content = new StringContent(json.ToJsonString(), Encoding.UTF8, "application/json");
            var (body, resp) = downloadTo != null ? Http.Download(req, downloadTo) : Http.Send(req);
            switch ((int)resp.StatusCode)
            {
                case >= 200 and < 300:
                    return (body, resp);
                case 401 when !refreshed:
                    refreshed = true;
                    Token(forceRefresh: true);
                    continue;
                case 429 or 500 or 502 or 503 or 504:
                    Thread.Sleep(Backoff(attempt));
                    continue;
                case 403 when Reason(body).Contains("RateLimit"):
                    Thread.Sleep(Backoff(attempt));
                    continue;
                case 416:
                    return ([], resp); // range past the end of the file
                case 404:
                    throw RemoteException.NotFound(path);
                case 403:
                    throw RemoteException.PermissionDenied(path);
                default:
                    throw RemoteException.Protocol($"Drive {(int)resp.StatusCode}: {Message(body)}");
            }
        }
        throw RemoteException.Network("Google Drive kept rejecting requests (rate limited)");
    }

    static TimeSpan Backoff(int attempt) => TimeSpan.FromSeconds(Math.Pow(2, attempt) * 0.5);

    static string Message(byte[] body) =>
        (string?)GoogleOAuth.Json(body)["error"]?["message"] ?? Encoding.UTF8.GetString(body, 0, Math.Min(200, body.Length));

    static string Reason(byte[] body) =>
        string.Join(',', (GoogleOAuth.Json(body)["error"]?["errors"] as JsonArray ?? new JsonArray()).Select(e => (string?)e?["reason"]));

    // Path to ID

    void Remember(string path, string? id)
    {
        lock (gate)
        {
            if (id == null) ids.Remove(RemotePath.Normalize(path));
            else ids[RemotePath.Normalize(path)] = id;
        }
    }

    void Forget(string path)
    {
        var p = RemotePath.Normalize(path);
        lock (gate)
            foreach (var key in ids.Keys.Where(k => k == p || RemotePath.IsInside(k, p)).ToList())
                ids.Remove(key);
    }

    string Resolve(string path)
    {
        var p = RemotePath.Normalize(path);
        lock (gate) if (ids.TryGetValue(p, out var id)) return id;
        List(RemotePath.Parent(p));
        lock (gate) return ids.TryGetValue(p, out var found) ? found : throw RemoteException.NotFound(p);
    }

    string? TryResolve(string path)
    {
        try { return Resolve(path); }
        catch (RemoteException e) when (e.Kind == RemoteErrorKind.NotFound) { return null; }
    }

    // Listing

    public List<RemoteItem> List(string path)
    {
        var p = RemotePath.Normalize(path);
        var folderId = Resolve(p);
        var items = new Dictionary<string, RemoteItem>();
        string? pageToken = null;
        do
        {
            var q = new Dictionary<string, string>
            {
                ["q"] = $"'{folderId}' in parents and trashed = false",
                ["fields"] = "nextPageToken,files(id,name,mimeType,size,modifiedTime)",
                ["pageSize"] = "1000",
                ["orderBy"] = "createdTime",
                ["includeItemsFromAllDrives"] = "true",
            };
            if (pageToken != null) q["pageToken"] = pageToken;
            var json = GoogleOAuth.Json(Call("GET", $"{Api}/files", p, q).Body);
            foreach (var node in json["files"] as JsonArray ?? new JsonArray())
            {
                if (node is not JsonObject f || (string?)f["id"] is not { } id || (string?)f["name"] is not { } name
                    || (string?)f["mimeType"] is not { } mime || name.Contains('/')) continue;
                var isDir = mime == FolderType;
                if (!isDir && mime.StartsWith("application/vnd.google-apps.")) continue;
                if (items.ContainsKey(name)) continue;
                var modified = DateTime.TryParse((string?)f["modifiedTime"], CultureInfo.InvariantCulture,
                    DateTimeStyles.AdjustToUniversal, out var m) ? m : DateTime.UtcNow;
                items[name] = new RemoteItem(name, isDir, ulong.TryParse((string?)f["size"], out var size) ? size : 0, modified, id);
            }
            pageToken = (string?)json["nextPageToken"];
        } while (pageToken != null);

        lock (gate) foreach (var item in items.Values) ids[RemotePath.Join(p, item.Name)] = item.Id!;
        return [.. items.Values];
    }

    public RemoteItem Stat(string path) => this.StatViaParent(path);

    // Content

    public void Download(string path, string localFile) =>
        Call("GET", $"{Api}/files/{Resolve(path)}", path, new() { ["alt"] = "media" }, downloadTo: localFile);

    public bool SupportsRangeReads => true;

    public byte[] Read(string path, ulong offset, int length)
    {
        if (length <= 0) return [];
        var body = Call("GET", $"{Api}/files/{Resolve(path)}", path, new() { ["alt"] = "media" },
            headers: new() { ["Range"] = $"bytes={offset}-{offset + (ulong)length - 1}" }).Body;
        return body.Length > length ? body[..length] : body;
    }

    public void Upload(string localFile, string path)
    {
        var p = RemotePath.Normalize(path);
        var headers = new Dictionary<string, string> { ["X-Upload-Content-Length"] = new FileInfo(localFile).Length.ToString(CultureInfo.InvariantCulture) };
        var resumable = new Dictionary<string, string> { ["uploadType"] = "resumable" };
        // Resumable upload: one call opens the session, the PUT sends the bytes.
        var start = TryResolve(p) is { } existing
            ? Call("PATCH", $"{UploadApi}/files/{existing}", p, resumable, new JsonObject(), headers: headers)
            : Call("POST", $"{UploadApi}/files", p, resumable,
                new JsonObject { ["name"] = RemotePath.Name(p), ["parents"] = new JsonArray(Resolve(RemotePath.Parent(p))) }, headers: headers);
        var session = start.Response.Headers.Location ?? throw RemoteException.Protocol("Drive did not open an upload session");
        var (body, resp) = Http.Upload(new HttpRequestMessage(HttpMethod.Put, session), localFile, null);
        if (!resp.IsSuccessStatusCode) throw RemoteException.Protocol($"Drive upload failed ({(int)resp.StatusCode}): {Message(body)}");
        if ((string?)GoogleOAuth.Json(body)["id"] is { } id) Remember(p, id);
    }

    // Namespace

    public void MakeDirectory(string path)
    {
        var p = RemotePath.Normalize(path);
        if (TryResolve(p) != null) throw RemoteException.AlreadyExists(p);
        var parent = Resolve(RemotePath.Parent(p));
        var body = Call("POST", $"{Api}/files", p, new() { ["fields"] = "id" },
            new JsonObject { ["name"] = RemotePath.Name(p), ["mimeType"] = FolderType, ["parents"] = new JsonArray(parent) }).Body;
        Remember(p, (string?)GoogleOAuth.Json(body)["id"]);
    }

    /// Moves the item to the Drive trash (recoverable for 30 days) instead of deleting it.
    void Trash(string path)
    {
        Call("PATCH", $"{Api}/files/{Resolve(path)}", path, new() { ["fields"] = "id" }, new JsonObject { ["trashed"] = true });
        Forget(path);
    }

    public void RemoveFile(string path) => Trash(path);
    public void RemoveDirectory(string path) => Trash(path);

    public void Move(string from, string to)
    {
        var src = RemotePath.Normalize(from);
        var dst = RemotePath.Normalize(to);
        var id = Resolve(src);
        // Drive happily keeps two items with one name; replace the destination like a file system would.
        if (TryResolve(dst) is { } existing && existing != id) Trash(dst);
        var query = new Dictionary<string, string> { ["fields"] = "id" };
        var oldParent = Resolve(RemotePath.Parent(src));
        var newParent = Resolve(RemotePath.Parent(dst));
        if (oldParent != newParent)
        {
            query["addParents"] = newParent;
            query["removeParents"] = oldParent;
        }
        Call("PATCH", $"{Api}/files/{id}", src, query, new JsonObject { ["name"] = RemotePath.Name(dst) });
        Forget(src);
        Remember(dst, id);
    }
}
