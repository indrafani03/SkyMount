using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Web;

namespace SkyMount.Core;

/// OAuth 2.0 for installed apps: browser consent, PKCE, and a loopback redirect to 127.0.0.1.
/// Uses the user's own "Desktop app" OAuth client from Google Cloud Console.
public sealed class GoogleOAuth(GoogleOAuth.Client client)
{
    public sealed record Client(string Id, string Secret);

    public sealed record Grant(string RefreshToken, string Email);

    const string Scope = "https://www.googleapis.com/auth/drive";

    /// Opens the consent page and waits (up to 5 minutes) for the redirect. Call off the UI thread.
    public Grant Authorize(Action<string> openUrl)
    {
        var verifier = RandomUrlSafe(48);
        var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        var state = RandomUrlSafe(16);
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            var redirect = $"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}";
            openUrl("https://accounts.google.com/o/oauth2/v2/auth?" + Form(new()
            {
                ["client_id"] = client.Id,
                ["redirect_uri"] = redirect,
                ["response_type"] = "code",
                ["scope"] = Scope,
                ["code_challenge"] = challenge,
                ["code_challenge_method"] = "S256",
                ["state"] = state,
                ["access_type"] = "offline",
                ["prompt"] = "consent",
            }));
            var code = WaitForCode(listener, state, DateTime.UtcNow.AddMinutes(5));
            var token = TokenRequest(new()
            {
                ["code"] = code,
                ["client_id"] = client.Id,
                ["client_secret"] = client.Secret,
                ["redirect_uri"] = redirect,
                ["grant_type"] = "authorization_code",
                ["code_verifier"] = verifier,
            });
            var refresh = (string?)token["refresh_token"];
            var access = (string?)token["access_token"];
            if (refresh == null || access == null) throw RemoteException.Authentication("Google returned no refresh token");
            var email = "";
            try { email = Email(access); }
            catch (RemoteException) { }
            return new Grant(refresh, email);
        }
        finally { listener.Stop(); }
    }

    /// Answers browser requests on the loopback port until one carries our state.
    static string WaitForCode(TcpListener listener, string state, DateTime deadline)
    {
        while (true)
        {
            var accept = listener.AcceptTcpClientAsync();
            var left = deadline - DateTime.UtcNow;
            if (left <= TimeSpan.Zero || !accept.Wait(left)) throw RemoteException.Authentication("timed out waiting for the browser");
            using var tcp = accept.Result;
            var stream = tcp.GetStream();
            stream.ReadTimeout = 5000;
            string? line;
            try { line = new StreamReader(stream, Encoding.ASCII, false, 4096, leaveOpen: true).ReadLine(); }
            catch (IOException) { continue; }
            var target = line?.Split(' ') is [_, var t, ..] ? t : "/";
            var q = HttpUtility.ParseQueryString(target.Contains('?') ? target[(target.IndexOf('?') + 1)..] : "");
            if (q["state"] != state)
            {
                Respond(stream, 400, "Unexpected request.");
                continue;
            }
            var code = q["code"];
            Respond(stream, 200, code != null
                ? "<h2>SkyMount is connected to Google Drive.</h2><p>You can close this tab.</p>"
                : $"<h2>Google sign-in did not finish.</h2><p>{WebUtility.HtmlEncode(q["error"] ?? "")}</p>");
            return code ?? throw RemoteException.Authentication(q["error"] ?? "cancelled");
        }
    }

    static void Respond(Stream stream, int status, string html)
    {
        var body = Encoding.UTF8.GetBytes("<!doctype html><meta charset=utf-8>" + html);
        var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {(status == 200 ? "OK" : "Bad Request")}\r\n"
            + $"Content-Type: text/html; charset=utf-8\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
        try
        {
            stream.Write(head);
            stream.Write(body);
        }
        catch (IOException) { }
    }

    /// Returns a fresh access token and when it expires.
    public (string Token, DateTime Expiry) Refresh(string refreshToken)
    {
        var token = TokenRequest(new()
        {
            ["refresh_token"] = refreshToken,
            ["client_id"] = client.Id,
            ["client_secret"] = client.Secret,
            ["grant_type"] = "refresh_token",
        });
        var access = (string?)token["access_token"] ?? throw RemoteException.Authentication("Google refused the saved sign-in; sign in again");
        var expires = (double?)token["expires_in"] ?? 3000;
        return (access, DateTime.UtcNow.AddSeconds(expires - 60));
    }

    static JsonObject TokenRequest(Dictionary<string, string> form)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, "https://oauth2.googleapis.com/token") { Content = new FormUrlEncodedContent(form) };
        var (body, resp) = Http.Send(req);
        var json = Json(body);
        if (resp.StatusCode != HttpStatusCode.OK)
            throw RemoteException.Authentication((string?)json["error_description"] ?? (string?)json["error"] ?? $"HTTP {(int)resp.StatusCode}");
        return json;
    }

    static string Email(string accessToken)
    {
        var req = new HttpRequestMessage(HttpMethod.Get, "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)");
        req.Headers.Authorization = new("Bearer", accessToken);
        return (string?)Json(Http.Send(req).Body)["user"]?["emailAddress"] ?? "";
    }

    internal static JsonObject Json(byte[] body)
    {
        try { return JsonNode.Parse(body) as JsonObject ?? new JsonObject(); }
        catch (JsonException) { return new JsonObject(); }
    }

    internal static string Form(Dictionary<string, string> fields) =>
        string.Join('&', fields.Select(f => $"{Uri.EscapeDataString(f.Key)}={Uri.EscapeDataString(f.Value)}"));

    static string RandomUrlSafe(int bytes) => Base64Url(RandomNumberGenerator.GetBytes(bytes));

    static string Base64Url(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
