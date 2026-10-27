using System.Security.Cryptography;
using System.Text;

namespace SkyMount.Core;

/// Sits between the file system and a backend:
/// - caches folder listings and answers single-item lookups from them. A listing older than
///   `listingTTL` is still served while a background refresh fetches a new one, so browsing never
///   waits on the network for folders it has seen,
/// - lists subfolders one level ahead in the background, in parallel,
/// - keeps downloaded file contents on disk and reuses them while size and mtime still match,
/// - keeps Explorer and Finder metadata files (`desktop.ini`, `Thumbs.db`, `._*`, `.DS_Store`) local,
/// - keeps pinned folders fully downloaded and serves them from disk while the server is unreachable.
public sealed class CachedFileSystem : IDisposable
{
    public IRemoteFileSystem Backend { get; }
    public bool ReadOnly { get; }
    readonly TimeSpan listingTTL;
    readonly string contentDir, shadowDir;

    sealed record Listing(Dictionary<string, RemoteItem> Items, DateTime Fetched);

    readonly object gate = new();
    /// Never changed once stored, so callers may keep a listing's Items after releasing the gate.
    readonly Dictionary<string, Listing> listings = [];
    readonly Dictionary<string, ManualResetEventSlim> inFlight = [];
    /// Bumped on every local change to a folder; a listing fetched across a change is stale.
    readonly Dictionary<string, int> versions = [];
    readonly HashSet<string> refreshing = [];
    readonly Dictionary<string, Stamp> contentStamps;
    readonly Dictionary<string, object> pathLocks = [];
    readonly OfflineStore store;
    readonly Dictionary<string, PinState> pinStates = [];
    readonly Dictionary<string, int> downloading = [];
    readonly Timer maintenance;
    bool offline, probing;
    /// Background refreshes and prefetches. Six at a time leaves room in the connection pools for
    /// requests someone waits on.
    readonly SemaphoreSlim backgroundSlots = new(6);

    /// True after a request failed for lack of a connection, until one succeeds again.
    public bool IsOffline { get { lock (gate) return offline; } }
    /// Called (on a background thread) when the server answers again after being unreachable.
    public Action? OnReachable { get; set; }

