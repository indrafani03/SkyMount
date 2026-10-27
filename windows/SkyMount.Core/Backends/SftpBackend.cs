using System.Net.Sockets;
using System.Security.Cryptography;
using Renci.SshNet;
using Renci.SshNet.Common;
using Renci.SshNet.Sftp;

namespace SkyMount.Core;

public sealed record SftpSettings(
    string Host, int Port, string Username, string RemoteRoot, string? Password,
    string? PrivateKeyPath, string? KeyPassphrase, string? KnownFingerprint, int Sessions = 8);

/// SFTP through SSH.NET with a small pool of connections, so folder scans run requests in parallel.
/// Host keys are trusted on first use and pinned by SHA-256 fingerprint. Symbolic links are shown as
/// what they point to; broken ones are left out.
public sealed class SftpBackend : IRemoteFileSystem
{
    readonly SftpSettings s;
    readonly Action<string> onNewFingerprint;
    readonly object fingerprintLock = new();
    string? knownFingerprint;
    readonly Pool<SftpClient> pool;

    /// `onNewFingerprint` is called once when a server is seen for the first time, so the caller can save it.
    public SftpBackend(SftpSettings settings, Action<string> onNewFingerprint)
    {
        s = settings;
        this.onNewFingerprint = onNewFingerprint;
        knownFingerprint = settings.KnownFingerprint;
        pool = new Pool<SftpClient>(Math.Max(1, settings.Sessions), Open, c => c.Dispose(), c => c.IsConnected);
    }

    SftpClient Open()
    {
        AuthenticationMethod auth = string.IsNullOrEmpty(s.PrivateKeyPath)
            ? new PasswordAuthenticationMethod(s.Username, s.Password ?? "")
            : new PrivateKeyAuthenticationMethod(s.Username, KeyFile(s.PrivateKeyPath));
        var client = new SftpClient(new ConnectionInfo(s.Host, s.Port, s.Username, auth) { Timeout = TimeSpan.FromSeconds(30) })
        {
            // Keeps idle connections alive through NAT and firewall timeouts.
            KeepAliveInterval = TimeSpan.FromSeconds(20),
            OperationTimeout = TimeSpan.FromSeconds(60),
        };
        string? rejected = null;
        client.HostKeyReceived += (_, e) =>
        {
            var fingerprint = "SHA256:" + Convert.ToBase64String(SHA256.HashData(e.HostKey)).TrimEnd('=');
            lock (fingerprintLock)
            {
                if (knownFingerprint == null)
                {
                    knownFingerprint = fingerprint;
                    onNewFingerprint(fingerprint);
                }
                else if (knownFingerprint != fingerprint)
                {
                    e.CanTrust = false;
                    rejected = $"host key for {s.Host} changed (expected {knownFingerprint}, got {fingerprint}). "
                        + "If the server was reinstalled, press Forget next to Server key in the connection settings.";
                }
            }
        };
        try
        {
            client.Connect();
            return client;
        }
        catch (Exception e)
        {
            client.Dispose();
            throw rejected != null ? RemoteException.Authentication(rejected) : Map(e, "/");
        }
    }

    PrivateKeyFile KeyFile(string configured)
    {
        var path = Util.ExpandHome(configured);
        try { return string.IsNullOrEmpty(s.KeyPassphrase) ? new PrivateKeyFile(path) : new PrivateKeyFile(path, s.KeyPassphrase); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or SshException or InvalidOperationException)
        {
            throw RemoteException.Authentication($"cannot use the key {path}: {e.Message}");
        }
    }

    RemoteException Map(Exception e, string path) => e switch
    {
        RemoteException r => r,
        SftpPathNotFoundException => RemoteException.NotFound(path),
        SftpPermissionDeniedException => RemoteException.PermissionDenied(path),
        SshAuthenticationException or SshPassPhraseNullOrEmptyException => RemoteException.Authentication($"{s.Username}@{s.Host}: {e.Message}"),
        SftpException f => RemoteException.Protocol($"SFTP error {f.StatusCode} on {path}: {f.Message}"),
        SshConnectionException or SshOperationTimeoutException or SocketException or ObjectDisposedException => RemoteException.Network(e.Message),
        _ => RemoteException.Protocol(e.Message),
    };

