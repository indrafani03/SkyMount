using Fsp;

namespace SkyMount.Core;

/// What a volume's status shows. Paths are server paths ("/docs/a.txt").
public sealed record VolumeActivity(
    Dictionary<string, PinState> Pinned, Dictionary<string, UploadState> Uploads, List<string> Downloads, bool Offline);

/// One mounted volume: backend + cache + write-back + the WinFsp drive.
public sealed class VolumeMount
{
    public string VolumeName { get; }
    public CachedFileSystem Fs { get; }
    /// The drive, like "S:", while mounted.
    public string? MountPoint { get; private set; }
    /// Changes uploaded at mount time that an earlier session could not send.
    public List<string> RecoveredUploads { get; private set; } = [];
    readonly string pendingDir;
    readonly char? driveLetter;
    WriteBack? writeBack;
    FileSystemHost? host;

    /// `pendingDir` holds unsent writes and `pinsPath` the folders kept offline; both must survive
    /// cache cleanups. Without a `driveLetter` the next free one from Z: down is used.
    public VolumeMount(string volumeName, IRemoteFileSystem backend, string cacheRoot, string pendingDir,
        TimeSpan listingTTL, bool readOnly = false, string? pinsPath = null, char? driveLetter = null)
    {
        VolumeName = Sanitize(volumeName);
        this.pendingDir = pendingDir;
        this.driveLetter = driveLetter;
        Fs = new CachedFileSystem(backend, cacheRoot, listingTTL, readOnly, pinsPath);
    }

    public VolumeActivity Activity => new(Fs.PinnedFolders, writeBack?.PendingUploads() ?? [], Fs.ActiveDownloads, Fs.IsOffline);

    /// "S:\docs\a.txt" to "/docs/a.txt"; null when the path is outside this volume.
    public string? VolumePath(string local)
    {
        if (MountPoint == null) return null;
        var full = Path.GetFullPath(local);
        if (!full.StartsWith(MountPoint, StringComparison.OrdinalIgnoreCase)) return null;
        return RemotePath.Normalize(string.Join('/',
            full[MountPoint.Length..].Split('\\', StringSplitOptions.RemoveEmptyEntries).Select(WindowsNames.ToRemote)));
    }

    /// Blocking: connects the backend and mounts. Returns the drive ("S:"). A volume that failed to
    /// mount is spent; make a new one to try again.
    public string Mount(Action<string>? log = null)
    {
        log ??= _ => { };
        WriteBack? wb = null;
        FileSystemHost? h = null;
        try
        {
            Fs.Backend.Connect();
            wb = new WriteBack(Fs, pendingDir, log);
            Fs.OnReachable = wb.RetryFailedSoon;
            RecoveredUploads = wb.RecoverPending().Uploaded;
            if (RecoveredUploads.Count > 0) log($"uploaded {RecoveredUploads.Count} change(s) left from the last session");

            h = new FileSystemHost(new WinFspFileSystem(Fs, wb, VolumeName, $@"\SkyMount\{VolumeName}", log));
            // SKYMOUNT_WINFSP_LOG=<file> logs every file system request, for diagnosing.
            var debugLog = Environment.GetEnvironmentVariable("SKYMOUNT_WINFSP_LOG") is { Length: > 0 } logFile
                && FileSystemHost.SetDebugLogFile(logFile) == FileSystemBase.STATUS_SUCCESS ? uint.MaxValue : 0;
            // Network calls block a dispatcher thread each, so allow a few more than the default.
            var status = h.MountEx(driveLetter is { } d ? $"{d}:" : null, (uint)Math.Max(8, Environment.ProcessorCount), null, false, debugLog);
            if (status != FileSystemBase.STATUS_SUCCESS)
                throw RemoteException.Protocol(driveLetter is { } l
                    ? $"could not mount on {l}: (is the drive letter in use?)"
                    : $"could not mount (WinFsp status 0x{status:X8})");
            writeBack = wb;
            host = h;
            return MountPoint = h.MountPoint().TrimEnd('\\');
        }
        catch (Exception e)
        {
            h?.Dispose();
            wb?.Dispose();
            Fs.Dispose();
            Fs.Backend.Disconnect();
            if (e is DllNotFoundException or TypeInitializationException or BadImageFormatException)
                throw RemoteException.Protocol("WinFsp is not installed. Install it from https://winfsp.dev/rel/ and try again.");
            throw;
        }
    }

    /// Unmounts, then uploads pending writes and disconnects.
    public void Unmount()
    {
        host?.Dispose();
        host = null;
        MountPoint = null;
        writeBack?.FlushAll();
        writeBack?.Dispose();
        writeBack = null;
        Fs.SaveState();
        Fs.Dispose();
        Fs.Backend.Disconnect();
    }

    /// False once the drive is gone (disconnected in Explorer).
    public bool IsMounted => MountPoint != null && Environment.GetLogicalDrives().Contains(MountPoint + "\\", StringComparer.OrdinalIgnoreCase);

    public void RefreshFolders() => Fs.RefreshFolders();

    /// After wake or a network change: drop stale connections and re-read folders.
    public void NetworkChanged() => Fs.NetworkChanged();

    /// Letters, digits, spaces and a few marks: the name doubles as the network share name.
    static string Sanitize(string name)
    {
        var cleaned = new string(name.Select(c => char.IsLetterOrDigit(c) || c is ' ' or '-' or '_' or '.' ? c : '-').ToArray()).Trim(' ', '.');
        return cleaned.Length == 0 ? "SkyMount" : cleaned;
    }
}
