using System.Net.Sockets;
using FluentFTP;
using FluentFTP.Exceptions;

namespace SkyMount.Core;

public sealed record FtpSettings(string Host, int Port, string Username, string Password, string RemoteRoot, bool UseTls);

/// FTP and explicit FTPS through FluentFTP, with a small pool of logged-in connections.
public sealed class FtpBackend : IRemoteFileSystem
{
    readonly FtpSettings s;
    readonly Pool<FtpClient> pool;

    public FtpBackend(FtpSettings settings)
    {
        s = settings;
        // Servers often limit connections per user, so the pool stays small.
        pool = new Pool<FtpClient>(4, Open, c => c.Dispose(), c => c.IsConnected);
    }

    FtpClient Open()
    {
        var c = new FtpClient(s.Host, s.Username, s.Password, s.Port);
        c.Config.EncryptionMode = s.UseTls ? FtpEncryptionMode.Explicit : FtpEncryptionMode.None;
        c.Config.ConnectTimeout = 20_000;
        c.Config.ReadTimeout = 60_000;
        c.Config.DataConnectionConnectTimeout = 20_000;
        c.Config.DataConnectionReadTimeout = 60_000;
        try
        {
            c.Connect();
            return c;
        }
        catch (Exception e)
        {
            c.Dispose();
            throw Map(e, "/");
        }
    }

    static RemoteException Map(Exception e, string path) => e switch
    {
        RemoteException r => r,
        FtpAuthenticationException => RemoteException.Authentication(e.Message),
        FtpInvalidCertificateException => RemoteException.Authentication($"the server's TLS certificate is not trusted: {e.Message}"),
        FtpCommandException c => c.CompletionCode switch
        {
            // Some servers answer a listing of a missing folder with 501 instead of 550.
            "550" or "501" => RemoteException.NotFound(path),
            "530" => RemoteException.Authentication(c.Message),
            "553" or "532" => RemoteException.PermissionDenied(path),
            _ => RemoteException.Protocol($"FTP {c.CompletionCode}: {c.Message}"),
        },
        FtpMissingSocketException or SocketException or TimeoutException or IOException => RemoteException.Network(e.Message),
        _ => RemoteException.Protocol(e.Message),
    };

    T With<T>(string path, Func<FtpClient, T> body) => pool.Use(c =>
    {
        try { return body(c); }
        catch (Exception e) { throw Map(e, path); }
    });

    void With(string path, Action<FtpClient> body) => With(path, c =>
    {
        body(c);
        return 0;
    });

    string Full(string path) => RemotePath.Under(s.RemoteRoot, path);

    public void Connect() => List("/");
    public void Disconnect() => pool.CloseAll();
    public void NetworkChanged() => pool.CloseIdle();

    public List<RemoteItem> List(string path) => With(path, c => c.GetListing(Full(path))
        .Where(i => i.Type is FtpObjectType.File or FtpObjectType.Directory && i.Name is not ("." or ".."))
        .Select(i => new RemoteItem(i.Name, i.Type == FtpObjectType.Directory,
            i.Type == FtpObjectType.File ? (ulong)Math.Max(0, i.Size) : 0,
            i.Modified == DateTime.MinValue ? DateTime.UtcNow : DateTime.SpecifyKind(i.Modified, DateTimeKind.Utc)))
        .ToList());

    public RemoteItem Stat(string path) => this.StatViaParent(path);

    public void Download(string path, string localFile)
    {
        using var output = File.Create(localFile);
        With(path, c =>
        {
            output.SetLength(0);
            if (!c.DownloadStream(output, Full(path))) throw RemoteException.Protocol($"download of {path} failed");
        });
    }

    public bool SupportsRangeReads => true;

    public byte[] Read(string path, ulong offset, int length) => length <= 0 ? [] : With(path, c =>
    {
        using var buffer = new MemoryStream();
        c.DownloadStream(buffer, Full(path), (long)offset, null, (long)offset + length);
        var data = buffer.ToArray();
        return data.Length > length ? data[..length] : data;
    });

    /// STOR replaces the contents in place, so the server keeps the file's permissions.
    public void Upload(string localFile, string path)
    {
        using var input = File.OpenRead(localFile);
        With(path, c =>
        {
            input.Position = 0;
            if (c.UploadStream(input, Full(path), FtpRemoteExists.NoCheck) != FtpStatus.Success)
                throw RemoteException.Protocol($"upload of {path} failed");
        });
    }

    public void MakeDirectory(string path) => With(path, c =>
    {
        if (!c.CreateDirectory(Full(path), false)) throw RemoteException.AlreadyExists(path);
    });

    public void RemoveFile(string path) => With(path, c => c.DeleteFile(Full(path)));

    public void RemoveDirectory(string path)
    {
        if (List(path).Count > 0) throw RemoteException.NotEmpty(path);
        With(path, c =>
        {
            var reply = c.Execute("RMD " + Full(path));
            if (!reply.Success) throw reply.Code == "550" ? RemoteException.NotFound(path) : RemoteException.Protocol($"FTP {reply.Code}: {reply.Message}");
        });
    }

    public void Move(string from, string to) => With(from, c => c.Rename(Full(from), Full(to)));
}
