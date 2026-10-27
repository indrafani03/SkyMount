using SkyMount.Core;
using Smctl;

// Developer tool: mount a backend without the tray app, and self-checks.

const string usage = """
    usage: smctl local <folder> <volume-name> [drive-letter]
           smctl sftp <host> <port> <user> <private-key> <remote-root> <volume-name>
           smctl ftp <host> <port> <user> <password> <remote-root> <volume-name> tls|plain
           smctl s3 <endpoint> <region> <bucket> <access-key> <secret> path|virtual <prefix> <volume-name>
           smctl selftest
           smctl offlinetest
           smctl mounttest [<folder the server serves> sftp|ftp ...]
    """;

switch (args)
{
    case ["selftest"]:
        var ok = S3Backend.SignatureSelfTest();
        Console.WriteLine($"S3 SigV4 (AWS documented example): {(ok ? "PASS" : "FAIL")}");
        return ok ? 0 : 1;
    case ["offlinetest"]:
        return Checks.OfflineTest() ? 0 : 1;
    case ["mounttest"]:
        return Checks.MountTest(null, null) ? 0 : 1;
    case ["mounttest", var served, .. var rest] when Backend(rest) is { } make:
        return Checks.MountTest(Path.GetFullPath(served), make.Backend) ? 0 : 1;
}

if (Backend(args) is not { } spec)
{
    Console.Error.WriteLine(usage);
    return 1;
}

// Pending writes are kept per volume name so a killed smctl recovers them on the next run.
var tmp = Path.GetTempPath();
var ttl = double.TryParse(Environment.GetEnvironmentVariable("SKYMOUNT_TTL"), out var t) ? t : 15;
var volume = new VolumeMount(spec.Name, spec.Backend, Path.Combine(tmp, $"smctl-cache-{Environment.ProcessId}"),
    Path.Combine(tmp, $"smctl-pending-{spec.Name}"), TimeSpan.FromSeconds(ttl), driveLetter: spec.Drive);

var started = DateTime.UtcNow;
try
{
    var point = volume.Mount(m => Console.WriteLine($"[fs] {m}"));
    Console.WriteLine($"mounted at {point} after {(DateTime.UtcNow - started).TotalSeconds:F1} s; Ctrl+C unmounts");
}
catch (RemoteException e)
{
    Console.Error.WriteLine($"mount failed: {e.Message}");
    return 1;
}

var done = new ManualResetEventSlim();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    done.Set();
};
using var stats = Stats.Enabled ? new Timer(_ =>
{
    var table = Stats.Shared.Drain();
    if (table.Length > 0) Console.WriteLine($"---- last 10 s\n{table}");
}, null, 10_000, 10_000) : null;
done.Wait();
volume.Unmount();
Console.WriteLine("unmounted");
return 0;

static (IRemoteFileSystem Backend, string Name, char? Drive)? Backend(string[] a) => a switch
{
    ["local", var folder, var name, ..] => (new LocalFolderBackend(Path.GetFullPath(folder)), name,
        a.Length > 3 ? char.ToUpperInvariant(a[3][0]) : null),
    ["sftp", var host, var port, var user, var key, var root, var name] =>
        (new SftpBackend(new SftpSettings(host, int.Parse(port), user, root, null, key, null, null), fp => Console.WriteLine($"host key: {fp}")), name, null),
    ["ftp", var host, var port, var user, var password, var root, var name, var tls] =>
        (new FtpBackend(new FtpSettings(host, int.Parse(port), user, password, root, tls == "tls")), name, null),
    ["s3", var endpoint, var region, var bucket, var accessKey, var secret, var style, var prefix, var name] =>
        (new S3Backend(new S3Settings(new Uri(endpoint), region, bucket, accessKey, secret, style == "path", prefix)), name, null),
    _ => null,
};
