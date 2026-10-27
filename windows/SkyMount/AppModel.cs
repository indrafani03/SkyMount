using System.Diagnostics;
using System.Net.NetworkInformation;
using Microsoft.Win32;
using SkyMount.Core;

namespace SkyMount;

enum MountPhase { Idle, Working, Mounted, Failed }

/// `Detail` is the drive while mounted, what is happening while working, and the error after a failure.
sealed record MountStatus(MountPhase Phase, string Detail = "")
{
    public static readonly MountStatus Idle = new(MountPhase.Idle);

    public string Label => Phase switch
    {
        MountPhase.Idle => "Not mounted",
        MountPhase.Working => Detail,
        MountPhase.Mounted => $"Mounted on {Detail}",
        _ => "Failed",
    };
}

/// Connections, mounts and their activity. Lives on the UI thread; slow work runs on the thread pool
/// and every change is announced through `Changed`.
sealed class AppModel
{
    public List<ConnectionConfig> Connections { get; } = ConnectionStore.Load();
    /// Offline folders, uploads and downloads per mounted connection.
    public Dictionary<Guid, VolumeActivity> Activity { get; private set; } = [];
    /// True while anything uploads, downloads or syncs an offline folder, and for two seconds after,
    /// so a run of small files does not make the tray icon flicker.
    public bool IsTransferring { get; private set; }
    public event Action? Changed;

    readonly Dictionary<Guid, MountStatus> status = [];
    readonly Dictionary<Guid, VolumeMount> volumes = [];
    /// Automatic mounts that failed for lack of a network (Wi-Fi not up yet right after login):
    /// how many tries so far, and the scheduled next one.
    readonly Dictionary<Guid, int> autoMountTries = [];
    readonly Dictionary<Guid, CancellationTokenSource> autoMountRetries = [];
    readonly System.Windows.Forms.Timer activityTimer = new() { Interval = 1000 };
    readonly System.Windows.Forms.Timer networkSettled = new() { Interval = 2000 };
    DateTime lastTransfer = DateTime.MinValue;
    bool refreshing;

