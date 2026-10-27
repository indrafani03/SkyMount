namespace SkyMount.Core;

public static class Util
{
    /// Writes through a temporary file so a crash never leaves half a file.
    public static void WriteAtomic(string path, byte[] data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = $"{path}.{Guid.NewGuid():N}.tmp";
        File.WriteAllBytes(tmp, data);
        File.Move(tmp, path, overwrite: true);
    }

    public static void TryDelete(string file)
    {
        try { File.Delete(file); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// "~/.ssh/id_ed25519" to "C:\Users\me\.ssh\id_ed25519".
    public static string ExpandHome(string path) => path.StartsWith('~')
        ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + path[1..].Replace('/', '\\')
        : path;

    /// Whole seconds, which is what servers store.
    public static DateTime WholeSeconds(DateTime t) => new(t.Ticks - t.Ticks % TimeSpan.TicksPerSecond, DateTimeKind.Utc);
}
