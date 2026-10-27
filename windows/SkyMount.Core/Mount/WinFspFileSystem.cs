using System.Security.AccessControl;
using System.Security.Principal;
using Fsp;
using FileInfo = Fsp.Interop.FileInfo;
using VolumeInfo = Fsp.Interop.VolumeInfo;

namespace SkyMount.Core;

/// Windows file requests (through WinFsp) in front of a CachedFileSystem and its WriteBack.
/// - A name is matched exactly first, then without regard to case, as Windows programs expect.
/// - Characters Windows forbids in names appear as look-alikes (WindowsNames).
/// - Deletes and renames go through the WriteBack, so a pending upload never brings back an old name.
sealed unsafe class WinFspFileSystem(CachedFileSystem fs, WriteBack wb, string label, string prefix, Action<string> log) : FileSystemBase
{
    /// Only this user may open files (SYSTEM and administrators can read the cache anyway).
    readonly byte[] security = SecurityFor(WindowsIdentity.GetCurrent().User!.Value);
    readonly object gate = new();
    /// Open files by server path, shared by all their handles; renames update them.
    readonly Dictionary<string, Node> nodes = [];

    sealed class Node(string path, bool isDirectory)
    {
        public string Path = path;
        public readonly bool IsDirectory = isDirectory;
        public int Opens;
    }

    sealed class NtStatusException(int status) : Exception($"NTSTATUS 0x{status:X8}")
    {
        public int Status { get; } = status;
    }

    static byte[] SecurityFor(string sid)
    {
        var sd = new RawSecurityDescriptor($"O:{sid}G:{sid}D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;{sid})");
        var bytes = new byte[sd.BinaryLength];
        sd.GetBinaryForm(bytes, 0);
        return bytes;
    }

    public override int Init(object host0)
    {
        var host = (FileSystemHost)host0;
        host.SectorSize = 4096;
        host.SectorsPerAllocationUnit = 1;
        host.MaxComponentLength = 255;
        host.FileInfoTimeout = 1000;
        host.CaseSensitiveSearch = false;
        host.CasePreservedNames = true;
        host.UnicodeOnDisk = true;
        host.PersistentAcls = true;
        host.PostCleanupWhenModifiedOnly = true;
        // Re-read a file on its next open instead of trusting the kernel's cache, which cannot see
        // changes made on the server.
        host.FlushAndPurgeOnCleanup = true;
        host.VolumeCreationTime = (ulong)DateTime.UtcNow.ToFileTimeUtc();
        host.VolumeSerialNumber = (uint)label.GetHashCode();
        host.FileSystemName = "SkyMount";
        // A network drive: Explorer deletes files instead of moving them into a Recycle Bin on the server.
        host.Prefix = prefix;
        return STATUS_SUCCESS;
    }

    public override int ExceptionHandler(Exception ex)
    {
        switch (ex)
        {
            case NtStatusException s:
                return s.Status;
            case RemoteException r:
                if (r.Kind == RemoteErrorKind.Protocol) log(r.Message);
                return r.Kind switch
                {
                    RemoteErrorKind.NotFound => STATUS_OBJECT_NAME_NOT_FOUND,
                    RemoteErrorKind.PermissionDenied or RemoteErrorKind.Authentication => STATUS_ACCESS_DENIED,
                    RemoteErrorKind.AlreadyExists => STATUS_OBJECT_NAME_COLLISION,
                    RemoteErrorKind.NotEmpty => STATUS_DIRECTORY_NOT_EMPTY,
                    RemoteErrorKind.Unsupported => STATUS_INVALID_DEVICE_REQUEST,
                    RemoteErrorKind.Network => STATUS_NETWORK_UNREACHABLE,
                    _ => STATUS_UNEXPECTED_IO_ERROR,
                };
            default:
                log($"unexpected error: {ex}");
                return STATUS_UNEXPECTED_IO_ERROR;
        }
    }

    public override int GetVolumeInfo(out VolumeInfo info)
    {
        info = default;
        // Quotas differ per backend; report a large volume so Explorer allows copies.
        info.TotalSize = 1UL << 40;
        info.FreeSize = 1UL << 39;
        info.SetVolumeLabel(label.Length > 32 ? label[..32] : label);
        return STATUS_SUCCESS;
    }

    // Names

    static string Remote(string fileName) => RemotePath.Normalize(string.Join('/',
        fileName.Split('\\', StringSplitOptions.RemoveEmptyEntries).Select(WindowsNames.ToRemote)));