    /// `pinsPath` stores the folders kept offline; null keeps none (command-line tools).
    public CachedFileSystem(IRemoteFileSystem backend, string cacheRoot, TimeSpan listingTTL, bool readOnly, string? pinsPath = null)
    {
        Backend = backend;
        this.listingTTL = listingTTL;
        ReadOnly = readOnly;
        contentDir = Path.Combine(cacheRoot, "content");
        shadowDir = Path.Combine(cacheRoot, "local-metadata");
        Directory.CreateDirectory(contentDir);
        Directory.CreateDirectory(shadowDir);
        store = new OfflineStore(pinsPath, Path.Combine(cacheRoot, "index.json"));
        // Contents downloaded in an earlier session stay valid while size and mtime still match.
        contentStamps = store.SavedStamps().Where(s => File.Exists(ContentPath(s.Key))).ToDictionary();
        foreach (var root in store.PinnedRoots) pinStates[root] = new PinState.Syncing(0, 0);

        var ticks = 0;
        maintenance = new Timer(_ =>
        {
            store.Save();
            ProbeIfOffline();
            // Pinned folders are checked against the server at start and every ten minutes.
            if (ticks++ % 120 == 0) SyncAllPinned();
        }, null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
    }

    public void Dispose() => maintenance.Dispose();

    void NoteReachable()
    {
        bool was;
        lock (gate)
        {
            was = offline;
            offline = false;
        }
        if (!was) return;
        OnReachable?.Invoke();
        SyncAllPinned();
    }

    /// While offline, requests are answered from disk without waiting on the network; this checks
    /// in the background whether the server is back.
    void ProbeIfOffline()
    {
        lock (gate)
        {
            if (!offline || probing) return;
            probing = true;
        }
        Background(() =>
        {
            try
            {
                var items = Backend.List("/");
                lock (gate) listings["/"] = new Listing(ByName(items), DateTime.UtcNow);
                NoteReachable();
            }
            finally { lock (gate) probing = false; }
        });
    }

    /// The last known listing of `path` (memory first, then disk), used while offline.
    Dictionary<string, RemoteItem>? OfflineListing(string path)
    {
        lock (gate) if (listings.TryGetValue(path, out var l)) return l.Items;
        if (store.SavedListing(path) is not { } saved) return null;
        var items = ByName(saved);
        lock (gate) listings[path] = new Listing(items, DateTime.UtcNow);
        return items;
    }

    static bool IsConnectivity(Exception e) => e is RemoteException { Kind: RemoteErrorKind.Network };

    // Explorer and Finder metadata kept local

    public static bool IsLocalOnly(string path)
    {
        var name = RemotePath.Name(path);
        return name.StartsWith("._", StringComparison.Ordinal) || name == ".DS_Store"
            || name.Equals("desktop.ini", StringComparison.OrdinalIgnoreCase)
            || name.Equals("Thumbs.db", StringComparison.OrdinalIgnoreCase);
    }

    string ShadowPath(string path) => Path.Combine(shadowDir, Key(path));
    string ContentPath(string path) => Path.Combine(contentDir, Key(path));

    // Metadata

    public List<RemoteItem> List(string path) => [.. Items(path).Values];

    /// The listing of a folder by name. Callers must not change it.
    Dictionary<string, RemoteItem> Items(string path)
    {
        path = RemotePath.Normalize(path);
        lock (gate)
        {
            if (listings.TryGetValue(path, out var l))
            {
                var age = DateTime.UtcNow - l.Fetched;
                // Serve stale listings while refreshing, unless they are very old (e.g. after a long idle).
                if (age < listingTTL * 10)
                {
                    if (age >= listingTTL && refreshing.Add(path))
                        Background(() =>
                        {
                            try { FetchListing(path, prefetchChildren: false); }
                            finally { lock (gate) refreshing.Remove(path); }
                        });
                    return l.Items;
                }
            }
        }
        return FetchListing(path, prefetchChildren: true);
    }

    /// Fetches one listing; concurrent callers for the same folder share the request.
    Dictionary<string, RemoteItem> FetchListing(string path, bool prefetchChildren)
    {
        ManualResetEventSlim? other;
        var mine = new ManualResetEventSlim();
        lock (gate) if (!inFlight.TryGetValue(path, out other)) inFlight[path] = mine;
        if (other != null)
        {
            other.Wait();
            lock (gate) return listings.TryGetValue(path, out var l) ? l.Items : throw RemoteException.NotFound(path);
        }
        try { return FetchListingNow(path, prefetchChildren); }
        finally
        {
            lock (gate) inFlight.Remove(path);
            mine.Set();
        }
    }

    Dictionary<string, RemoteItem> FetchListingNow(string path, bool prefetchChildren)
    {
        if (IsOffline) return OfflineListing(path) ?? throw RemoteException.Network("the server is unreachable");

        Dictionary<string, RemoteItem> items;
        for (var attempt = 0; ; attempt++)
        {
            int version;
            lock (gate) version = versions.GetValueOrDefault(path);
            var started = DateTime.UtcNow;
            List<RemoteItem> fetched;
            try { fetched = Backend.List(path); }
            catch (RemoteException e)
            {
                if (e.Kind == RemoteErrorKind.NotFound) lock (gate) listings.Remove(path);
                if (e.Kind == RemoteErrorKind.Network)
                {
                    lock (gate) offline = true;
                    // Without a connection the last known listing beats an error: Explorer keeps
                    // showing the folder and pinned files stay readable.
                    if (OfflineListing(path) is { } cached) return cached;
                }
                throw;
            }
            NoteReachable();
            Stats.Shared.Record("backend.list", started);
            items = ByName(fetched);
            lock (gate)
            {
                // A local create/delete/rename landed while the request was out: its result may predate
                // that change and would resurrect deleted files. Fetch again.
                if (versions.GetValueOrDefault(path) != version && attempt < 2) continue;
                listings[path] = new Listing(items, DateTime.UtcNow);
            }
            break;
        }
        store.RecordListing(path, items.Values);
        if (prefetchChildren)
        {
            List<string> toPrefetch;
            lock (gate)
                toPrefetch = items.Values.Where(i => i.IsDirectory).Select(i => RemotePath.Join(path, i.Name))
                    .Where(c => !listings.ContainsKey(c) && !inFlight.ContainsKey(c)).Take(64).ToList();
            // One level ahead only: prefetched folders do not prefetch their own children.
            foreach (var child in toPrefetch) Background(() => FetchListing(child, prefetchChildren: false));
        }
        return items;
    }

    public RemoteItem Stat(string path)
    {
        path = RemotePath.Normalize(path);
        if (path == "/") return RemoteItem.Folder("/");
        var name = RemotePath.Name(path);
        if (IsLocalOnly(path))
        {
            var f = new FileInfo(ShadowPath(path));
            return f.Exists ? new RemoteItem(name, false, (ulong)f.Length, f.LastWriteTimeUtc) : throw RemoteException.NotFound(path);
        }
        // One listing of the parent answers every sibling lookup Explorer makes afterwards.
        var parent = RemotePath.Parent(path);
        if (Items(parent).TryGetValue(name, out var item)) return item;
        // "Not found" from a stale listing would hide files created on the server, so confirm
        // misses against a fresh listing.
        TimeSpan age;
        lock (gate) age = listings.TryGetValue(parent, out var l) ? DateTime.UtcNow - l.Fetched : TimeSpan.MaxValue;
        if (age >= listingTTL && FetchListing(parent, prefetchChildren: false).TryGetValue(name, out item)) return item;
        throw RemoteException.NotFound(path);
    }

    public void Invalidate(string path)
    {
        path = RemotePath.Normalize(path);
        lock (gate)
        {
            listings.Remove(path);
            versions[path] = versions.GetValueOrDefault(path) + 1;
        }
    }

    void PatchParent(string path, RemoteItem? item)
    {
        var parent = RemotePath.Parent(path);
        var name = RemotePath.Name(path);
        lock (gate)
        {
            versions[parent] = versions.GetValueOrDefault(parent) + 1;
            if (!listings.TryGetValue(parent, out var l)) return;
            var items = new Dictionary<string, RemoteItem>(l.Items);
            if (item == null) items.Remove(name);
            else items[name] = item;
            listings[parent] = l with { Items = items };
        }
    }

    // Content

    static string Key(string path) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(RemotePath.Normalize(path))));

    object PathLock(string path)
    {
        lock (gate)
        {
            if (!pathLocks.TryGetValue(path, out var l)) pathLocks[path] = l = new object();
            return l;
        }
    }

    /// Local file holding the current remote contents, downloading only when the cached copy is stale.
    public string LocalCopy(string path)
    {
        path = RemotePath.Normalize(path);
        if (IsLocalOnly(path))
        {
            var shadow = ShadowPath(path);
            return File.Exists(shadow) ? shadow : throw RemoteException.NotFound(path);
        }
        var item = Stat(path);
        if (item.IsDirectory) throw RemoteException.Unsupported("cannot read a folder as a file");
        var target = ContentPath(path);
        lock (PathLock(path))
        {
            bool fresh;
            lock (gate) fresh = contentStamps.TryGetValue(path, out var st) && st.Size == item.Size && st.Modified == item.Modified;
            if (fresh && File.Exists(target)) return target;
            if (IsOffline) throw RemoteException.Network($"the server is unreachable and {path} is not kept offline");
            NoteMiss(path);
            var partial = target + ".part";
            var started = DateTime.UtcNow;
            lock (gate) downloading[path] = downloading.GetValueOrDefault(path) + 1;
            try { Backend.Download(path, partial); }
            catch (Exception e)
            {
                if (IsConnectivity(e)) lock (gate) offline = true;
                throw;
            }
            finally
            {
                Stats.Shared.Record("backend.download", started);
                lock (gate) if ((downloading[path] -= 1) == 0) downloading.Remove(path);
            }
            File.Move(partial, target, overwrite: true);
            lock (gate) contentStamps[path] = new Stamp(item.Size, item.Modified);
            store.RecordStamp(path, item.Size, item.Modified);
            return target;
        }
    }

    /// Uploads `file` as the new contents of `path`, then applies `modified` when given. The file is
    /// moved into the content cache.
    public void Write(string path, string file, DateTime? modified = null)
    {
        path = RemotePath.Normalize(path);
        if (IsLocalOnly(path))
        {
            File.Move(file, ShadowPath(path), overwrite: true);
            return;
        }
        EnsureWritable(path);
        lock (PathLock(path))
        {
            var started = DateTime.UtcNow;
            try { Backend.Upload(file, path); }
            finally { Stats.Shared.Record("backend.upload", started); }

            var size = (ulong)new FileInfo(file).Length;
            RemoteItem item;
            if (Backend.CanSetModificationTime)
            {
                // Setting the mtime ourselves tells us the exact result, so no stat is needed to keep
                // the cached copy valid. Whole seconds match what servers store.
                var stamp = Util.WholeSeconds(modified ?? DateTime.UtcNow);
                Backend.SetModified(path, stamp);
                item = new RemoteItem(RemotePath.Name(path), false, size, stamp);
            }
            else
            {
                // One stat for the authoritative mtime keeps the cached copy valid without re-listing the folder.
                try { item = Backend.Stat(path); }
                catch (RemoteException) { item = new RemoteItem(RemotePath.Name(path), false, size, DateTime.UtcNow); }
            }
            PatchParent(path, item);
            DropBlocks(path);

            try
            {
                File.Move(file, ContentPath(path), overwrite: true);
                lock (gate) contentStamps[path] = new Stamp(item.Size, item.Modified);
                store.RecordStamp(path, item.Size, item.Modified);
            }
            catch (IOException) { }
        }
    }

    // Namespace changes

    void EnsureWritable(string path)
    {
        if (ReadOnly) throw RemoteException.PermissionDenied(path);
    }

    public void MakeDirectory(string path)
    {
        EnsureWritable(path);
        Backend.MakeDirectory(RemotePath.Normalize(path));
        PatchParent(path, RemoteItem.Folder(RemotePath.Name(path)));
    }

    /// Deletes a file, or a folder together with everything inside it.
    public void Remove(string path)
    {
        path = RemotePath.Normalize(path);
        if (IsLocalOnly(path))
        {
            Util.TryDelete(ShadowPath(path));
            return;
        }
        EnsureWritable(path);
        if (Stat(path).IsDirectory)
        {
            try { Backend.RemoveDirectory(path); }
            catch (RemoteException e) when (e.Kind == RemoteErrorKind.NotEmpty)
            {
                Invalidate(path);
                foreach (var child in List(path)) Remove(RemotePath.Join(path, child.Name));
                Backend.RemoveDirectory(path);
            }
            Invalidate(path);
        }
        else
        {
            Backend.RemoveFile(path);
        }
        PatchParent(path, null);
    }

    public void Move(string from, string to)
    {
        from = RemotePath.Normalize(from);
        to = RemotePath.Normalize(to);
        if (IsLocalOnly(from) || IsLocalOnly(to))
        {
            if (File.Exists(ShadowPath(from))) File.Move(ShadowPath(from), ShadowPath(to), overwrite: true);
            return;
        }
        EnsureWritable(to);
        Backend.Move(from, to);
        Invalidate(RemotePath.Parent(from));
        Invalidate(RemotePath.Parent(to));
        Invalidate(from);
    }

    // Sibling prefetch

    /// Small files read one after another in a folder (a build reading sources, a viewer stepping
    /// through photos) are fetched in parallel ahead of the reader.
    const ulong PrefetchMaxSize = 256 << 10;
    readonly Dictionary<string, (int Count, DateTime Last)> recentMisses = [];
    readonly HashSet<string> prefetching = [];

    void NoteMiss(string path)
    {
        var dir = RemotePath.Parent(path);
        List<string> uncached;
        lock (gate)
        {
            var (count, last) = recentMisses.GetValueOrDefault(dir, (0, DateTime.MinValue));
            count = DateTime.UtcNow - last < TimeSpan.FromSeconds(2) ? count + 1 : 1;
            recentMisses[dir] = (count, DateTime.UtcNow);
            if (count != 2 || !prefetching.Add(dir)) return;
            var candidates = SmallFiles(dir);
            if (listings.TryGetValue(RemotePath.Parent(dir), out var parentListing))
            {
                // Readers that go through a tree in path order reach the next folders soon.
                var name = RemotePath.Name(dir);
                foreach (var folder in parentListing.Items.Values
                             .Where(i => i.IsDirectory && string.CompareOrdinal(i.Name, name) > 0)
                             .Select(i => i.Name).Order(StringComparer.Ordinal).Take(2))
                    candidates.AddRange(SmallFiles(RemotePath.Join(RemotePath.Parent(dir), folder)));
            }
            uncached = candidates.Where(c => c != path && !contentStamps.ContainsKey(c)).Take(96).ToList();
        }
        var work = uncached.Select(sibling => Background(() => LocalCopy(sibling))).ToArray();
        Task.WhenAll(work).ContinueWith(_ => { lock (gate) prefetching.Remove(dir); });
    }

    /// Small files directly in `dir` from its cached listing, in name order. Call with the gate held.
    List<string> SmallFiles(string dir) => listings.TryGetValue(dir, out var l)
        ? l.Items.Values.Where(i => !i.IsDirectory && i.Size <= PrefetchMaxSize)
            .Select(i => RemotePath.Join(dir, i.Name)).Order(StringComparer.Ordinal).ToList()
        : [];

    // Partial reads

    /// Files above this size are read block by block when the backend supports ranges.
    const ulong BlockThreshold = 8 << 20;
    const ulong BlockSize = 1 << 20;

    sealed class BlockFile(string data, ulong size, DateTime modified)
    {
        public readonly string Data = data;
        public readonly ulong Size = size;
        public readonly DateTime Modified = modified;
        public readonly HashSet<ulong> Present = [];
    }
    readonly Dictionary<string, BlockFile> blockFiles = [];

    void DropBlocks(string path)
    {
        BlockFile? bf;
        lock (gate) blockFiles.Remove(path, out bf);
        if (bf != null) Util.TryDelete(bf.Data);
    }

    /// Reads part of a file. Small files are fetched whole and cached; large ones only fetch the
    /// 1 MB blocks that are actually read (archives, logs, media).
    public byte[] Read(string path, ulong offset, int length)
    {
        path = RemotePath.Normalize(path);
        var item = Stat(path);
        if (item.IsDirectory) throw RemoteException.Unsupported("cannot read a folder as a file");

        bool haveWhole;
        lock (gate) haveWhole = contentStamps.TryGetValue(path, out var st) && st.Size == item.Size && st.Modified == item.Modified;
        if (haveWhole || IsLocalOnly(path) || item.Size <= BlockThreshold || !Backend.SupportsRangeReads)
            return Pread(LocalCopy(path), offset, length);
        if (offset >= item.Size || length <= 0) return [];

        BlockFile file;
        lock (gate)
        {
            if (!blockFiles.TryGetValue(path, out var bf) || bf.Size != item.Size || bf.Modified != item.Modified)
            {
                if (bf != null) Util.TryDelete(bf.Data);
                var data = ContentPath(path) + ".blocks";
                File.Create(data).Dispose();
                blockFiles[path] = bf = new BlockFile(data, item.Size, item.Modified);
            }
            file = bf;
        }

        var end = Math.Min(item.Size, offset + (ulong)length);
        lock (file)
        {
            for (var block = offset / BlockSize; block <= (end - 1) / BlockSize; block++)
            {
                if (file.Present.Contains(block)) continue;
                var start = block * BlockSize;
                var started = DateTime.UtcNow;
                var data = Backend.Read(path, start, (int)Math.Min(BlockSize, item.Size - start));
                Stats.Shared.Record("backend.read", started);
                using (var h = File.OpenHandle(file.Data, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                    RandomAccess.Write(h, data, (long)start);
                file.Present.Add(block);
            }
        }
        return Pread(file.Data, offset, (int)(end - offset));
    }

    public static byte[] Pread(string file, ulong offset, int length)
    {
        using var h = File.OpenHandle(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var size = RandomAccess.GetLength(h);
        if ((long)offset >= size || length <= 0) return [];
        var buf = new byte[Math.Min(length, size - (long)offset)];
        var n = 0;
        while (n < buf.Length)
        {
            var r = RandomAccess.Read(h, buf.AsSpan(n), (long)offset + n);
            if (r == 0) break;
            n += r;
        }
        return n == buf.Length ? buf : buf[..n];
    }

    // Times

    /// Sets the modification time on the server and keeps the cached copy valid under it.
    public void SetModified(string path, DateTime modified)
    {
        path = RemotePath.Normalize(path);
        if (IsLocalOnly(path) || !Backend.CanSetModificationTime) return;
        EnsureWritable(path);
        modified = Util.WholeSeconds(modified);
        Backend.SetModified(path, modified);
        PatchParent(path, Stat(path) with { Modified = modified });
        Stamp? updated = null;
        lock (gate)
        {
            if (contentStamps.TryGetValue(path, out var st))
            {
                // The bytes did not change, so the cached copy stays valid under the new mtime.
                updated = contentStamps[path] = st with { Modified = modified };
            }
        }
        if (updated is { } u) store.RecordStamp(path, u.Size, u.Modified);
    }

    /// Forgets every folder listing so the next access reads fresh ones (e.g. after a git pull on the server).
    public void RefreshFolders()
    {
        lock (gate)
        {
            listings.Clear();
            offline = false; // asked for fresh folders: try the server again now
        }
    }

    /// After sleep or a network change: reconnect lazily and re-read folders.
    public void NetworkChanged()
    {
        Backend.NetworkChanged();
        RefreshFolders();
        // Changes made on the server while this PC was away reach pinned folders now.
        SyncAllPinned();
    }

    /// Writes what must outlive this session; called before unmounting.
    public void SaveState() => store.Save();

    // Offline folders

    public Dictionary<string, PinState> PinnedFolders
    {
        get { lock (gate) return new(pinStates); }
    }

    /// Paths with a download in progress.
    public List<string> ActiveDownloads
    {
        get { lock (gate) return [.. downloading.Keys]; }
    }

    public bool IsPinned(string path) => store.PinnedRoot(RemotePath.Normalize(path)) != null;

    /// Keeps a folder (or a single file) and everything inside it downloaded, and in step with the server.
    public void Pin(string path)
    {
        path = RemotePath.Normalize(path);
        store.SetPinned(path, true);
        lock (gate)
        {
            foreach (var inside in pinStates.Keys.Where(k => RemotePath.IsInside(k, path)).ToList()) pinStates.Remove(inside);
            pinStates[path] = new PinState.Syncing(0, 0);
        }
        Background(() => SyncPinned(path));
    }

    /// Stops keeping a folder offline. Its files stay cached until evicted or replaced.
    public void Unpin(string path)
    {
        path = RemotePath.Normalize(path);
        store.SetPinned(path, false);
        lock (gate) pinStates.Remove(path);
    }

    /// Frees the disk space used by cached copies under `path`. Pinned files are kept.
    public int Evict(string path)
    {
        path = RemotePath.Normalize(path);
        bool Under(string p) => p == path || RemotePath.IsInside(p, path);
        List<string> victims, partial;
        lock (gate)
        {
            victims = contentStamps.Keys.Where(p => Under(p) && !downloading.ContainsKey(p)).ToList();
            partial = blockFiles.Keys.Where(Under).ToList();
        }
        var removable = victims.Where(p => store.PinnedRoot(p) == null).ToList();
        lock (gate) foreach (var p in removable) contentStamps.Remove(p);
        store.RemoveStamps(removable);
        foreach (var p in removable) Util.TryDelete(ContentPath(p));
        foreach (var p in removable.Concat(partial)) DropBlocks(p);
        return removable.Count;
    }

    void SyncAllPinned()
    {
        foreach (var root in store.PinnedRoots)
        {
            bool busy;
            lock (gate) busy = pinStates.GetValueOrDefault(root) is PinState.Syncing { Total: > 0 };
            if (!busy) Background(() => SyncPinned(root));
        }
    }

    /// Re-pins everything after the connection comes back, and checks pinned folders again.
    public void ResyncPinned()
    {
        lock (gate) offline = false;
        SyncAllPinned();
    }

    /// Walks a pinned folder with fresh listings and downloads every file that is missing or changed.
    void SyncPinned(string root)
    {
        if (store.PinnedRoot(root) != root) return;
        var files = new List<string>();
        var folders = new List<string> { root };
        try
        {
            for (var ancestor = root; ancestor != "/";)
            {
                ancestor = RemotePath.Parent(ancestor);
                FetchListing(ancestor, prefetchChildren: false);
            }
            if (!Stat(root).IsDirectory)
            {
                files.Add(root);
                folders.Clear();
            }
            while (folders.Count > 0)
            {
                var folder = folders[^1];
                folders.RemoveAt(folders.Count - 1);
                Invalidate(folder);
                foreach (var item in FetchListing(folder, prefetchChildren: false).Values)
                {
                    var child = RemotePath.Join(folder, item.Name);
                    if (item.IsDirectory) folders.Add(child);
                    else if (!IsLocalOnly(child)) files.Add(child);
                }
                SetPinState(root, new PinState.Syncing(0, files.Count));
            }
            if (IsOffline) throw RemoteException.Network("offline");
            for (var i = 0; i < files.Count; i++)
            {
                if (store.PinnedRoot(files[i]) == null) return; // unpinned meanwhile
                LocalCopy(files[i]);
                SetPinState(root, new PinState.Syncing(i + 1, files.Count));
            }
            SetPinState(root, new PinState.Synced(DateTime.UtcNow));
        }
        catch (Exception e)
        {
            SetPinState(root, new PinState.Failed(e.Message));
        }
        store.Save();
    }

    void SetPinState(string root, PinState state)
    {
        lock (gate) if (pinStates.ContainsKey(root)) pinStates[root] = state;
    }

    // Helpers

    /// Runs work in the background; it is best effort, so its errors are dropped (callers that
    /// need the result see the same error on their own request).
    Task Background(Action work) => Task.Run(async () =>
    {
        await backgroundSlots.WaitAsync();
        try { work(); }
        catch (Exception) { }
        finally { backgroundSlots.Release(); }
    });

    static Dictionary<string, RemoteItem> ByName(IEnumerable<RemoteItem> items)
    {
        var d = new Dictionary<string, RemoteItem>();
        foreach (var i in items) d.TryAdd(i.Name, i);
        return d;
    }
}
