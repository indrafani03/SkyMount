namespace SkyMount.Core;

/// Serves a local folder. Used by smctl to exercise the cache and the drive without a server.
public sealed class LocalFolderBackend(string root) : IRemoteFileSystem
{
    string Local(string path) => Path.Combine(root, RemotePath.Normalize(path)[1..].Replace('/', '\\'));

    static RemoteItem Item(FileSystemInfo info, string name) =>
        new(name, info is DirectoryInfo, info is FileInfo f ? (ulong)f.Length : 0, info.LastWriteTimeUtc);

    public void Connect()
    {
        if (!Directory.Exists(root)) throw RemoteException.NotFound(root);
    }

    public void Disconnect() { }

    public List<RemoteItem> List(string path)
    {
        var dir = new DirectoryInfo(Local(path));
        if (!dir.Exists) throw RemoteException.NotFound(path);
        return Map(path, () => dir.EnumerateFileSystemInfos().Select(i => Item(i, i.Name)).ToList());
    }

    public RemoteItem Stat(string path)
    {
        var local = Local(path);
        var name = RemotePath.Normalize(path) == "/" ? "/" : RemotePath.Name(path);
        if (Directory.Exists(local)) return Item(new DirectoryInfo(local), name);
        if (File.Exists(local)) return Item(new FileInfo(local), name);
        throw RemoteException.NotFound(path);
    }

    public bool SupportsRangeReads => true;

    public byte[] Read(string path, ulong offset, int length) => Map(path, () => CachedFileSystem.Pread(Local(path), offset, length));

    public void Download(string path, string localFile) => Map(path, () => File.Copy(Local(path), localFile, overwrite: true));

    /// Rewrites an existing file in place so it keeps its attributes, like a server does.
    public void Upload(string localFile, string path) => Map(path, () =>
    {
        using var input = File.OpenRead(localFile);
        using var output = new FileStream(Local(path), FileMode.Create, FileAccess.Write);
        input.CopyTo(output);
    });

    public void MakeDirectory(string path)
    {
        if (Directory.Exists(Local(path)) || File.Exists(Local(path))) throw RemoteException.AlreadyExists(path);
        Map(path, () => Directory.CreateDirectory(Local(path)));
    }

    public void RemoveFile(string path)
    {
        if (!File.Exists(Local(path))) throw RemoteException.NotFound(path);
        Map(path, () => File.Delete(Local(path)));
    }

    public void RemoveDirectory(string path)
    {
        var local = Local(path);
        if (!Directory.Exists(local)) throw RemoteException.NotFound(path);
        if (Directory.EnumerateFileSystemEntries(local).Any()) throw RemoteException.NotEmpty(path);
        Map(path, () => Directory.Delete(local));
    }

    public void Move(string from, string to) => Map(from, () =>
    {
        var src = Local(from);
        var dst = Local(to);
        if (Directory.Exists(src)) Directory.Move(src, dst);
        else if (File.Exists(src)) File.Move(src, dst, overwrite: true);
        else throw RemoteException.NotFound(from);
    });

    public bool CanSetModificationTime => true;

    public void SetModified(string path, DateTime modified) => Map(path, () => File.SetLastWriteTimeUtc(Local(path), modified));

    static void Map(string path, Action body) => Map(path, () =>
    {
        body();
        return 0;
    });

    static T Map<T>(string path, Func<T> body)
    {
        try { return body(); }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { throw RemoteException.NotFound(path); }
        catch (UnauthorizedAccessException) { throw RemoteException.PermissionDenied(path); }
        catch (IOException e) { throw RemoteException.Protocol(e.Message); }
    }
}