    public AppModel()
    {
        var ui = SynchronizationContext.Current!;
        activityTimer.Tick += async (_, _) => await RefreshActivity();
        activityTimer.Start();
        // Connections opened before sleep or on another network are dead; reconnect on next use.
        // Address changes come in bursts, so act once they settle.
        NetworkChange.NetworkAddressChanged += (_, _) => ui.Post(_ =>
        {
            networkSettled.Stop();
            networkSettled.Start();
        }, null);
        networkSettled.Tick += (_, _) =>
        {
            networkSettled.Stop();
            NetworkChanged();
        };
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == PowerModes.Resume) ui.Post(_ => NetworkChanged(), null);
        };
        // Rewrite the login item so it points at this copy (which may have moved) with today's arguments.
        if (OpensAtLogin) OpensAtLogin = true;
        foreach (var c in Connections.Where(c => c.AutoMount)) Mount(c.Id, automatic: true);
    }

    public MountStatus Status(Guid id) => status.GetValueOrDefault(id, MountStatus.Idle);
    public bool AnyMounted => status.Values.Any(s => s.Phase == MountPhase.Mounted);
    public VolumeMount? Volume(Guid id) => volumes.GetValueOrDefault(id);

    void Set(Guid id, MountStatus s)
    {
        status[id] = s;
        Changed?.Invoke();
    }

    async Task RefreshActivity()
    {
        if (refreshing) return;
        refreshing = true;
        var mounted = volumes.ToList();
        var snapshot = await Task.Run(() => mounted.ToDictionary(v => v.Key, v => v.Value.Activity));
        refreshing = false;
        Activity = snapshot;
        var busy = snapshot.Values.Any(a => a.Uploads.Count > 0 || a.Downloads.Count > 0 || a.Pinned.Values.Any(p => p is PinState.Syncing));
        if (busy) lastTransfer = DateTime.UtcNow;
        IsTransferring = busy || DateTime.UtcNow - lastTransfer < TimeSpan.FromSeconds(2);
        DropDisconnectedDrives();
        Changed?.Invoke();
    }

    /// Drives disconnected in Explorer disappear without telling us; release their volumes.
    void DropDisconnectedDrives()
    {
        foreach (var (id, volume) in volumes.Where(v => !v.Value.IsMounted).ToList())
        {
            volumes.Remove(id);
            Task.Run(volume.Unmount);
            Set(id, MountStatus.Idle);
        }
    }

    void NetworkChanged()
    {
        if (!NetworkInterface.GetIsNetworkAvailable()) return;
        var mounted = volumes.Values.ToList();
        Task.Run(() => mounted.ForEach(v => v.NetworkChanged()));
        // The network just came up: automatic mounts waiting for it go now.
        foreach (var id in autoMountTries.Keys.ToList()) Mount(id, automatic: true);
    }

    void ScheduleAutoMountRetry(Guid id)
    {
        var tries = autoMountTries[id] = autoMountTries.GetValueOrDefault(id) + 1;
        var delay = TimeSpan.FromSeconds(Math.Min(300, 10 * Math.Pow(2, Math.Min(tries, 6) - 1))); // 10 s, 20 s, 40 s ... 5 min
        if (autoMountRetries.Remove(id, out var old)) old.Cancel();
        var cts = autoMountRetries[id] = new CancellationTokenSource();
        Task.Delay(delay, cts.Token).ContinueWith(t =>
        {
            if (!t.IsCanceled) Mount(id, automatic: true);
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    void StopAutoMountRetry(Guid id)
    {
        if (autoMountRetries.Remove(id, out var cts)) cts.Cancel();
        autoMountTries.Remove(id);
    }

    // Login item

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public bool OpensAtLogin
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("SkyMount") != null;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue("SkyMount", $"\"{Environment.ProcessPath}\" --background");
            else key.DeleteValue("SkyMount", throwOnMissingValue: false);
        }
    }

    // Editing

    /// Stores a copy, so later edits to `config` do not change the saved connection.
    public void Upsert(ConnectionConfig config)
    {
        var i = Connections.FindIndex(c => c.Id == config.Id);
        if (i >= 0) Connections[i] = config with { };
        else Connections.Add(config with { });
        Persist();
    }

    public void Delete(Guid id)
    {
        Unmount(id);
        if (Connections.Find(c => c.Id == id) is { } c)
            foreach (var field in Enum.GetValues<SecretField>()) c.SetSecret(field, null);
        Connections.RemoveAll(c => c.Id == id);
        status.Remove(id);
        Persist();
    }

    void Persist()
    {
        try { ConnectionStore.Save(Connections); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show($"Could not save connections: {e.Message}", "SkyMount", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        Changed?.Invoke();
    }

    void StoreFingerprint(string fingerprint, Guid id)
    {
        if (Connections.Find(c => c.Id == id) is { } c) Upsert(c with { SftpHostFingerprint = fingerprint });
    }

    public void ResetHostKey(Guid id)
    {
        if (Connections.Find(c => c.Id == id) is { } c) Upsert(c with { SftpHostFingerprint = null });
    }

    // Mounting

    public void Toggle(Guid id)
    {
        if (Status(id).Phase == MountPhase.Mounted) Unmount(id);
        else Mount(id);
    }

    /// `automatic` mounts (at launch) are retried while the server cannot be reached.
    public async void Mount(Guid id, bool automatic = false)
    {
        if (Connections.Find(c => c.Id == id) is not { } config) return;
        if (Status(id).Phase is MountPhase.Working or MountPhase.Mounted) return;
        if (!automatic) StopAutoMountRetry(id);
        if (config.ValidationProblem() is { } problem)
        {
            Set(id, new(MountPhase.Failed, problem));
            return;
        }
        Set(id, new(MountPhase.Working, "Connecting…"));
        var ui = SynchronizationContext.Current!;
        try
        {
            var volume = await Task.Run(() =>
            {
                var backend = BackendFactory.Make(config, fp => ui.Post(_ => StoreFingerprint(fp, id), null));
                var v = new VolumeMount(config.DisplayName, backend, AppPaths.Cache(id), AppPaths.Pending(id),
                    TimeSpan.FromSeconds(config.ListingTTL), config.ReadOnly, AppPaths.Pins(id),
                    config.DriveLetter is [var letter] ? letter : null);
                v.Mount(m => Log.Write($"{config.DisplayName}: {m}"));
                return v;
            });
            volumes[id] = volume;
            StopAutoMountRetry(id);
            Set(id, new(MountPhase.Mounted, volume.MountPoint!));
        }
        catch (RemoteException e) when (automatic && config.AutoMount && e.Kind == RemoteErrorKind.Network)
        {
            Set(id, new(MountPhase.Failed, $"Waiting for the network: {e.Message}"));
            ScheduleAutoMountRetry(id);
        }
        catch (Exception e)
        {
            Log.Write($"{config.DisplayName}: mount failed: {e}");
            Set(id, new(MountPhase.Failed, e.Message));
            if (automatic) StopAutoMountRetry(id);
        }
    }

    public async void Unmount(Guid id)
    {
        StopAutoMountRetry(id);
        if (!volumes.Remove(id, out var volume))
        {
            if (Status(id).Phase == MountPhase.Failed) Set(id, MountStatus.Idle);
            return;
        }
        Set(id, new(MountPhase.Working, "Uploading changes and unmounting…"));
        await Task.Run(volume.Unmount);
        Set(id, MountStatus.Idle);
    }

    /// Uploads everything still pending and unmounts every drive; used when quitting.
    public Task UnmountAll()
    {
        var all = volumes.Values.ToList();
        volumes.Clear();
        return Task.Run(() => Parallel.ForEach(all, v => v.Unmount()));
    }

    // Folders

    /// Re-reads folders on next access, for changes made on the server (a git pull, a deploy).
    public void RefreshFolders(Guid id) => Volume(id)?.RefreshFolders();

    public void OpenInExplorer(Guid id)
    {
        if (Volume(id)?.MountPoint is { } drive) Process.Start("explorer.exe", drive + "\\");
    }

    public void KeepOffline(Guid id, string serverPath) => Volume(id)?.Fs.Pin(serverPath);

    public void Unpin(Guid id, string serverPath) => Volume(id)?.Fs.Unpin(serverPath);

    /// Removes downloaded copies under a folder; returns how many files were removed.
    public Task<int> FreeUpSpace(Guid id, string serverPath) =>
        Volume(id) is { } v ? Task.Run(() => v.Fs.Evict(serverPath)) : Task.FromResult(0);

    // Checks

    /// Connects and lists the top folder without mounting. Returns a human-readable result.
    public static Task<string> Test(ConnectionConfig config) => Task.Run(() =>
    {
        var backend = BackendFactory.Make(config, _ => { });
        backend.Connect();
        var count = backend.List("/").Count;
        backend.Disconnect();
        return $"Connected. The top folder has {count} item{(count == 1 ? "" : "s")}.";
    });
}
