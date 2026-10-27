using System.Security.Cryptography;
using SkyMount.Core;

namespace Smctl;

/// A local folder whose "connection" can be cut, to test pinned folders without a server or a drive.
sealed class SwitchableBackend(string root) : IRemoteFileSystem
{
    readonly LocalFolderBackend inner = new(root);
    public volatile bool Online = true;
    public int Downloads;

    void Check()
    {
        if (!Online) throw RemoteException.Network("test: offline");
    }

    public void Connect() { Check(); inner.Connect(); }
    public void Disconnect() { }
    public List<RemoteItem> List(string path) { Check(); return inner.List(path); }
    public RemoteItem Stat(string path) { Check(); return inner.Stat(path); }
    public void Download(string path, string localFile) { Check(); Interlocked.Increment(ref Downloads); inner.Download(path, localFile); }
    public void Upload(string localFile, string path) { Check(); inner.Upload(localFile, path); }
    public void MakeDirectory(string path) { Check(); inner.MakeDirectory(path); }
    public void RemoveFile(string path) { Check(); inner.RemoveFile(path); }
    public void RemoveDirectory(string path) { Check(); inner.RemoveDirectory(path); }
    public void Move(string from, string to) { Check(); inner.Move(from, to); }
}

static class Checks
{
    static bool ok = true;

    static void Check(string name, bool condition)
    {
        Console.WriteLine($"{(condition ? "PASS" : "FAIL")}  {name}");
        ok &= condition;
    }

    static string? Read(CachedFileSystem fs, string path)
    {
        try { return File.ReadAllText(fs.LocalCopy(path)); }
        catch (Exception) { return null; }
    }

    static PinState? WaitSynced(CachedFileSystem fs, string path)
    {
        for (var i = 0; i < 100; i++)
        {
            if (fs.PinnedFolders.GetValueOrDefault(path) is PinState.Synced or PinState.Failed) break;
            Thread.Sleep(50);
        }
        return fs.PinnedFolders.GetValueOrDefault(path);
    }

