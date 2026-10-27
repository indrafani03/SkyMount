using System.Security.Cryptography;
using System.Text;
using SkyMount;
using SkyMount.Core;

// One instance per data folder (normally one per user); SKYMOUNT_HOME starts a separate one.
var instanceName = @"Local\SkyMount." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(AppPaths.Root.ToLowerInvariant())))[..12];
var showName = instanceName + ".ShowConnections";
var quitName = instanceName + ".Quit";

// `SkyMount.exe --quit` (run by the installer) asks the running app to upload pending changes,
// unmount and exit, and waits until it has.
if (args is ["--quit"])
{
    try
    {
        if (!Mutex.TryOpenExisting(instanceName, out var running)) return;
        using (running)
        {
            EventWaitHandle.OpenExisting(quitName).Set();
            try { running.WaitOne(TimeSpan.FromMinutes(10)); }
            catch (AbandonedMutexException) { } // what an exiting owner leaves behind
        }
    }
    catch (Exception e) when (e is UnauthorizedAccessException or WaitHandleCannotBeOpenedException) { }
    return;
}

// Starting SkyMount again shows the Connections window of the running instance.
using var single = new Mutex(true, instanceName, out var first);
using var show = new EventWaitHandle(false, EventResetMode.AutoReset, showName);
using var quit = new EventWaitHandle(false, EventResetMode.AutoReset, quitName);
if (!first)
{
    show.Set();
    return;
}

ApplicationConfiguration.Initialize();
// AppModel captures the UI thread's context while it is built and starts automatic mounts from it,
// so the Windows Forms one must be in place before the first control would install it.
SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
var app = new TrayApp(atLogin: args is ["--background"]);
var ui = SynchronizationContext.Current!;
new Thread(() =>
{
    while (true)
    {
        if (WaitHandle.WaitAny([show, quit]) == 0) ui.Post(_ => app.ShowConnections(), null);
        else ui.Post(async _ => await app.Quit(), null);
    }
}) { IsBackground = true }.Start();
Application.Run(app);

namespace SkyMount
{
    /// Appends to %LOCALAPPDATA%\SkyMount\skymount.log, keeping one older file once it passes 5 MB.
    static class Log
    {
        static readonly string FilePath = Path.Combine(AppPaths.Root, "skymount.log");
        static readonly object Gate = new();

        public static void Write(string message)
        {
            lock (Gate)
            {
                try
                {
                    Directory.CreateDirectory(AppPaths.Root);
                    if (File.Exists(FilePath) && new FileInfo(FilePath).Length > 5 << 20) File.Move(FilePath, FilePath + ".old", overwrite: true);
                    File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
                }
                catch (IOException) { }
            }
        }
    }
}
