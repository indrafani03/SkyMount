using System.Text.Json;

namespace SkyMount.Core;

public enum UploadPhase { Waiting, Uploading, Failed }

public sealed record UploadState(UploadPhase Phase, string? Error = null);

/// Writes go to a local working copy. A file is uploaded three seconds after its last write, on a
/// flush, or before unmounting. Each dirty file has a journal entry on disk so an interrupted upload
/// is retried at the next mount. New files exist only here until their first upload, so temporary
/// files deleted before then never travel.
public sealed class WriteBack : IDisposable
{
    sealed class WorkingFile(string data, string path)
    {
        public readonly string Data = data;
        public readonly string Journal = data + ".json";
        /// The server path; renames change it.
        public volatile string Path = path;
        public bool Dirty, Uploading, Scheduled;
        /// Set once the copy is uploaded or deleted; a writer that still holds it starts a new one.
        public bool Retired;
        public int Generation, Failures;
        public DateTime Modified = DateTime.UtcNow, RetryAt = DateTime.MinValue;
        /// Client-chosen mtime to apply after the upload (a copy that keeps dates).
        public DateTime? PendingMtime;
        public string? LastError;
        public readonly object Lock = new();       // guards the bytes and the fields above
        public readonly object UploadLock = new(); // one upload at a time
    }

    readonly CachedFileSystem fs;
    readonly string workDir;
    readonly Action<string> log;
    // Lock order: UploadLock, then a file's Lock, then gate.
    readonly object gate = new();
    readonly Dictionary<string, WorkingFile> working = [];
    /// Files created here that the server has not seen yet.
    readonly HashSet<string> pendingNew = [];
    readonly Timer timer;

    public WriteBack(CachedFileSystem fs, string workDir, Action<string> log)
    {
        this.fs = fs;
        this.workDir = workDir;
        this.log = log;
        Directory.CreateDirectory(workDir);
        timer = new Timer(_ => Housekeeping(), null, 2000, 2000);
    }

    public void Dispose() => timer.Dispose();

    WorkingFile? Get(string path)
    {
        lock (gate) return working.GetValueOrDefault(path);
    }

    public bool IsPendingNew(string path)
    {
        lock (gate) return pendingNew.Contains(path);
    }

    /// Size and mtime of the working copy, which win over the server's while it exists.
    public (ulong Size, DateTime Modified)? Overlay(string path)
    {
        if (Get(path) is not { } wf) return null;
        lock (wf.Lock) return wf.Retired ? null : ((ulong)new FileInfo(wf.Data).Length, wf.PendingMtime ?? wf.Modified);
    }

    /// An item for a file only this PC has seen so far.
    public RemoteItem? PendingItem(string path) =>
        IsPendingNew(path) && Overlay(path) is { } o ? new RemoteItem(RemotePath.Name(path), false, o.Size, o.Modified) : null;

    public List<RemoteItem> PendingIn(string dir)
    {
        List<string> paths;
        lock (gate) paths = pendingNew.Where(p => RemotePath.Parent(p) == dir).ToList();
        return paths.Select(PendingItem).OfType<RemoteItem>().ToList();
    }

    // Working copies

    /// The working copy of `path`, made from the cached contents (or empty) when there is none.
    WorkingFile Open(string path, bool empty)
    {
        if (Get(path) is { } existing) return existing;
        var data = Path.Combine(workDir, Guid.NewGuid().ToString("N"));
        if (empty) File.Create(data).Dispose();
        else File.Copy(fs.LocalCopy(path), data);
        var wf = new WorkingFile(data, path);
        lock (gate)
        {
            if (working.TryGetValue(path, out var raced))
            {
                Util.TryDelete(data);
                return raced;
            }
            working[path] = wf;
            return wf;
        }
    }