    static string Windows(string path) => "\\" + string.Join('\\',
        path.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(WindowsNames.ToLocal));

    RemoteItem? Find(string path)
    {
        if (path == "/") return RemoteItem.Folder("/");
        if (wb.PendingItem(path) is { } pending) return pending;
        try { return fs.Stat(path); }
        catch (RemoteException e) when (e.Kind == RemoteErrorKind.NotFound) { return null; }
    }

    List<RemoteItem> Children(string dir)
    {
        var items = fs.List(dir);
        foreach (var p in wb.PendingIn(dir))
            if (!items.Any(i => i.Name == p.Name)) items.Add(p);
        return items;
    }

    /// The server path for a Windows path and what is there (null when nothing is, with the path a
    /// new item would get).
    (string Path, RemoteItem? Item) Resolve(string fileName)
    {
        var exact = Remote(fileName);
        if (Find(exact) is { } hit) return (exact, hit);
        var names = exact.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var path = "/";
        for (var i = 0; ; i++)
        {
            var children = Children(path);
            var match = children.FirstOrDefault(c => c.Name == names[i])
                ?? children.FirstOrDefault(c => string.Equals(c.Name, names[i], StringComparison.OrdinalIgnoreCase));
            var next = RemotePath.Join(path, match?.Name ?? names[i]);
            if (i == names.Length - 1) return (next, match);
            if (match is not { IsDirectory: true }) throw new NtStatusException(STATUS_OBJECT_PATH_NOT_FOUND);
            path = next;
        }
    }

    FileInfo Info(string path, RemoteItem item)
    {
        var size = item.Size;
        var modified = item.Modified;
        if (!item.IsDirectory && wb.Overlay(path) is { } o) (size, modified) = o;
        var time = modified.Year < 1601 ? 0 : (ulong)modified.ToFileTimeUtc();
        return new FileInfo
        {
            FileAttributes = item.IsDirectory ? (uint)FileAttributes.Directory
                : (uint)FileAttributes.Archive | (fs.ReadOnly ? (uint)FileAttributes.ReadOnly : 0),
            FileSize = size,
            AllocationSize = (size + 4095) / 4096 * 4096,
            CreationTime = time,
            LastAccessTime = time,
            LastWriteTime = time,
            ChangeTime = time,
        };
    }

    FileInfo InfoOf(Node node) => Info(node.Path, Find(node.Path) ?? throw RemoteException.NotFound(node.Path));

    Node Acquire(string path, bool isDirectory)
    {
        lock (gate)
        {
            if (!nodes.TryGetValue(path, out var node) || node.IsDirectory != isDirectory) nodes[path] = node = new Node(path, isDirectory);
            node.Opens++;
            return node;
        }
    }

    void RequireWritable()
    {
        if (fs.ReadOnly) throw new NtStatusException(STATUS_MEDIA_WRITE_PROTECTED);
    }

    // Opening and closing

    public override int GetSecurityByName(string fileName, out uint fileAttributes, ref byte[] securityDescriptor)
    {
        var (path, item) = Resolve(fileName);
        if (item == null) throw new NtStatusException(STATUS_OBJECT_NAME_NOT_FOUND);
        fileAttributes = Info(path, item).FileAttributes;
        if (securityDescriptor != null) securityDescriptor = security;
        return STATUS_SUCCESS;
    }

    public override int Open(string fileName, uint createOptions, uint grantedAccess,
        out object fileNode, out object fileDesc, out FileInfo fileInfo, out string normalizedName)
    {
        var (path, item) = Resolve(fileName);
        if (item == null) throw new NtStatusException(STATUS_OBJECT_NAME_NOT_FOUND);
        fileNode = fileDesc = Acquire(path, item.IsDirectory);
        fileInfo = Info(path, item);
        normalizedName = Windows(path);
        return STATUS_SUCCESS;
    }

    public override int Create(string fileName, uint createOptions, uint grantedAccess, uint fileAttributes,
        byte[] securityDescriptor, ulong allocationSize,
        out object fileNode, out object fileDesc, out FileInfo fileInfo, out string normalizedName)
    {
        RequireWritable();
        var (path, item) = Resolve(fileName);
        if (item != null) throw new NtStatusException(STATUS_OBJECT_NAME_COLLISION);
        var isDirectory = (createOptions & FILE_DIRECTORY_FILE) != 0;
        if (isDirectory) fs.MakeDirectory(path);
        else wb.Create(path);
        item = isDirectory ? RemoteItem.Folder(RemotePath.Name(path)) : wb.PendingItem(path)!;
        fileNode = fileDesc = Acquire(path, isDirectory);
        fileInfo = Info(path, item);
        normalizedName = Windows(path);
        return STATUS_SUCCESS;
    }

