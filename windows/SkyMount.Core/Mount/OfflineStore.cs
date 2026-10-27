using System.Text.Json;

namespace SkyMount.Core;

/// State of a folder kept offline ("pinned").
public abstract record PinState
{
    /// Downloading what is missing or changed: `Done` of `Total` files checked so far.
    public sealed record Syncing(int Done, int Total) : PinState;
    /// Every file is on this PC and matched the server at `Checked`.
    public sealed record Synced(DateTime Checked) : PinState;
    /// The last pass stopped early; files already downloaded are still available.
    public sealed record Failed(string Message) : PinState;
}

readonly record struct Stamp(ulong Size, DateTime Modified);

/// What must outlive a mount session:
/// - the folders the user keeps offline (outside the cache, so a cache purge never forgets them),
/// - folder listings inside those folders and the size/mtime of every cached file (in the cache), so a
///   remount reuses downloaded contents and a lost connection still shows pinned folders.
sealed class OfflineStore
{
    sealed class Index
    {
        public Dictionary<string, List<RemoteItem>> Listings { get; set; } = [];
        public Dictionary<string, Stamp> Stamps { get; set; } = [];
    }

    readonly string? pinsPath;
    readonly string indexPath;
    readonly object gate = new();
    HashSet<string> pins = [];
    Index index = new();
    bool dirty;

    public OfflineStore(string? pinsPath, string indexPath)
    {
        this.pinsPath = pinsPath;
        this.indexPath = indexPath;
        try
        {
            if (pinsPath != null) pins = [.. JsonSerializer.Deserialize<List<string>>(File.ReadAllBytes(pinsPath)) ?? []];
        }
        catch (Exception e) when (e is IOException or JsonException) { }
        try { index = JsonSerializer.Deserialize<Index>(File.ReadAllBytes(indexPath)) ?? new(); }
        catch (Exception e) when (e is IOException or JsonException) { }
    }

    // Pins

    public List<string> PinnedRoots
    {
        get { lock (gate) return [.. pins.Order(StringComparer.Ordinal)]; }
    }

    /// The pinned folder containing `path` (or `path` itself), if any.
    public string? PinnedRoot(string path)
    {
        lock (gate) return Root(path, pins);
    }

    static string? Root(string path, HashSet<string> pins)
    {
        for (var p = path; ; p = RemotePath.Parent(p))
        {
            if (pins.Contains(p)) return p;
            if (p == "/") return null;
        }
    }

    public void SetPinned(string path, bool pinned)
    {
        List<string> list;
        lock (gate)
        {
            if (pinned)
            {
                // A pinned folder inside this one is now covered by it.
                pins.RemoveWhere(p => RemotePath.IsInside(p, path));
                pins.Add(path);
            }
            else
            {
                pins.Remove(path);
                foreach (var key in index.Listings.Keys.Where(k => !KeepsListing(k, pins)).ToList()) index.Listings.Remove(key);
                dirty = true;
            }
            list = [.. pins.Order(StringComparer.Ordinal)];
        }
        if (pinsPath != null)
        {
            try { Util.WriteAtomic(pinsPath, JsonSerializer.SerializeToUtf8Bytes(list)); }
            catch (IOException) { }
        }
    }

    // Index

    /// Folders worth keeping a listing of: pinned ones, everything inside them, and the folders
    /// leading to them (without those, a pinned folder cannot be reached while offline).
    static bool KeepsListing(string path, HashSet<string> pins) =>
        Root(path, pins) != null || pins.Any(p => RemotePath.IsInside(p, path));

    public void RecordListing(string path, IEnumerable<RemoteItem> items)
    {
        lock (gate)
        {
            if (!KeepsListing(path, pins)) return;
            index.Listings[path] = [.. items];
            dirty = true;
        }
    }

    public List<RemoteItem>? SavedListing(string path)
    {
        lock (gate) return index.Listings.TryGetValue(path, out var l) ? [.. l] : null;
    }

    public Dictionary<string, Stamp> SavedStamps()
    {
        lock (gate) return new(index.Stamps);
    }

    public void RecordStamp(string path, ulong size, DateTime modified)
    {
        lock (gate)
        {
            index.Stamps[path] = new Stamp(size, modified);
            dirty = true;
        }
    }

    public void RemoveStamps(IEnumerable<string> paths)
    {
        lock (gate)
        {
            foreach (var p in paths) index.Stamps.Remove(p);
            dirty = true;
        }
    }

    /// Writes the index if it changed since the last save.
    public void Save()
    {
        byte[] data;
        lock (gate)
        {
            if (!dirty) return;
            data = JsonSerializer.SerializeToUtf8Bytes(index);
            dirty = false;
        }
        try { Util.WriteAtomic(indexPath, data); }
        catch (IOException) { }
    }
}
