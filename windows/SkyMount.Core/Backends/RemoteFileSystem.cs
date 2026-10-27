namespace SkyMount.Core;

/// One file or folder as a backend reports it. Times are UTC.
public sealed record RemoteItem(string Name, bool IsDirectory, ulong Size, DateTime Modified, string? Id = null)
{
    public static RemoteItem Folder(string name) => new(name, true, 0, DateTime.UtcNow);
}

public enum RemoteErrorKind { NotFound, PermissionDenied, AlreadyExists, NotEmpty, Unsupported, Authentication, Network, Protocol }

public sealed class RemoteException(RemoteErrorKind kind, string message) : Exception(message)
{
    public RemoteErrorKind Kind { get; } = kind;

    public static RemoteException NotFound(string path) => new(RemoteErrorKind.NotFound, $"Not found: {path}");
    public static RemoteException PermissionDenied(string path) => new(RemoteErrorKind.PermissionDenied, $"Permission denied: {path}");
    public static RemoteException AlreadyExists(string path) => new(RemoteErrorKind.AlreadyExists, $"Already exists: {path}");
    public static RemoteException NotEmpty(string path) => new(RemoteErrorKind.NotEmpty, $"Folder is not empty: {path}");
    public static RemoteException Unsupported(string what) => new(RemoteErrorKind.Unsupported, $"Not supported: {what}");
    public static RemoteException Authentication(string message) => new(RemoteErrorKind.Authentication, $"Sign-in failed: {message}");
    public static RemoteException Network(string message) => new(RemoteErrorKind.Network, $"Network error: {message}");
    public static RemoteException Protocol(string message) => new(RemoteErrorKind.Protocol, message);
}

/// Operations every backend implements. Paths are absolute within the mount ("/a/b.txt").
/// Implementations are called from many threads and must serialize internally if needed.
public interface IRemoteFileSystem
{
    void Connect();
    void Disconnect();
    List<RemoteItem> List(string path);
    RemoteItem Stat(string path);
    void Download(string path, string localFile);
    void Upload(string localFile, string path);
    void MakeDirectory(string path);
    void RemoveFile(string path);
    void RemoveDirectory(string path);
    void Move(string from, string to);

    /// True when Read can fetch part of a file without downloading all of it.
    bool SupportsRangeReads => false;
    byte[] Read(string path, ulong offset, int length) => throw RemoteException.Unsupported("partial reads");
    /// True when SetModified works (SFTP, local folders).
    bool CanSetModificationTime => false;
    void SetModified(string path, DateTime modified) { }
    /// Called after wake from sleep or a network change; backends drop stale connections.
    void NetworkChanged() { }
}

public static class RemoteFileSystemExtensions
{
    /// Stat by listing the parent folder, for backends without a cheap single-item lookup.
    public static RemoteItem StatViaParent(this IRemoteFileSystem fs, string path)
    {
        if (RemotePath.Normalize(path) == "/") return RemoteItem.Folder("/");
        var name = RemotePath.Name(path);
        return fs.List(RemotePath.Parent(path)).FirstOrDefault(i => i.Name == name) ?? throw RemoteException.NotFound(path);
    }
}

public static class RemotePath
{
    public static string Normalize(string path) => "/" + string.Join('/', path.Split('/', StringSplitOptions.RemoveEmptyEntries));

    public static string Parent(string path)
    {
        var p = Normalize(path);
        var i = p.LastIndexOf('/');
        return i <= 0 ? "/" : p[..i];
    }

    public static string Name(string path)
    {
        var p = Normalize(path);
        return p[(p.LastIndexOf('/') + 1)..];
    }

    public static string Join(string dir, string name) => Normalize(dir + "/" + name);

    /// Joins a configured remote root ("/home/u", "") with a mount-relative path.
    public static string Under(string root, string path)
    {
        var r = Normalize(root);
        return r == "/" ? Normalize(path) : Normalize(r + "/" + path);
    }

    /// True when `path` lies inside `folder` (not the folder itself).
    public static bool IsInside(string path, string folder) =>
        folder == "/" ? path != "/" : path.StartsWith(folder + "/", StringComparison.Ordinal);
}
