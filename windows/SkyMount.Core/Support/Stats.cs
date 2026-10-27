namespace SkyMount.Core;

/// Counters for diagnosing slow mounts; collected only when SKYMOUNT_DEBUG is set.
public sealed class Stats
{
    public static readonly Stats Shared = new();
    public static readonly bool Enabled = Environment.GetEnvironmentVariable("SKYMOUNT_DEBUG") != null;

    readonly Dictionary<string, (int Count, double Seconds)> entries = [];

    public void Record(string name, DateTime start)
    {
        if (!Enabled) return;
        var elapsed = (DateTime.UtcNow - start).TotalSeconds;
        lock (entries)
        {
            var e = entries.GetValueOrDefault(name);
            entries[name] = (e.Count + 1, e.Seconds + elapsed);
        }
    }

    /// Returns a table of counters and resets them.
    public string Drain()
    {
        List<KeyValuePair<string, (int Count, double Seconds)>> snapshot;
        lock (entries)
        {
            snapshot = [.. entries];
            entries.Clear();
        }
        return string.Join('\n', snapshot.OrderByDescending(e => e.Value.Seconds)
            .Select(e => $"{e.Key,-22} {e.Value.Count,6}  {e.Value.Seconds,8:F2}s"));
    }
}