    public override int Overwrite(object fileNode, object fileDesc, uint fileAttributes, bool replaceFileAttributes,
        ulong allocationSize, out FileInfo fileInfo)
    {
        RequireWritable();
        var node = (Node)fileNode;
        wb.SetSize(node.Path, 0);
        fileInfo = InfoOf(node);
        return STATUS_SUCCESS;
    }

    public override void Cleanup(object fileNode, object fileDesc, string fileName, uint flags)
    {
        var node = (Node)fileNode;
        if ((flags & CleanupDelete) == 0) return;
        try { wb.Delete(node.Path); }
        catch (Exception e) { log($"could not delete {node.Path}: {e.Message}"); }
    }

    public override void Close(object fileNode, object fileDesc)
    {
        var node = (Node)fileNode;
        lock (gate)
            if (--node.Opens == 0 && nodes.GetValueOrDefault(node.Path) == node) nodes.Remove(node.Path);
    }

    // Contents

    public override int Read(object fileNode, object fileDesc, IntPtr buffer, ulong offset, uint length, out uint bytesTransferred)
    {
        var node = (Node)fileNode;
        var span = new Span<byte>((void*)buffer, (int)length);
        int n;
        if (wb.Read(node.Path, span, offset) is { } local) n = local;
        else
        {
            var data = fs.Read(node.Path, offset, (int)length);
            data.CopyTo(span);
            n = data.Length;
        }
        bytesTransferred = (uint)n;
        return n == 0 && length > 0 ? STATUS_END_OF_FILE : STATUS_SUCCESS;
    }

    public override int Write(object fileNode, object fileDesc, IntPtr buffer, ulong offset, uint length,
        bool writeToEndOfFile, bool constrainedIo, out uint bytesTransferred, out FileInfo fileInfo)
    {
        RequireWritable();
        var node = (Node)fileNode;
        bytesTransferred = (uint)wb.Write(node.Path, new ReadOnlySpan<byte>((void*)buffer, (int)length), offset, writeToEndOfFile, constrainedIo);
        fileInfo = InfoOf(node);
        return STATUS_SUCCESS;
    }

    /// Uploads now (a program asked for its data to be safe), or everything for a volume flush.
    public override int Flush(object fileNode, object fileDesc, out FileInfo fileInfo)
    {
        fileInfo = default;
        if (fileNode is not Node node)
        {
            wb.FlushAll();
            return STATUS_SUCCESS;
        }
        if (!node.IsDirectory) wb.Flush(node.Path);
        fileInfo = InfoOf(node);
        return STATUS_SUCCESS;
    }

    public override int GetFileInfo(object fileNode, object fileDesc, out FileInfo fileInfo)
    {
        fileInfo = InfoOf((Node)fileNode);
        return STATUS_SUCCESS;
    }

    /// Only the modification time is kept (a copy that preserves dates); servers have no other
    /// Windows times or attributes.
    public override int SetBasicInfo(object fileNode, object fileDesc, uint fileAttributes, ulong creationTime,
        ulong lastAccessTime, ulong lastWriteTime, ulong changeTime, out FileInfo fileInfo)
    {
        var node = (Node)fileNode;
        if (lastWriteTime is > 0 and < (ulong)long.MaxValue && !node.IsDirectory && !fs.ReadOnly)
        {
            var modified = DateTime.FromFileTimeUtc((long)lastWriteTime);
            if (!wb.SetModified(node.Path, modified) && Find(node.Path) is { } item
                && Math.Abs((item.Modified - modified).TotalSeconds) >= 1)
                fs.SetModified(node.Path, modified);
        }
        fileInfo = InfoOf(node);
        return STATUS_SUCCESS;
    }

    public override int SetFileSize(object fileNode, object fileDesc, ulong newSize, bool setAllocationSize, out FileInfo fileInfo)
    {
        RequireWritable();
        var node = (Node)fileNode;
        var current = InfoOf(node).FileSize;
        // An allocation size only matters when it cuts the file short.
        if (newSize != current && (!setAllocationSize || newSize < current)) wb.SetSize(node.Path, newSize);
        fileInfo = InfoOf(node);
        return STATUS_SUCCESS;
    }

    // Namespace

