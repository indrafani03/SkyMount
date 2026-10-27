using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using SkyMount.Core;

namespace SkyMount;

/// The notification-area icon and its menu. The icon gets a green dot while something is mounted
/// and a blue one while files move, so the state is visible without opening the menu.
sealed class TrayApp : ApplicationContext
{
    readonly AppModel model = new();
    readonly NotifyIcon tray;
    readonly Icon appIcon, idleIcon, mountedIcon, transferringIcon;
    /// Hidden window that owns the tray menu while it is open.
    readonly NativeWindow menuOwner = new();
    ConnectionsForm? connections;
    bool quitting;

    /// `atLogin`: started by Windows at sign-in, so it stays in the tray unless there is nothing set up yet.
    public TrayApp(bool atLogin)
    {
        using (var stream = typeof(TrayApp).Assembly.GetManifestResourceStream("SkyMount.AppIcon.ico")!)
            appIcon = new Icon(stream);
        idleIcon = new Icon(appIcon, SystemInformation.SmallIconSize);
        mountedIcon = Badge(idleIcon, Color.FromArgb(0x2E, 0xA0, 0x43));
        transferringIcon = Badge(idleIcon, Color.FromArgb(0x1F, 0x6F, 0xEB));

        menuOwner.CreateHandle(new CreateParams());
        tray = new NotifyIcon { Icon = idleIcon, Text = "SkyMount", Visible = true };
        tray.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Right) ShowMenu();
        };
        tray.MouseDoubleClick += (_, _) => ShowConnections();
        model.Changed += UpdateTray;
        // Unsent changes are journaled, but uploading them before Windows ends the session is better.
        SystemEvents.SessionEnding += (_, _) => model.UnmountAll().Wait(TimeSpan.FromSeconds(20));
        // Started by hand (Start menu, installer) the window shows, so the app visibly opens; at sign-in
        // only when the menu would be empty, to show where connections are added.
        if (!atLogin || model.Connections.Count == 0) ShowConnections();
    }

    public void ShowConnections(Guid? select = null)
    {
        if (connections == null || connections.IsDisposed) connections = new ConnectionsForm(model, appIcon);
        if (select is { } id) connections.SelectConnection(id);
        connections.Show();
        if (connections.WindowState == FormWindowState.Minimized) connections.WindowState = FormWindowState.Normal;
        connections.Activate();
    }

    void UpdateTray()
    {
        if (quitting) return;
        var icon = model.IsTransferring ? transferringIcon : model.AnyMounted ? mountedIcon : idleIcon;
        if (tray.Icon != icon) tray.Icon = icon;
        var mounted = model.Connections.Count(c => model.Status(c.Id).Phase == MountPhase.Mounted);
        var uploads = model.Activity.Values.Sum(a => a.Uploads.Count);
        var downloads = model.Activity.Values.Sum(a => a.Downloads.Count);
        var parts = new List<string> { mounted == 0 ? "nothing mounted" : $"{mounted} mounted" };
        if (uploads > 0) parts.Add($"{Files(uploads)} to upload");
        if (downloads > 0) parts.Add($"downloading {Files(downloads)}");
        var text = "SkyMount: " + string.Join(", ", parts);
        text = text.Length > 127 ? text[..127] : text;
        if (tray.Text != text) tray.Text = text;
    }

    // Menu

    /// Shows the tray menu as a native Windows menu. Explorer keeps Windows 11's hidden-icons flyout
    /// open while such a menu is up, and the menu closes on a click elsewhere; a Windows Forms menu is
    /// an ordinary window, so the flyout closed under it as soon as the pointer left the flyout.
    /// The items are built as Windows Forms items and converted, and the chosen one is clicked.
    void ShowMenu()
    {
        using var items = new ContextMenuStrip();
        BuildMenu(items);
        var commands = new List<ToolStripItem>();
        var menu = NativeMenu(items.Items, commands);
        try
        {
            var at = Cursor.Position;
            // The owner must be the foreground window, or the menu does not close on an outside click.
            SetForegroundWindow(menuOwner.Handle);
            var chosen = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, at.X, at.Y, menuOwner.Handle, IntPtr.Zero);
            PostMessage(menuOwner.Handle, WM_NULL, IntPtr.Zero, IntPtr.Zero); // lets the next menu dismiss correctly
            if (chosen > 0) commands[chosen - 1].PerformClick();
        }
        finally { DestroyMenu(menu); } // destroys the submenus too
    }

    /// A native popup menu with the same items; command IDs are positions in `commands` plus one.
    static IntPtr NativeMenu(ToolStripItemCollection items, List<ToolStripItem> commands)
    {
        var menu = CreatePopupMenu();
        foreach (ToolStripItem item in items)
        {
            if (item is ToolStripSeparator)
            {
                AppendMenu(menu, MF_SEPARATOR, 0, null);
                continue;
            }
            var flags = (item.Enabled ? 0u : MF_GRAYED) | (item is ToolStripMenuItem { Checked: true } ? MF_CHECKED : 0u);
            if (item is ToolStripMenuItem { HasDropDownItems: true } parent)
            {
                AppendMenu(menu, flags | MF_POPUP, (nuint)NativeMenu(parent.DropDownItems, commands), item.Text);
                continue;
            }
            commands.Add(item);
            AppendMenu(menu, flags, (nuint)commands.Count, item.Text);
        }
        return menu;
    }

    void BuildMenu(ContextMenuStrip menu)
    {
        menu.Items.Clear();
        if (model.Connections.Count == 0)
        {
            menu.Items.Add(Disabled("No connections yet"));
            menu.Items.Add("Add Connection…", null, (_, _) => ShowConnections());
        }
        foreach (var c in model.Connections) menu.Items.Add(ConnectionMenu(c));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Connections…", null, (_, _) => ShowConnections());
        menu.Items.Add(new ToolStripMenuItem("Open at Login", null, (_, _) => ToggleLogin()) { Checked = model.OpensAtLogin });
        menu.Items.Add("About SkyMount", null, (_, _) => About());
        menu.Items.Add("Quit SkyMount", null, async (_, _) => await Quit());
    }

    /// The WinFsp license (FLOSS exception) asks for its notice and repository link in the user interface.
    static void About() => MessageBox.Show(
        $"SkyMount {Application.ProductVersion.Split('+')[0]}\nMounts SFTP, FTP, S3 and Google Drive as drives.\n"
        + "Licensed under the Apache License 2.0.\n\n"
        + "WinFsp - Windows File System Proxy, Copyright (C) Bill Zissimopoulos\nhttps://github.com/winfsp/winfsp\n\n"
        + "SSH.NET and FluentFTP are used under the MIT License.",
        "About SkyMount", MessageBoxButtons.OK, MessageBoxIcon.Information);

    ToolStripMenuItem ConnectionMenu(ConnectionConfig c)
    {
        var status = model.Status(c.Id);
        var item = new ToolStripMenuItem($"{c.DisplayName}  ({status.Label})");
        var sub = item.DropDownItems;
        sub.Add(Disabled(status.Label));
        if (status.Phase == MountPhase.Failed) sub.Add(Disabled(status.Detail.Length > 90 ? status.Detail[..90] + "…" : status.Detail));
        sub.Add(new ToolStripSeparator());
        switch (status.Phase)
        {
            case MountPhase.Mounted:
                AddActivity(sub, c.Id);
                sub.Add("Open in Explorer", null, (_, _) => model.OpenInExplorer(c.Id));
                sub.Add("Keep a Folder Offline…", null, (_, _) =>
                    PickFolder(c.Id, "Choose a folder to keep on this PC. Its files stay downloaded and in step with the server.",
                        path => model.KeepOffline(c.Id, path)));
                sub.Add("Free Up Space…", null, (_, _) =>
                    PickFolder(c.Id, "Choose a folder whose downloaded copies to remove. Folders kept offline are not touched.",
                        async path => tray.ShowBalloonTip(3000, "SkyMount", $"Removed {Files(await model.FreeUpSpace(c.Id, path))} from this PC.", ToolTipIcon.Info)));
                sub.Add(new ToolStripMenuItem("Refresh Folders", null, (_, _) => model.RefreshFolders(c.Id))
                {
                    ToolTipText = "Show changes made on the server right away instead of after the refresh interval.",
                });
                sub.Add("Unmount", null, (_, _) => model.Unmount(c.Id));
                break;
            case MountPhase.Idle or MountPhase.Failed:
                sub.Add("Mount", null, (_, _) => model.Mount(c.Id));
                break;
        }
        sub.Add(new ToolStripSeparator());
        sub.Add("Edit Connection…", null, (_, _) => ShowConnections(c.Id));
        return item;
    }

    void AddActivity(ToolStripItemCollection sub, Guid id)
    {
        if (!model.Activity.TryGetValue(id, out var a)) return;
        if (a.Offline) sub.Add(Disabled("Server unreachable: showing offline copies"));
        var failed = a.Uploads.Values.Count(u => u.Phase == UploadPhase.Failed);
        if (a.Uploads.Count > 0)
            sub.Add(Disabled(failed > 0 ? $"{Files(a.Uploads.Count)} not uploaded yet, {failed} failed (retrying)" : $"Uploading {Files(a.Uploads.Count)}"));
        if (a.Downloads.Count > 0) sub.Add(Disabled($"Downloading {Files(a.Downloads.Count)}"));
        if (a.Pinned.Count > 0)
        {
            var kept = new ToolStripMenuItem($"Kept Offline ({a.Pinned.Count})");
            foreach (var (path, state) in a.Pinned.OrderBy(p => p.Key, StringComparer.Ordinal))
            {
                var entry = new ToolStripMenuItem($"{path}  ({Describe(state)})");
                entry.DropDownItems.Add("Stop Keeping Offline", null, (_, _) => model.Unpin(id, path));
                kept.DropDownItems.Add(entry);
            }
            sub.Add(kept);
        }
        sub.Add(new ToolStripSeparator());
    }

    /// Asks for a folder on the connection's drive and passes on its server path.
    void PickFolder(Guid id, string description, Action<string> action)
    {
        if (model.Volume(id) is not { MountPoint: { } drive } volume) return;
        using var dialog = new FolderBrowserDialog { Description = description, UseDescriptionForTitle = true, InitialDirectory = drive + "\\" };
        if (dialog.ShowDialog() != DialogResult.OK) return;
        if (volume.VolumePath(dialog.SelectedPath) is { } path) action(path);
        else MessageBox.Show($"Choose a folder on the {drive} drive.", "SkyMount", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    void ToggleLogin()
    {
        try { model.OpensAtLogin = !model.OpensAtLogin; }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException)
        {
            MessageBox.Show($"Could not change Open at Login: {e.Message}", "SkyMount", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    public async Task Quit()
    {
        if (quitting) return;
        quitting = true;
        tray.Text = "SkyMount: uploading changes and unmounting…";
        connections?.Close();
        await model.UnmountAll();
        tray.Visible = false;
        ExitThread();
    }

    static string Describe(PinState state) => state switch
    {
        PinState.Syncing { Total: > 0 } s => $"downloading {s.Done} of {s.Total}",
        PinState.Syncing => "checking",
        PinState.Synced s => $"up to date, checked {s.Checked.ToLocalTime():t}",
        PinState.Failed f => $"stopped: {f.Message}",
        _ => "",
    };

    static string Files(int n) => n == 1 ? "1 file" : $"{n} files";

    static ToolStripMenuItem Disabled(string text) => new(text) { Enabled = false };

    /// The icon with a colored dot in the lower right corner.
    static Icon Badge(Icon icon, Color color)
    {
        using var bitmap = icon.ToBitmap();
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var d = bitmap.Width * 0.55f;
            var dot = new RectangleF(bitmap.Width - d - 0.5f, bitmap.Height - d - 0.5f, d, d);
            using var brush = new SolidBrush(color);
            using var pen = new Pen(Color.White, Math.Max(1f, bitmap.Width / 16f));
            g.FillEllipse(brush, dot);
            g.DrawEllipse(pen, dot);
        }
        var handle = bitmap.GetHicon();
        try { return (Icon)Icon.FromHandle(handle).Clone(); }
        finally { DestroyIcon(handle); }
    }

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);

    const uint MF_GRAYED = 0x1, MF_CHECKED = 0x8, MF_POPUP = 0x10, MF_SEPARATOR = 0x800;
    const uint TPM_RIGHTBUTTON = 0x2, TPM_RETURNCMD = 0x100;
    const int WM_NULL = 0;

    [DllImport("user32.dll")]
    static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode)]
    static extern bool AppendMenu(IntPtr menu, uint flags, nuint id, string? text);

    [DllImport("user32.dll")]
    static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);

    [DllImport("user32.dll")]
    static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll")]
    static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr window);
}
