using System.Diagnostics;
using SkyMount.Core;

namespace SkyMount;

/// Connections on the left; the selected one's settings on the right, with Mount, Test and Save.
sealed class ConnectionsForm : Form
{
    readonly AppModel model;
    readonly ListBox list = new() { Dock = DockStyle.Fill, IntegralHeight = false, DrawMode = DrawMode.OwnerDrawFixed, BorderStyle = BorderStyle.None };
    readonly TableLayoutPanel grid = new() { ColumnCount = 2, AutoSize = true, Dock = DockStyle.Top, Padding = new Padding(16, 8, 16, 8) };
    readonly Panel fields = new() { Dock = DockStyle.Fill, AutoScroll = true };
    readonly Panel editor = new() { Dock = DockStyle.Fill, Visible = false };
    readonly Label empty = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = SystemColors.GrayText,
        Text = "Select a connection on the left to edit or mount it,\nor add one with the Add button." };
    readonly Label problem = new() { AutoSize = true, ForeColor = SystemColors.GrayText };
    readonly Label result = new() { AutoSize = true, MaximumSize = new Size(560, 0) };
    readonly Button mountButton = new() { AutoSize = true, Text = "Mount" };
    readonly Button revertButton = new() { AutoSize = true, Text = "Revert" };
    readonly Button testButton = new() { AutoSize = true, Text = "Test Connection" };
    readonly Button saveButton = new() { AutoSize = true, Text = "Save" };
    readonly Button deleteButton = new() { AutoSize = true, Text = "Delete" };

    ConnectionConfig? original;
    ConnectionConfig draft = new();
    Dictionary<SecretField, string> secrets = [], savedSecrets = [];
    bool loading, checking;

    public ConnectionsForm(AppModel model, Icon icon)
    {
        this.model = model;
        Text = "SkyMount Connections";
        Icon = icon;
        Font = SystemFonts.MessageBoxFont;
        AutoScaleMode = AutoScaleMode.Dpi;
        Size = new Size(880, 620);
        MinimumSize = new Size(720, 480);
        StartPosition = FormStartPosition.CenterScreen;
        KeyPreview = true;
        KeyDown += (_, e) =>
        {
            if (e is { Control: true, KeyCode: Keys.S } && saveButton.Enabled) Save();
        };

        list.ItemHeight = Font.Height * 2 + 12;
        list.DrawItem += DrawConnection;
        list.SelectedIndexChanged += (_, _) => Edit(list.SelectedItem as ConnectionConfig);
        var add = new Button { AutoSize = true, Text = "Add" };
        add.Click += (_, _) => AddConnection();
        deleteButton.Click += (_, _) => DeleteConnection();
        var left = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2 };
        left.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        left.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        left.Controls.Add(list, 0, 0);
        left.Controls.Add(new FlowLayoutPanel { AutoSize = true, Controls = { add, deleteButton } }, 0, 1);

        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        fields.Controls.Add(grid);
        mountButton.Click += (_, _) =>
        {
            if (IsDirty) Save();
            model.Toggle(draft.Id);
        };
        revertButton.Click += (_, _) => Edit(original);
        testButton.Click += (_, _) => RunTest();
        saveButton.Click += (_, _) => Save();
        var buttons = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft,
            Controls = { saveButton, testButton, revertButton } };
        var footer = new TableLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, ColumnCount = 2, Padding = new Padding(12, 8, 12, 12) };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        footer.Controls.Add(problem, 0, 0);
        footer.SetColumnSpan(problem, 2);
        footer.Controls.Add(result, 0, 1);
        footer.SetColumnSpan(result, 2);
        footer.Controls.Add(mountButton, 0, 2);
        footer.Controls.Add(buttons, 1, 2);
        editor.Controls.Add(fields);
        editor.Controls.Add(footer);

        var split = new SplitContainer { Dock = DockStyle.Fill, FixedPanel = FixedPanel.Panel1 };
        split.Panel1.Controls.Add(left);
        split.Panel2.Controls.Add(editor);
        split.Panel2.Controls.Add(empty);
        Controls.Add(split);
        Load += (_, _) => split.SplitterDistance = LogicalToDeviceUnits(250);

        model.Changed += OnModelChanged;
        FormClosed += (_, _) => model.Changed -= OnModelChanged;
        RefreshList();
        if (model.Connections.Count > 0) list.SelectedIndex = 0;
    }

    public void SelectConnection(Guid id)
    {
        var i = model.Connections.FindIndex(c => c.Id == id);
        if (i >= 0) list.SelectedIndex = i;
    }

    void OnModelChanged()
    {
        list.Invalidate();
        if (original == null) return;
        // Saved meanwhile by something else (the host key seen on the first connection): show it,
        // unless the form holds edits of its own.
        if (!IsDirty && model.Connections.Find(c => c.Id == original.Id) is { } saved && saved != original) Edit(saved);
        else UpdateFooter();
    }

    void RefreshList()
    {
        var selected = (list.SelectedItem as ConnectionConfig)?.Id;
        list.BeginUpdate();
        list.Items.Clear();
        foreach (var c in model.Connections) list.Items.Add(c);
        list.EndUpdate();
        if (selected is { } id) SelectConnection(id);
    }

    void DrawConnection(object? sender, DrawItemEventArgs e)
    {
        e.DrawBackground();
        if (e.Index < 0 || list.Items[e.Index] is not ConnectionConfig c) return;
        // The list holds the saved copies; show the current name from the model.
        c = model.Connections.Find(x => x.Id == c.Id) ?? c;
        var selected = (e.State & DrawItemState.Selected) != 0;
        var status = model.Status(c.Id);
        var line2 = $"{c.Kind.Title()} · {status.Label}";
        var top = new Rectangle(e.Bounds.X + 8, e.Bounds.Y + 5, e.Bounds.Width - 16, Font.Height);
        TextRenderer.DrawText(e.Graphics, c.DisplayName, Font, top, selected ? SystemColors.HighlightText : SystemColors.ControlText, TextFormatFlags.EndEllipsis);
        top.Offset(0, Font.Height + 2);
        var color = selected ? SystemColors.HighlightText : status.Phase == MountPhase.Failed ? Color.DarkOrange : SystemColors.GrayText;
        TextRenderer.DrawText(e.Graphics, line2, Font, top, color, TextFormatFlags.EndEllipsis);
    }

    // Editing

    void Edit(ConnectionConfig? config)
    {
        original = config == null ? null : model.Connections.Find(c => c.Id == config.Id);
        editor.Visible = original != null;
        empty.Visible = original == null;
        if (original == null) return;
        draft = original with { };
        secrets = [];
        foreach (var field in new[] { SecretField.Password, SecretField.KeyPassphrase, SecretField.S3SecretKey, SecretField.GoogleClientSecret })
            if (original.Secret(field) is { } value) secrets[field] = value;
        savedSecrets = new(secrets);
        SetResult("", SystemColors.ControlText);
        BuildFields();
    }

    bool IsDirty => original != null && (draft != original || secrets.Count != savedSecrets.Count
        || secrets.Any(s => savedSecrets.GetValueOrDefault(s.Key) != s.Value));

    void BuildFields()
    {
        loading = true;
        grid.SuspendLayout();
        foreach (Control c in grid.Controls.Cast<Control>().ToList()) c.Dispose();
        grid.Controls.Clear();
        grid.RowStyles.Clear();
        grid.RowCount = 0;

        AddText("Name", draft.Name, v => draft.Name = v, "Shown in Explorer and the menu");
        AddChoice("Type", Enum.GetValues<BackendKind>().Select(k => k.Title()).ToArray(), (int)draft.Kind, i =>
        {
            draft.Kind = (BackendKind)i;
            draft.Port = draft.Kind.DefaultPort();
            Rebuild();
        });
        switch (draft.Kind)
        {
            case BackendKind.Sftp: SftpFields(); break;
            case BackendKind.Ftp: FtpFields(); break;
            case BackendKind.S3: S3Fields(); break;
            case BackendKind.GoogleDrive: GoogleFields(); break;
        }
        Header("Options");
        AddCheck("Mount when SkyMount opens", draft.AutoMount, v => draft.AutoMount = v);
        AddCheck("Read-only", draft.ReadOnly, v => draft.ReadOnly = v);
        AddNumber("Re-read folders after (s)", (decimal)draft.ListingTTL, 5, 300, 5, v => draft.ListingTTL = (double)v);
        Note("Folder listings are reused for this long. Lower values show changes made on the server sooner but make more requests.");
        var letters = Enumerable.Range('D', 'Z' - 'D' + 1).Select(c => ((char)c).ToString()).ToArray();
        AddChoice("Drive letter", ["Automatic", .. letters.Select(l => l + ":")], Math.Max(0, Array.IndexOf(letters, draft.DriveLetter) + 1),
            i => draft.DriveLetter = i == 0 ? "" : letters[i - 1]);

        grid.ResumeLayout();
        loading = false;
        UpdateFooter();
    }

    /// Rebuilds after the event that asked for it, not inside it (its control is about to go away).
    void Rebuild() => BeginInvoke(BuildFields);

    void SftpFields()
    {
        Header("Server");
        ServerFields("sftp.example.com");
        AddChoice("Sign in with", ["Password", "Private key"], draft.SftpUseKey ? 1 : 0, i =>
        {
            draft.SftpUseKey = i == 1;
            Rebuild();
        });
        if (draft.SftpUseKey)
        {
            var path = new TextBox { Text = draft.SftpKeyPath, Width = 300, Anchor = AnchorStyles.Left | AnchorStyles.Right };
            path.TextChanged += (_, _) => Changed(() => draft.SftpKeyPath = path.Text);
            var choose = new Button { AutoSize = true, Text = "Choose…" };
            choose.Click += (_, _) =>
            {
                var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                using var dialog = new OpenFileDialog { Title = "Choose the private key file (not the .pub file)", InitialDirectory = Path.Combine(home, ".ssh") };
                if (dialog.ShowDialog(this) == DialogResult.OK)
                    path.Text = dialog.FileName.StartsWith(home, StringComparison.OrdinalIgnoreCase) ? "~" + dialog.FileName[home.Length..].Replace('\\', '/') : dialog.FileName;
            };
            Row("Key file", Pair(path, choose));
            AddSecret("Key passphrase", SecretField.KeyPassphrase, "Leave empty if the key has none");
        }
        else
        {
            AddSecret("Password", SecretField.Password);
        }
        if (draft.SftpHostFingerprint is { } fingerprint)
        {
            var forget = new Button { AutoSize = true, Text = "Forget" };
            new ToolTip().SetToolTip(forget, "Use after the server was reinstalled. The next connection trusts the key it sees.");
            forget.Click += (_, _) =>
            {
                model.ResetHostKey(draft.Id);
                draft.SftpHostFingerprint = null;
                if (original != null) original = original with { SftpHostFingerprint = null };
                BuildFields();
            };
            Row("Server key", Pair(new TextBox { Text = fingerprint, ReadOnly = true, BorderStyle = BorderStyle.None, Width = 300,
                Anchor = AnchorStyles.Left | AnchorStyles.Right }, forget));
        }
        else
        {
            Row("Server key", new Label { Text = "Saved on first connection", AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(3, 7, 3, 3) });
        }
    }

    void FtpFields()
    {
        Header("Server");
        ServerFields("ftp.example.com");
        AddSecret("Password", SecretField.Password);
        AddCheck("Require TLS (FTPS)", draft.FtpUseTLS, v => draft.FtpUseTLS = v);
        Note("Plain FTP sends the password unencrypted. Turn TLS off only for servers without it.");
    }

    void ServerFields(string example)
    {
        AddText("Address", draft.Host, v => draft.Host = v, example);
        AddNumber("Port", draft.Port, 1, 65535, 1, v => draft.Port = (int)v);
        AddText("User", draft.Username, v => draft.Username = v);
        AddText("Folder on server", draft.RemoteFolder, v => draft.RemoteFolder = v, "/");
    }

    void S3Fields()
    {
        Header("Bucket");
        AddText("Endpoint", draft.S3Endpoint, v => draft.S3Endpoint = v, "https://s3.amazonaws.com");
        AddText("Region", draft.S3Region, v => draft.S3Region = v, "us-east-1");
        AddText("Bucket", draft.S3Bucket, v => draft.S3Bucket = v);
        AddText("Folder in bucket", draft.RemoteFolder, v => draft.RemoteFolder = v, "/");
        AddText("Access key ID", draft.S3AccessKey, v => draft.S3AccessKey = v);
        AddSecret("Secret access key", SecretField.S3SecretKey);
        AddCheck("Path-style addresses", draft.S3PathStyle, v => draft.S3PathStyle = v);
        Note("Works with Amazon S3, Backblaze B2, Wasabi, Cloudflare R2 and MinIO. Use the endpoint and region your provider lists. "
            + "MinIO and most S3-compatible services need path-style addresses; Amazon S3 works either way.");
    }

    void GoogleFields()
    {
        Header("Google Drive");
        AddText("OAuth client ID", draft.GoogleClientID, v => draft.GoogleClientID = v, "…apps.googleusercontent.com");
        AddSecret("OAuth client secret", SecretField.GoogleClientSecret);
        var signedIn = draft.GoogleAccount.Length > 0 || original?.Secret(SecretField.GoogleRefreshToken) != null;
        var button = new Button { AutoSize = true, Text = signedIn ? "Sign Out" : "Sign In with Google…" };
        button.Click += (_, _) =>
        {
            if (signedIn) SignOut();
            else SignIn();
        };
        if (!signedIn) button.Enabled = draft.GoogleClientID.Length > 0 && secrets.GetValueOrDefault(SecretField.GoogleClientSecret, "").Length > 0;
        var account = new Label { AutoSize = true, Text = signedIn ? (draft.GoogleAccount.Length > 0 ? draft.GoogleAccount : "Signed in") : "Not signed in",
            Margin = new Padding(3, 7, 12, 3) };
        Row("Account", Pair(account, button));
        Note("SkyMount uses your own OAuth client, so no third party sees your files. Create one of type “Desktop app” "
            + "and enable the Google Drive API. Deleted files go to the Drive trash. Google Docs, Sheets and Slides are not shown "
            + "because they have no file to download.");
        var link = new LinkLabel { Text = "Open Google Cloud credentials", AutoSize = true, Margin = new Padding(3, 0, 3, 8) };
        link.LinkClicked += (_, _) => OpenUrl("https://console.cloud.google.com/apis/credentials");
        Row("", link);
    }

    // Field helpers

    void Row(string label, Control control)
    {
        var row = grid.RowCount++;
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        grid.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(3, 7, 16, 3) }, 0, row);
        if (control.Anchor == (AnchorStyles.Top | AnchorStyles.Left)) control.Anchor = AnchorStyles.Left;
        grid.Controls.Add(control, 1, row);
    }

    void Header(string text)
    {
        var row = grid.RowCount++;
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var label = new Label { Text = text, AutoSize = true, Font = new Font(Font, FontStyle.Bold), Margin = new Padding(3, 16, 3, 4) };
        grid.Controls.Add(label, 0, row);
        grid.SetColumnSpan(label, 2);
    }

    void Note(string text)
    {
        var row = grid.RowCount++;
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var label = new Label { Text = text, AutoSize = true, ForeColor = SystemColors.GrayText, MaximumSize = new Size(LogicalToDeviceUnits(520), 0), Margin = new Padding(3, 2, 3, 6) };
        grid.Controls.Add(label, 1, row);
    }

    void Changed(Action apply)
    {
        if (loading) return;
        apply();
        UpdateFooter();
    }

    void AddText(string label, string value, Action<string> set, string? placeholder = null, bool secret = false)
    {
        var box = new TextBox { Text = value, PlaceholderText = placeholder ?? "", UseSystemPasswordChar = secret, Width = 380,
            Anchor = AnchorStyles.Left | AnchorStyles.Right };
        box.TextChanged += (_, _) => Changed(() => set(box.Text));
        Row(label, box);
    }

    void AddSecret(string label, SecretField field, string? placeholder = null) =>
        AddText(label, secrets.GetValueOrDefault(field, ""), v => secrets[field] = v, placeholder, secret: true);

    void AddNumber(string label, decimal value, decimal min, decimal max, decimal step, Action<decimal> set)
    {
        var box = new NumericUpDown { Minimum = min, Maximum = max, Increment = step, Value = Math.Clamp(value, min, max), Width = 90 };
        box.ValueChanged += (_, _) => Changed(() => set(box.Value));
        Row(label, box);
    }

    void AddCheck(string text, bool value, Action<bool> set)
    {
        var box = new CheckBox { Text = text, Checked = value, AutoSize = true };
        box.CheckedChanged += (_, _) => Changed(() => set(box.Checked));
        Row("", box);
    }

    void AddChoice(string label, string[] items, int selected, Action<int> set)
    {
        var box = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 240 };
        box.Items.AddRange(items);
        box.SelectedIndex = selected;
        box.SelectedIndexChanged += (_, _) => Changed(() => set(box.SelectedIndex));
        Row(label, box);
    }

    static FlowLayoutPanel Pair(Control a, Control b) =>
        new() { AutoSize = true, WrapContents = false, Margin = Padding.Empty, Controls = { a, b } };

    // Footer and actions

    void UpdateFooter()
    {
        var status = model.Status(draft.Id);
        // A mounted connection keeps the settings it was mounted with: unmount to change or delete it.
        var locked = status.Phase is MountPhase.Mounted or MountPhase.Working;
        var invalid = draft.ValidationProblem();
        grid.Enabled = deleteButton.Enabled = !locked;
        problem.Text = locked ? "Unmount to change or delete this connection." : invalid ?? "";
        problem.Visible = problem.Text.Length > 0;
        if (!checking && status.Phase == MountPhase.Failed) SetResult($"Last mount attempt: {status.Detail}", Color.DarkOrange);
        mountButton.Text = status.Phase == MountPhase.Mounted ? $"Unmount {status.Detail}" : "Mount";
        mountButton.Enabled = invalid == null && !checking && status.Phase != MountPhase.Working;
        revertButton.Enabled = saveButton.Enabled = IsDirty && !locked;
        testButton.Enabled = invalid == null && !checking && !locked;
    }

    void SetResult(string text, Color color)
    {
        result.Text = text;
        result.ForeColor = color;
        result.Visible = text.Length > 0;
    }

    void Save()
    {
        try
        {
            // The host key is set by connecting and by Forget, never by this form: keep the saved one.
            if (model.Connections.Find(c => c.Id == draft.Id) is { } saved) draft.SftpHostFingerprint = saved.SftpHostFingerprint;
            foreach (var (field, value) in secrets)
                if (savedSecrets.GetValueOrDefault(field) != value) draft.SetSecret(field, value);
            savedSecrets = new(secrets);
            model.Upsert(draft);
            original = draft with { };
        }
        catch (IOException e)
        {
            MessageBox.Show(this, $"Could not save: {e.Message}", "SkyMount", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        UpdateFooter();
    }

    async void RunTest()
    {
        Save();
        var config = draft with { };
        checking = true;
        SetResult($"Connecting to {(config.Summary.Length > 0 ? config.Summary : config.DisplayName)}…", SystemColors.ControlText);
        UpdateFooter();
        try
        {
            var message = await AppModel.Test(config);
            if (draft.Id == config.Id) SetResult(message, Color.ForestGreen);
        }
        catch (Exception e)
        {
            if (draft.Id == config.Id) SetResult(e.Message, Color.Firebrick);
        }
        checking = false;
        UpdateFooter();
    }

    async void SignIn()
    {
        Save();
        var config = draft with { };
        var client = new GoogleOAuth.Client(config.GoogleClientID, secrets.GetValueOrDefault(SecretField.GoogleClientSecret, ""));
        checking = true;
        SetResult("Waiting for Google sign-in in your browser…", SystemColors.ControlText);
        UpdateFooter();
        try
        {
            var grant = await Task.Run(() => new GoogleOAuth(client).Authorize(OpenUrl));
            config.SetSecret(SecretField.GoogleRefreshToken, grant.RefreshToken);
            config.GoogleAccount = grant.Email;
            model.Upsert(config);
            checking = false;
            if (draft.Id == config.Id)
            {
                Edit(config);
                SetResult(grant.Email.Length == 0 ? "Signed in." : $"Signed in as {grant.Email}.", Color.ForestGreen);
            }
        }
        catch (Exception e)
        {
            checking = false;
            if (draft.Id == config.Id) SetResult(e.Message, Color.Firebrick);
        }
        UpdateFooter();
    }

    void SignOut()
    {
        draft.GoogleAccount = "";
        draft.SetSecret(SecretField.GoogleRefreshToken, null);
        Save();
        BuildFields();
    }

    void AddConnection()
    {
        var c = new ConnectionConfig { Name = "New Connection" };
        model.Upsert(c);
        RefreshList();
        SelectConnection(c.Id);
    }

    void DeleteConnection()
    {
        if (list.SelectedItem is not ConnectionConfig c) return;
        var answer = MessageBox.Show(this,
            $"Delete “{c.DisplayName}”?\n\nThe drive is unmounted and the saved passwords and tokens are removed from Windows Credential Manager. "
            + "Files on the server are not touched.", "Delete Connection", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
        if (answer != DialogResult.OK) return;
        model.Delete(c.Id);
        RefreshList();
        if (list.Items.Count > 0) list.SelectedIndex = 0;
        else Edit(null);
    }

    static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
}