    public override int CanDelete(object fileNode, object fileDesc, string fileName)
    {
        RequireWritable();
        var node = (Node)fileNode;
        return node.IsDirectory && Children(node.Path).Count > 0 ? STATUS_DIRECTORY_NOT_EMPTY : STATUS_SUCCESS;
    }

    public override int Rename(object fileNode, object fileDesc, string fileName, string newFileName, bool replaceIfExists)
    {
        RequireWritable();
        var node = (Node)fileNode;
        var from = node.Path;
        var (to, existing) = Resolve(newFileName);
        if (existing != null && to == from)
        {
            // Only the case changes: the lookup found the file itself.
            to = RemotePath.Join(RemotePath.Parent(from), RemotePath.Name(Remote(newFileName)));
        }
        else if (existing != null)
        {
            if (!replaceIfExists) return STATUS_OBJECT_NAME_COLLISION;
            if (existing.IsDirectory) return STATUS_ACCESS_DENIED;
        }
        if (to == from) return STATUS_SUCCESS;
        wb.Move(from, to);
        lock (gate)
        {
            foreach (var (path, open) in nodes.Where(kv => kv.Key == from || RemotePath.IsInside(kv.Key, from)).ToList())
            {
                nodes.Remove(path);
                open.Path = to + path[from.Length..];
                nodes[open.Path] = open;
            }
            if (node.Path == from) node.Path = to;
        }
        return STATUS_SUCCESS;
    }

    public override bool ReadDirectoryEntry(object fileNode, object fileDesc, string pattern, string marker,
        ref object context, out string fileName, out FileInfo fileInfo)
    {
        if (context is not IEnumerator<(string Name, FileInfo Info)> entries)
        {
            var node = (Node)fileNode;
            var list = Children(node.Path)
                .Select(i => (WindowsNames.ToLocal(i.Name), Info(RemotePath.Join(node.Path, i.Name), i))).ToList();
            if (node.Path != "/")
            {
                var parent = RemotePath.Parent(node.Path);
                list.Add((".", InfoOf(node)));
                list.Add(("..", Info(parent, Find(parent) ?? RemoteItem.Folder(".."))));
            }
            list.Sort((a, b) => string.CompareOrdinal(a.Item1, b.Item1));
            // Each batch continues after the last name of the previous one.
            context = entries = list.Where(e => marker == null || string.CompareOrdinal(e.Item1, marker) > 0).GetEnumerator();
        }
        if (entries.MoveNext())
        {
            (fileName, fileInfo) = entries.Current;
            return true;
        }
        fileName = null!;
        fileInfo = default;
        return false;
    }

    public override int GetSecurity(object fileNode, object fileDesc, ref byte[] securityDescriptor)
    {
        securityDescriptor = security;
        return STATUS_SUCCESS;
    }

    /// Servers keep no Windows permissions; changes are accepted and dropped so copies that carry them work.
    public override int SetSecurity(object fileNode, object fileDesc, AccessControlSections sections, byte[] securityDescriptor) =>
        STATUS_SUCCESS;
}

/// Windows forbids some characters in names and drops a trailing dot or space. Server names with
/// them are shown with look-alike characters ("10:30.log" as "10：30.log") and turned back on the way
/// to the server, so such files can still be opened, renamed and deleted.
public static class WindowsNames
{
    const string Forbidden = "\\:*?\"<>|";
    const string LookAlike = "＼：＊？＂＜＞｜";

    public static string ToLocal(string name)
    {
        var chars = name.ToCharArray();
        for (var i = 0; i < chars.Length; i++)
        {
            var k = Forbidden.IndexOf(chars[i]);
            if (k >= 0) chars[i] = LookAlike[k];
            else if (chars[i] is > '\0' and < ' ') chars[i] = (char)(0x2400 + chars[i]); // control characters as their symbols
        }
        if (chars.Length > 0 && chars[^1] == '.') chars[^1] = '．';
        else if (chars.Length > 0 && chars[^1] == ' ') chars[^1] = '␠';
        return new string(chars);
    }

    public static string ToRemote(string name)
    {
        var chars = name.ToCharArray();
        for (var i = 0; i < chars.Length; i++)
        {
            var k = LookAlike.IndexOf(chars[i]);
            if (k >= 0) chars[i] = Forbidden[k];
            else if (chars[i] is > '\u2400' and < '\u2420') chars[i] = (char)(chars[i] - 0x2400);
        }
        if (chars.Length > 0 && chars[^1] == '．') chars[^1] = '.';
        else if (chars.Length > 0 && chars[^1] == '␠') chars[^1] = ' ';
        return new string(chars);
    }
}