    static string NewBase(string name)
    {
        var dir = Path.Combine(Path.GetTempPath(), $"smctl-{name}-{Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        return dir;
    }

    static void Seed(string server, params (string Path, string Text)[] files)
    {
        foreach (var (path, text) in files)
        {
            var full = Path.Combine(server, path);
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            File.WriteAllText(full, text);
        }
    }

    /// Pins a folder, cuts the connection and checks that pinned files stay readable, that the pin
    /// survives a new session, that eviction spares pinned files, and that server changes are picked up.
    public static bool OfflineTest()
    {
        var root = NewBase("offline");
        try
        {
            var server = Path.Combine(root, "server");
            var cache = Path.Combine(root, "cache");
            var pins = Path.Combine(root, "pins.json");
            Seed(server, ("docs/a.txt", "alpha"), ("docs/sub/b.txt", "bravo"), ("other/c.txt", "charlie"));

            var backend = new SwitchableBackend(server);
            using (var fs = new CachedFileSystem(backend, cache, TimeSpan.Zero, false, pins))
            {
                fs.Pin("/docs");
                var state = WaitSynced(fs, "/docs");
                Check($"pinned folder syncs ({state})", state is PinState.Synced);
                Check("pinned file downloaded once each", backend.Downloads == 2);
                Read(fs, "/other/c.txt");
                fs.SaveState();

                backend.Online = false;
                Check("offline: pinned file readable", Read(fs, "/docs/sub/b.txt") == "bravo");
                Check("offline: pinned folder listed", string.Join(",", fs.List("/docs").Select(i => i.Name).Order()) == "a.txt,sub");
                Check("offline: flag set", fs.IsOffline);
                backend.Online = true;
            }

            // A new session (remount) with the network down: the pin and its contents come back from disk.
            backend.Online = false;
            var downloadsBefore = backend.Downloads;
            using (var fs = new CachedFileSystem(backend, cache, TimeSpan.Zero, false, pins))
            {
                Check("remount: pin remembered", fs.IsPinned("/docs/sub/b.txt"));
                Check("remount offline: pinned file readable", Read(fs, "/docs/a.txt") == "alpha");
                Check("remount offline: unpinned folder unavailable", Throws(() => fs.List("/other")));
                Check("remount offline: nothing downloaded", backend.Downloads == downloadsBefore);
                backend.Online = true;

                Read(fs, "/other/c.txt");
                var evicted = fs.Evict("/");
                Check($"evict frees unpinned copies only ({evicted})", evicted == 1);
                backend.Online = false;
                Check("after evict: pinned file still offline", Read(fs, "/docs/a.txt") == "alpha");
                backend.Online = true;

                Seed(server, ("docs/a.txt", "alpha v2"), ("docs/sub/d.txt", "delta"));
                File.SetLastWriteTimeUtc(Path.Combine(server, "docs/a.txt"), DateTime.UtcNow.AddMinutes(1));
                fs.ResyncPinned();
                Thread.Sleep(200);
                WaitSynced(fs, "/docs");
                backend.Online = false;
                Check("resync: changed file updated", Read(fs, "/docs/a.txt") == "alpha v2");
                Check("resync: new file downloaded", Read(fs, "/docs/sub/d.txt") == "delta");
                backend.Online = true;

                fs.Unpin("/docs");
                Check("unpin: no longer pinned", !fs.IsPinned("/docs/a.txt") && fs.PinnedFolders.Count == 0);
                Check("unpin: copies become evictable", fs.Evict("/docs") == 3);
            }
        }
        finally { TryDeleteTree(root); }
        return ok;
    }

    /// Mounts a backend as a drive and works on it with ordinary file calls, then checks what reached
    /// the folder the server serves (`served`). Without a backend, a local folder stands in for the server.
    public static bool MountTest(string? served, IRemoteFileSystem? backend)
    {
        Check("names: forbidden characters round-trip",
            WindowsNames.ToLocal("10:30 a?b.") == "10：30 a？b．" && WindowsNames.ToRemote(WindowsNames.ToLocal("a<b>|\"*\\c ")) == "a<b>|\"*\\c ");

        var root = NewBase("mount");
        var server = served ?? Path.Combine(root, "server");
        foreach (var leftover in Directory.Exists(server) ? Directory.GetFileSystemEntries(server) : [])
            if (Directory.Exists(leftover)) Directory.Delete(leftover, true); else File.Delete(leftover);
        Seed(server, ("docs/a.txt", "alpha"), ("docs/old.txt", "old"));
        var big = RandomNumberGenerator.GetBytes(12 << 20); // above the 8 MB block threshold
        File.WriteAllBytes(Path.Combine(server, "big.bin"), big);
        backend ??= new LocalFolderBackend(server);

        var volume = new VolumeMount("MountTest", backend, Path.Combine(root, "cache"),
            Path.Combine(root, "pending"), TimeSpan.FromSeconds(1));
        string drive;
        try { drive = volume.Mount(m => Console.WriteLine($"  [fs] {m}")); }
        catch (RemoteException e)
        {
            Check($"mount ({e.Message})", false);
            return false;
        }
        Console.WriteLine($"  mounted at {drive}");
        string D(string path) => Path.Combine(drive + "\\", path);
        string S(string path) => Path.Combine(server, path);
        try
        {
            Check("read existing file", File.ReadAllText(D(@"docs\a.txt")) == "alpha");
            Check("listing", string.Join(",", Directory.GetFileSystemEntries(D("docs")).Select(Path.GetFileName).Order()) == "a.txt,old.txt");
            Check("case-insensitive open", File.ReadAllText(D(@"DOCS\A.TXT")) == "alpha");
            var slice = new byte[4096];
            using (var f = File.OpenRead(D("big.bin")))
            {
                f.Position = 10 << 20;
                f.ReadExactly(slice);
            }
            Check("large file: partial read matches", slice.AsSpan().SequenceEqual(big.AsSpan(10 << 20, 4096)));
            Check("large file: whole read matches", File.ReadAllBytes(D("big.bin")).AsSpan().SequenceEqual(big));

            var data = RandomNumberGenerator.GetBytes(5 << 20);
            using (var f = new FileStream(D("new.bin"), FileMode.CreateNew))
            {
                f.Write(data);
                f.Flush(flushToDisk: true); // FlushFileBuffers uploads at once
            }
            Check("write 5 MB + flush reaches server", File.Exists(S("new.bin")) && File.ReadAllBytes(S("new.bin")).AsSpan().SequenceEqual(data));

            using (var f = new FileStream(D(@"docs\a.txt"), FileMode.Append)) { f.Write("+more"u8); f.Flush(true); }
            Check("append", File.ReadAllText(S(@"docs\a.txt")) == "alpha+more");

            using (var f = new FileStream(D("new.bin"), FileMode.Open)) { f.SetLength(1000); f.Flush(true); }
            Check("truncate", new FileInfo(S("new.bin")).Length == 1000);

            if (backend.CanSetModificationTime)
            {
                var stamp = new DateTime(2020, 5, 17, 10, 30, 0, DateTimeKind.Utc);
                File.WriteAllText(D("dated.txt"), "dated");
                File.SetLastWriteTimeUtc(D("dated.txt"), stamp);
                Check("modification time kept", WaitFor(() => File.Exists(S("dated.txt")) && File.GetLastWriteTimeUtc(S("dated.txt")) == stamp));
            }

            // Safe save, as editors do: write a temporary file, then rename it over the original.
            File.WriteAllText(D(@"docs\old.txt.tmp"), "new contents");
            File.Move(D(@"docs\old.txt.tmp"), D(@"docs\old.txt"), overwrite: true);
            Check("overwriting rename", WaitFor(() => File.ReadAllText(S(@"docs\old.txt")) == "new contents" && !File.Exists(S(@"docs\old.txt.tmp"))));

            File.WriteAllText(D("Case.txt"), "case");
            File.Move(D("Case.txt"), D("CASE.txt"));
            Check("case-only rename", WaitFor(() => Directory.GetFiles(server, "*.txt").Select(Path.GetFileName).Contains("CASE.txt")));

            Directory.CreateDirectory(D(@"tree\sub"));
            File.WriteAllText(D(@"tree\sub\x.txt"), "x");
            Check("mkdir + nested file", WaitFor(() => File.Exists(S(@"tree\sub\x.txt"))));
            Directory.Delete(D("tree"), recursive: true);
            Check("recursive delete", WaitFor(() => !Directory.Exists(S("tree"))) && !Directory.Exists(D("tree")));

            File.WriteAllText(D("scratch.tmp"), "short-lived");
            File.Delete(D("scratch.tmp"));
            Thread.Sleep(4500);
            Check("temporary file deleted before upload never reaches server", !File.Exists(S("scratch.tmp")));

            File.WriteAllText(S("outside.txt"), "made on the server");
            Check("changes on the server become visible", WaitFor(() => File.Exists(D("outside.txt"))));

            File.WriteAllText(D("last.txt"), "written just before unmount");
        }
        catch (Exception e)
        {
            Check($"unexpected {e.GetType().Name}: {e.Message}", false);
        }
        finally { volume.Unmount(); }
        Check("unmount uploads pending writes", File.Exists(S("last.txt")) && File.ReadAllText(S("last.txt")) == "written just before unmount");
        Check("drive is gone after unmount", !Directory.Exists(drive + "\\"));
        TryDeleteTree(root);
        return ok;
    }

    static bool WaitFor(Func<bool> condition, int seconds = 10)
    {
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < until)
        {
            try { if (condition()) return true; }
            catch (IOException) { }
            Thread.Sleep(200);
        }
        return false;
    }

    static bool Throws(Action action)
    {
        try { action(); return false; }
        catch (Exception) { return true; }
    }

    static void TryDeleteTree(string dir)
    {
        try { Directory.Delete(dir, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