    T With<T>(string path, Func<SftpClient, T> body) => pool.Use(c =>
    {
        try { return body(c); }
        catch (Exception e) { throw Map(e, path); }
    });

    void With(string path, Action<SftpClient> body) => With(path, c =>
    {
        body(c);
        return 0;
    });

    string Full(string path) => RemotePath.Under(s.RemoteRoot, path);

    static RemoteItem Item(string name, SftpFileAttributes a) =>
        new(name, a.IsDirectory, a.IsDirectory ? 0 : (ulong)Math.Max(0, a.Size), a.LastWriteTimeUtc);

    public void Connect() => With("/", _ => { });
    public void Disconnect() => pool.CloseAll();
    public void NetworkChanged() => pool.CloseIdle();

    public List<RemoteItem> List(string path) => With(path, c =>
    {
        var items = new List<RemoteItem>();
        foreach (var f in c.ListDirectory(Full(path)))
        {
            if (f.Name is "." or "..") continue;
            var a = f.Attributes;
            if (a.IsSymbolicLink)
            {
                try { a = c.GetAttributes(f.FullName); }
                catch (SftpPathNotFoundException) { continue; }
            }
            items.Add(Item(f.Name, a));
        }
        return items;
    });

    public RemoteItem Stat(string path) => RemotePath.Normalize(path) == "/"
        ? RemoteItem.Folder("/")
        : With(path, c => Item(RemotePath.Name(path), c.GetAttributes(Full(path))));

    public bool SupportsRangeReads => true;

    public byte[] Read(string path, ulong offset, int length) => With(path, c =>
    {
        using var stream = c.Open(Full(path), FileMode.Open, FileAccess.Read);
        stream.Seek((long)offset, SeekOrigin.Begin);
        var buf = new byte[length];
        var n = 0;
        while (n < length)
        {
            var r = stream.Read(buf, n, length - n);
            if (r == 0) break;
            n += r;
        }
        return n == length ? buf : buf[..n];
    });

    public void Download(string path, string localFile)
    {
        using var output = File.Create(localFile);
        With(path, c =>
        {
            output.SetLength(0);
            c.DownloadFile(Full(path), output);
        });
    }

    /// Overwrites in place: the server keeps the file's owner and permission bits.
    public void Upload(string localFile, string path)
    {
        using var input = File.OpenRead(localFile);
        With(path, c =>
        {
            input.Position = 0;
            c.UploadFile(input, Full(path), true);
        });
    }

    public void MakeDirectory(string path) => With(path, c => c.CreateDirectory(Full(path)));

    public void RemoveFile(string path) => With(path, c => c.DeleteFile(Full(path)));

    public void RemoveDirectory(string path) => With(path, c =>
    {
        try { c.DeleteDirectory(Full(path)); }
        catch (SftpException e) when (e.StatusCode == StatusCode.Failure) { throw RemoteException.NotEmpty(path); }
    });

    public void Move(string from, string to) => With(from, c =>
    {
        var src = Full(from);
        var dst = Full(to);
        // posix-rename@openssh.com replaces the target atomically.
        try { c.RenameFile(src, dst, true); }
        catch (Exception e) when (e is NotSupportedException or SftpException { StatusCode: StatusCode.OperationUnsupported })
        {
            // A plain SFTP v3 rename refuses to overwrite: remove the target and retry once.
            if (c.Exists(dst)) c.DeleteFile(dst);
            c.RenameFile(src, dst);
        }
    });

    public bool CanSetModificationTime => true;

    public void SetModified(string path, DateTime modified) => With(path, c => c.SetLastWriteTimeUtc(Full(path), modified));
}