    /// Reads from the working copy; null when there is none.
    public int? Read(string path, Span<byte> buffer, ulong offset)
    {
        if (Get(path) is not { } wf) return null;
        lock (wf.Lock)
        {
            if (wf.Retired) return null;
            using var h = File.OpenHandle(wf.Data, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var n = 0;
            while (n < buffer.Length)
            {
                var r = RandomAccess.Read(h, buffer[n..], (long)offset + n);
                if (r == 0) break;
                n += r;
            }
            return n;
        }
    }

    /// Writes into the working copy and returns how many bytes were written. `append` writes at the
    /// end; `constrained` (paging I/O) never grows the file.
    public int Write(string path, ReadOnlySpan<byte> data, ulong offset, bool append, bool constrained)
    {
        while (true)
        {
            var wf = Open(path, empty: false);
            lock (wf.Lock)
            {
                if (wf.Retired) continue;
                using var h = File.OpenHandle(wf.Data, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);
                var size = (ulong)RandomAccess.GetLength(h);
                if (append) offset = size;
                if (constrained)
                {
                    if (offset >= size) return 0;
                    data = data[..(int)Math.Min((ulong)data.Length, size - offset)];
                }
                RandomAccess.Write(h, data, (long)offset);
                MarkDirty(wf);
                return data.Length;
            }
        }
    }

    /// Truncates or extends. Cutting to zero needs no download of the old contents.
    public void SetSize(string path, ulong size)
    {
        while (true)
        {
            var wf = Open(path, empty: size == 0);
            lock (wf.Lock)
            {
                if (wf.Retired) continue;
                using (var h = File.OpenHandle(wf.Data, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete))
                    RandomAccess.SetLength(h, (long)size);
                MarkDirty(wf);
                return;
            }
        }
    }

    /// A new, empty file that stays local until its first upload.
    public void Create(string path)
    {
        SetSize(path, 0);
        lock (gate) pendingNew.Add(path);
    }

    /// Remembers an mtime to apply with the upload; false when the file has no pending changes.
    public bool SetModified(string path, DateTime modified)
    {
        if (Get(path) is not { } wf) return false;
        lock (wf.Lock)
        {
            if (wf.Retired || !wf.Dirty) return false;
            wf.PendingMtime = modified;
            return true;
        }
    }

    /// Call with the file's Lock held.
    void MarkDirty(WorkingFile wf)
    {
        var wasDirty = wf.Dirty;
        wf.Generation++;
        wf.Dirty = true;
        wf.Modified = DateTime.UtcNow;
        if (!wasDirty) WriteJournal(wf);
    }

    static void WriteJournal(WorkingFile wf)
    {
        try { Util.WriteAtomic(wf.Journal, JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, string> { ["path"] = wf.Path })); }
        catch (IOException) { }
    }

    void Retire(WorkingFile wf)
    {
        lock (wf.Lock)
        {
            wf.Retired = true;
            wf.Dirty = false;
        }
        Util.TryDelete(wf.Data);
        Util.TryDelete(wf.Journal);
    }

    // Uploads

    /// Uploads the working copy of `path`. Writes that land during the upload keep it dirty.
    public void Flush(string path)
    {
        if (Get(path) is not { } wf) return;
        lock (wf.UploadLock)
        {
            var snapshot = Path.Combine(workDir, "upload-" + Guid.NewGuid().ToString("N"));
            int generation;
            DateTime? mtime;
            lock (wf.Lock)
            {
                if (!wf.Dirty || wf.Retired) return;
                File.Copy(wf.Data, snapshot);
                generation = wf.Generation;
                mtime = wf.PendingMtime;
                wf.Uploading = true;
            }
            var destination = wf.Path;
            try { fs.Write(destination, snapshot, mtime); }
            catch (Exception e)
            {
                Util.TryDelete(snapshot);
                lock (wf.Lock)
                {
                    wf.Uploading = false;
                    wf.Failures++;
                    // 5 s, 10 s, 20 s ... capped at 5 minutes, so an unreachable server is not hammered.
                    wf.RetryAt = DateTime.UtcNow.AddSeconds(Math.Min(300, 5 * Math.Pow(2, Math.Min(wf.Failures, 7) - 1)));
                    wf.LastError = e.Message;
                }
                log($"upload of {destination} failed: {e.Message}");
                throw;
            }
            lock (gate) pendingNew.Remove(destination);
            lock (wf.Lock)
            {
                wf.Uploading = false;
                wf.Failures = 0;
                wf.RetryAt = DateTime.MinValue;
                wf.LastError = null;
                if (wf.Generation != generation) return;
                wf.PendingMtime = null;
                wf.Dirty = false;
                wf.Retired = true;
                lock (gate) if (working.GetValueOrDefault(wf.Path) == wf) working.Remove(wf.Path);
            }
            Util.TryDelete(wf.Data);
            Util.TryDelete(wf.Journal);
        }
    }

    void Housekeeping()
    {
        var now = DateTime.UtcNow;
        List<WorkingFile> files;
        lock (gate) files = [.. working.Values];
        foreach (var wf in files)
        {
            lock (wf.Lock)
            {
                if (!wf.Dirty || wf.Uploading || wf.Scheduled || now - wf.Modified < TimeSpan.FromSeconds(3) || now < wf.RetryAt) continue;
                wf.Scheduled = true;
            }
            Task.Run(() =>
            {
                try { Flush(wf.Path); }
                catch (Exception) { } // recorded on the file and retried later
                finally { lock (wf.Lock) wf.Scheduled = false; }
            });
        }
    }

