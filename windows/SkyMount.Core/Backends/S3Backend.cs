using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;

namespace SkyMount.Core;

/// `Endpoint` is https://s3.amazonaws.com, https://s3.us-west-004.backblazeb2.com, a MinIO URL...
/// `PathStyle` is needed for MinIO and most S3-compatible services. `Prefix` is the folder in the
/// bucket used as the mount root.
public sealed record S3Settings(Uri Endpoint, string Region, string Bucket, string AccessKey, string SecretKey, bool PathStyle, string Prefix);

/// Amazon S3 and S3-compatible storage, signed with AWS Signature Version 4.
/// Folders are emulated with "/" delimiters and zero-byte "name/" marker objects.
public sealed class S3Backend(S3Settings s) : IRemoteFileSystem
{
    public void Connect() => List("/");
    public void Disconnect() { }

    // Keys

    string Key(string path) => RemotePath.Under(s.Prefix, path)[1..];

    string DirPrefix(string path)
    {
        var k = Key(path);
        return k.Length == 0 ? "" : k + "/";
    }

    // Requests

    const string EmptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    HttpRequestMessage Request(string method, string key, Dictionary<string, string>? query = null,
        Dictionary<string, string>? headers = null, string payloadHash = EmptyHash, DateTime? now = null)
    {
        var host = s.Endpoint.Host;
        string path;
        if (s.PathStyle) path = "/" + Encode(s.Bucket, keepSlash: false) + "/" + Encode(key, keepSlash: true);
        else
        {
            host = $"{s.Bucket}.{host}";
            path = "/" + Encode(key, keepSlash: true);
        }
        if (path.EndsWith("//")) path = path[..^1];
        var canonicalQuery = string.Join('&', (query ?? []).OrderBy(q => q.Key, StringComparer.Ordinal)
            .Select(q => $"{Encode(q.Key, false)}={Encode(q.Value, false)}"));
        if (!s.Endpoint.IsDefaultPort) host += ":" + s.Endpoint.Port;

        var time = now ?? DateTime.UtcNow;
        var amzDate = time.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var day = time.ToString("yyyyMMdd", CultureInfo.InvariantCulture);
        var signed = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var (name, value) in headers ?? []) signed[name.ToLowerInvariant()] = value.Trim();
        signed["host"] = host;
        signed["x-amz-date"] = amzDate;
        signed["x-amz-content-sha256"] = payloadHash;

        var canonicalHeaders = string.Concat(signed.Select(h => $"{h.Key}:{h.Value}\n"));
        var signedHeaders = string.Join(';', signed.Keys);
        var canonicalRequest = string.Join('\n', method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash);
        var scope = $"{day}/{s.Region}/s3/aws4_request";
        var stringToSign = $"AWS4-HMAC-SHA256\n{amzDate}\n{scope}\n{Hex(SHA256.HashData(Encoding.UTF8.GetBytes(canonicalRequest)))}";

        var k = Encoding.UTF8.GetBytes("AWS4" + s.SecretKey);
        foreach (var part in new[] { day, s.Region, "s3", "aws4_request" }) k = HMACSHA256.HashData(k, Encoding.UTF8.GetBytes(part));
        var signature = Hex(HMACSHA256.HashData(k, Encoding.UTF8.GetBytes(stringToSign)));