    /// Every file with changes not yet on the server, and how its upload is going.
    public Dictionary<string, UploadState> PendingUploads()
    {
        List<WorkingFile> files;
        lock (gate) files = [.. working.Values];
        var result = new Dictionary<string, UploadState>();
        foreach (var wf in files)
            lock (wf.Lock)
                if (wf.Dirty || wf.Uploading)
                    result[wf.Path] = wf.Uploading ? new(UploadPhase.Uploading)
                        : wf.LastError != null ? new(UploadPhase.Failed, wf.LastError) : new(UploadPhase.Waiting);
        return result;
    }

    /// Ends the wait after failed uploads, so they go out on the next pass (the server is back).
    public void RetryFailedSoon()
    {
        List<WorkingFile> files;
        lock (gate) files = [.. working.Values];
        foreach (var wf in files) lock (wf.Lock) wf.RetryAt = DateTime.MinValue;
    }

    /// Uploads everything still pending; used when unmounting. Failures stay journaled for the next mount.
    public void FlushAll()
    {
        List<string> paths;
        lock (gate) paths = [.. working.Keys];
        foreach (var p in paths)
        {
            try { Flush(p); }
            catch (Exception) { }
        }
    }

    // Deletes and renames

    /// Deletes a file or folder: on the server unless it never got there, and here.
    public void Delete(string path)
    {
        if (Get(path) is not { } wf)
        {
            fs.Remove(path);
            Forget(path);
            return;
        }
        // An upload in flight finishes first, so it cannot bring the file back afterwards.
        lock (wf.UploadLock)
        {
            if (!IsPendingNew(path)) fs.Remove(path);
            Forget(path);
        }
    }

    /// Drops the working copies at `path` and under it.
    void Forget(string path)
    {
        List<WorkingFile> dropped = [];
        lock (gate)
        {
            foreach (var key in working.Keys.Where(k => k == path || RemotePath.IsInside(k, path)).ToList())
            {
                dropped.Add(working[key]);
                working.Remove(key);
            }
            pendingNew.RemoveWhere(p => p == path || RemotePath.IsInside(p, path));
        }
        dropped.ForEach(Retire);
    }

    /// Renames on the server and here. Pending writes reach the old name before the server moves the
    /// file; a file the server has never seen is simply uploaded under its new name later.
    public void Move(string from, string to)
    {
        if (Get(from) is not { } wf)
        {
            fs.Move(from, to);
            Rekey(from, to);
            return;
        }
        // Decide after any upload in flight, which may just have sent the file under its old name.
        lock (wf.UploadLock)
        {
            if (!IsPendingNew(from))
            {
                Flush(from);
                fs.Move(from, to);
            }
            Rekey(from, to);
        }
    }

    void Rekey(string from, string to)
    {
        List<WorkingFile> moved = [], replaced = [];
        lock (gate)
        {
            // Whatever was pending at the destination has just been replaced.
            if (working.Remove(to, out var old)) replaced.Add(old);
            pendingNew.Remove(to);
            foreach (var key in working.Keys.Where(k => k == from || RemotePath.IsInside(k, from)).ToList())
            {
                var wf = working[key];
                working.Remove(key);
                wf.Path = to + key[from.Length..];
                working[wf.Path] = wf;
                moved.Add(wf);
            }
            foreach (var p in pendingNew.Where(p => p == from || RemotePath.IsInside(p, from)).ToList())
            {
                pendingNew.Remove(p);
                pendingNew.Add(to + p[from.Length..]);
            }
        }
        replaced.ForEach(Retire);
        foreach (var wf in moved) lock (wf.Lock) if (wf.Dirty) WriteJournal(wf);
    }

    /// Uploads changes left behind by a session that ended before they were sent.
    /// Failed ones stay on disk for the next attempt.
    public (List<string> Uploaded, List<string> Failed) RecoverPending()
    {
        List<string> uploaded = [], failed = [];
        foreach (var journal in Directory.GetFiles(workDir, "*.json"))
        {
            var data = journal[..^5];
            string? path = null;
            try { path = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllBytes(journal))?.GetValueOrDefault("path"); }
            catch (Exception e) when (e is IOException or JsonException) { }
            if (path == null || !File.Exists(data))
            {
                Util.TryDelete(journal);
                continue;
            }
            var snapshot = Path.Combine(workDir, "upload-" + Guid.NewGuid().ToString("N"));
            try
            {
                File.Copy(data, snapshot);
                fs.Write(path, snapshot);
                Util.TryDelete(data);
                Util.TryDelete(journal);
                uploaded.Add(path);
            }
            catch (Exception e)
            {
                Util.TryDelete(snapshot);
                failed.Add(path);
                log($"could not upload saved change to {path}: {e.Message}");
            }
        }
        // Data files without a journal were never dirty or were already uploaded.
        foreach (var file in Directory.GetFiles(workDir).Where(f => !f.EndsWith(".json") && !File.Exists(f + ".json")))
            Util.TryDelete(file);
        return (uploaded, failed);
    }
}