        var url = $"{s.Endpoint.Scheme}://{host}{path}{(canonicalQuery.Length > 0 ? "?" + canonicalQuery : "")}";
        // The URL must reach the wire exactly as it was signed.
        var req = new HttpRequestMessage(new HttpMethod(method), new Uri(url, new UriCreationOptions { DangerousDisablePathAndQueryCanonicalization = true }));
        foreach (var (name, value) in signed)
            if (name != "host") req.Headers.TryAddWithoutValidation(name, value);
        req.Headers.TryAddWithoutValidation("Authorization",
            $"AWS4-HMAC-SHA256 Credential={s.AccessKey}/{scope}, SignedHeaders={signedHeaders}, Signature={signature}");
        return req;
    }

    static void Check(HttpResponseMessage resp, byte[] body, string path)
    {
        var status = (int)resp.StatusCode;
        if (status is >= 200 and < 300) return;
        if (status == 404) throw RemoteException.NotFound(path);
        if (status is 401 or 403)
        {
            var code = XmlValue("Code", body) ?? "AccessDenied";
            throw code == "AccessDenied" ? RemoteException.PermissionDenied(path)
                : RemoteException.Authentication($"{code}: {XmlValue("Message", body)}");
        }
        throw RemoteException.Protocol($"S3 {status}: {XmlValue("Message", body) ?? path}");
    }

    // Listing

    sealed record Page(List<RemoteItem> Files, List<string> Dirs, List<string> Keys, string? Next);

    Page ListPage(string prefix, bool delimiter, string? token, int? maxKeys = null)
    {
        var q = new Dictionary<string, string> { ["list-type"] = "2", ["prefix"] = prefix };
        if (delimiter) q["delimiter"] = "/";
        if (token != null) q["continuation-token"] = token;
        if (maxKeys != null) q["max-keys"] = maxKeys.Value.ToString(CultureInfo.InvariantCulture);
        var (body, resp) = Http.Send(Request("GET", "", q));
        Check(resp, body, prefix);

        var root = XDocument.Load(new MemoryStream(body)).Root!;
        IEnumerable<XElement> All(XElement e, string name) => e.Elements().Where(x => x.Name.LocalName == name);
        string? Value(XElement e, string name) => All(e, name).FirstOrDefault()?.Value;
        var files = new List<RemoteItem>();
        var keys = new List<string>();
        foreach (var c in All(root, "Contents"))
        {
            var key = Value(c, "Key") ?? "";
            keys.Add(key);
            if (key == prefix || !key.StartsWith(prefix, StringComparison.Ordinal)) continue;
            files.Add(new RemoteItem(key[prefix.Length..], false,
                ulong.TryParse(Value(c, "Size"), out var size) ? size : 0,
                DateTime.TryParse(Value(c, "LastModified"), CultureInfo.InvariantCulture,
                    DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var modified) ? modified : DateTime.UtcNow));
        }
        var dirs = All(root, "CommonPrefixes").Select(p => Value(p, "Prefix") ?? "")
            .Where(p => p.Length > prefix.Length + 1 && p.StartsWith(prefix, StringComparison.Ordinal))
            .Select(p => p[prefix.Length..^1]).ToList();
        return new Page(files, dirs, keys, Value(root, "NextContinuationToken"));
    }

    public List<RemoteItem> List(string path)
    {
        var prefix = DirPrefix(path);
        var items = new List<RemoteItem>();
        string? token = null;
        do
        {
            var page = ListPage(prefix, delimiter: true, token);
            items.AddRange(page.Files);
            items.AddRange(page.Dirs.Select(RemoteItem.Folder));
            token = page.Next;
        } while (token != null);
        return items;
    }

    List<string> AllKeys(string prefix)
    {
        var keys = new List<string>();
        string? token = null;
        do
        {
            var page = ListPage(prefix, delimiter: false, token);
            keys.AddRange(page.Keys);
            token = page.Next;
        } while (token != null);
        return keys;
    }

    public RemoteItem Stat(string path)
    {
        if (RemotePath.Normalize(path) == "/") return RemoteItem.Folder("/");
        var (body, resp) = Http.Send(Request("HEAD", Key(path)));
        if (resp.StatusCode == HttpStatusCode.OK)
            return new RemoteItem(RemotePath.Name(path), false, (ulong)(resp.Content.Headers.ContentLength ?? 0),
                resp.Content.Headers.LastModified?.UtcDateTime ?? DateTime.UtcNow);
        if (resp.StatusCode != HttpStatusCode.NotFound) Check(resp, body, path);
        var page = ListPage(DirPrefix(path), delimiter: false, null, maxKeys: 1);
        return page.Keys.Count > 0 ? RemoteItem.Folder(RemotePath.Name(path)) : throw RemoteException.NotFound(path);
    }

    // Objects

    public void Download(string path, string localFile)
    {
        var (body, resp) = Http.Download(Request("GET", Key(path)), localFile);
        Check(resp, body, path);
    }

    public bool SupportsRangeReads => true;

    public byte[] Read(string path, ulong offset, int length)
    {
        if (length <= 0) return [];
        var range = $"bytes={offset}-{offset + (ulong)length - 1}";
        var (body, resp) = Http.Send(Request("GET", Key(path), headers: new() { ["range"] = range }));
        if (resp.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable) return [];
        Check(resp, body, path);
        return body;
    }

    public void Upload(string localFile, string path)
    {
        var (body, resp) = Http.Upload(Request("PUT", Key(path), payloadHash: "UNSIGNED-PAYLOAD"), localFile, "application/octet-stream");
        Check(resp, body, path);
    }

    public void MakeDirectory(string path)
    {
        var req = Request("PUT", DirPrefix(path));
        req.Content = new ByteArrayContent([]);
        var (body, resp) = Http.Send(req);
        Check(resp, body, path);
    }

    void DeleteKey(string key, string path)
    {
        var (body, resp) = Http.Send(Request("DELETE", key));
        if (resp.StatusCode != HttpStatusCode.NotFound) Check(resp, body, path);
    }

    public void RemoveFile(string path) => DeleteKey(Key(path), path);

    public void RemoveDirectory(string path)
    {
        var prefix = DirPrefix(path);
        var page = ListPage(prefix, delimiter: false, null, maxKeys: 2);
        if (page.Keys.Any(k => k != prefix)) throw RemoteException.NotEmpty(path);
        DeleteKey(prefix, path);
    }

    void CopyKey(string from, string to, string path)
    {
        var source = "/" + Encode(s.Bucket, false) + "/" + Encode(from, true);
        var req = Request("PUT", to, headers: new() { ["x-amz-copy-source"] = source });
        req.Content = new ByteArrayContent([]);
        var (body, resp) = Http.Send(req);
        Check(resp, body, path);
    }

    public void Move(string from, string to)
    {
        if (Stat(from).IsDirectory)
        {
            // S3 has no rename: copy every object under the folder, then delete the originals.
            var src = DirPrefix(from);
            var dst = DirPrefix(to);
            var keys = AllKeys(src);
            foreach (var k in keys) CopyKey(k, dst + k[src.Length..], from);
            foreach (var k in keys) DeleteKey(k, from);
        }
        else
        {
            CopyKey(Key(from), Key(to), from);
            DeleteKey(Key(from), from);
        }
    }

    /// Checks the signer against the GET Object example from the AWS SigV4 documentation.
    public static bool SignatureSelfTest()
    {
        var b = new S3Backend(new S3Settings(new Uri("https://s3.amazonaws.com"), "us-east-1", "examplebucket",
            "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", false, ""));
        var req = b.Request("GET", "test.txt", headers: new() { ["range"] = "bytes=0-9" },
            now: DateTime.UnixEpoch.AddSeconds(1_369_353_600));
        return req.Headers.TryGetValues("Authorization", out var auth)
            && auth.First().EndsWith("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41");
    }

    // Helpers

    /// Percent-encodes everything but A-Z a-z 0-9 - _ . ~ (and "/" in keys), as SigV4 requires.
    static string Encode(string value, bool keepSlash)
    {
        var e = Uri.EscapeDataString(value);
        return keepSlash ? e.Replace("%2F", "/") : e;
    }

    static string Hex(byte[] bytes) => Convert.ToHexStringLower(bytes);

    static string? XmlValue(string tag, byte[] body)
    {
        var text = Encoding.UTF8.GetString(body);
        var a = text.IndexOf($"<{tag}>", StringComparison.Ordinal);
        if (a < 0) return null;
        a += tag.Length + 2;
        var b = text.IndexOf($"</{tag}>", a, StringComparison.Ordinal);
        return b < 0 ? null : text[a..b];
    }
}
