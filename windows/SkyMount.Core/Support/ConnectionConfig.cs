using System.Text.Json;
using System.Text.Json.Serialization;

namespace SkyMount.Core;

public enum BackendKind { Sftp, Ftp, S3, GoogleDrive }

public static class BackendKinds
{
    public static string Title(this BackendKind kind) => kind switch
    {
        BackendKind.Sftp => "SFTP",
        BackendKind.Ftp => "FTP / FTPS",
        BackendKind.S3 => "Amazon S3 or compatible",
        _ => "Google Drive",
    };

    public static int DefaultPort(this BackendKind kind) => kind switch
    {
        BackendKind.Sftp => 22,
        BackendKind.Ftp => 21,
        _ => 0,
    };
}

public enum SecretField { Password, KeyPassphrase, S3SecretKey, GoogleClientSecret, GoogleRefreshToken }

/// Everything about a connection except secrets, which go to Windows Credential Manager.
public sealed record ConnectionConfig
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public BackendKind Kind { get; set; } = BackendKind.Sftp;

    // SFTP / FTP
    public string Host { get; set; } = "";
    public int Port { get; set; } = 22;
    public string Username { get; set; } = "";
    /// Folder on the server (or in the bucket) used as the drive's root.
    public string RemoteFolder { get; set; } = "/";
    public bool SftpUseKey { get; set; }
    public string SftpKeyPath { get; set; } = "~/.ssh/id_ed25519";
    public string? SftpHostFingerprint { get; set; }
    public bool FtpUseTLS { get; set; } = true;

    // S3
    public string S3Endpoint { get; set; } = "https://s3.amazonaws.com";
    public string S3Region { get; set; } = "us-east-1";
    public string S3Bucket { get; set; } = "";
    public string S3AccessKey { get; set; } = "";
    public bool S3PathStyle { get; set; }

    // Google Drive
    public string GoogleClientID { get; set; } = "";
    public string GoogleAccount { get; set; } = "";

    // Behaviour
    public bool AutoMount { get; set; }
    public bool ReadOnly { get; set; }
    public double ListingTTL { get; set; } = 15;
    /// "S" mounts on S:; empty takes the next free letter from Z: down.
    public string DriveLetter { get; set; } = "";

    public string SecretAccount(SecretField field) => $"{Id}.{JsonNamingPolicy.CamelCase.ConvertName(field.ToString())}";
    public string? Secret(SecretField field) => CredentialStore.Get(SecretAccount(field));
    public void SetSecret(SecretField field, string? value) => CredentialStore.Set(value, SecretAccount(field));

    [JsonIgnore]
    public string DisplayName => string.IsNullOrWhiteSpace(Name) ? "Untitled connection" : Name;

    /// Short description of where this connection points, for lists.
    [JsonIgnore]
    public string Summary => Kind switch
    {
        BackendKind.Sftp or BackendKind.Ftp => Username.Length == 0 ? Host : $"{Username}@{Host}",
        BackendKind.S3 => S3Bucket,
        _ => GoogleAccount.Length == 0 ? "Not signed in" : GoogleAccount,
    };

    /// Describes the first missing or invalid field, or returns null when the config is usable.
    public string? ValidationProblem()
    {
        if (string.IsNullOrWhiteSpace(Name)) return "Give the connection a name.";
        switch (Kind)
        {
            case BackendKind.Sftp or BackendKind.Ftp:
                if (Host.Length == 0) return "Enter the server address.";
                if (Username.Length == 0) return "Enter the user name.";
                if (Port is < 1 or > 65535) return "The port must be between 1 and 65535.";
                break;
            case BackendKind.S3:
                if (!Uri.TryCreate(S3Endpoint, UriKind.Absolute, out _)) return "Enter the endpoint as a full URL, like https://s3.amazonaws.com.";
                if (S3Bucket.Length == 0) return "Enter the bucket name.";
                if (S3AccessKey.Length == 0) return "Enter the access key ID.";
                break;
            case BackendKind.GoogleDrive:
                if (GoogleClientID.Length == 0) return "Enter the OAuth client ID from Google Cloud Console.";
                break;
        }
        if (DriveLetter.Length > 0 && !(DriveLetter.Length == 1 && char.IsAsciiLetterUpper(DriveLetter[0])))
            return "Choose a drive letter from the list.";
        return null;
    }
}

/// Where SkyMount keeps its files: %LOCALAPPDATA%\SkyMount, or SKYMOUNT_HOME when set (for testing).
public static class AppPaths
{
    public static readonly string Root = Environment.GetEnvironmentVariable("SKYMOUNT_HOME")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SkyMount");
    public static string Cache(Guid id) => Path.Combine(Root, "Cache", id.ToString());
    /// Unsent writes; outside the cache so cleaning it never loses them.
    public static string Pending(Guid id) => Path.Combine(Root, "Pending", id.ToString());
    public static string Pins(Guid id) => Path.Combine(Root, "Offline", id + ".json");
}

public static class ConnectionStore
{
    public static readonly string FilePath = Path.Combine(AppPaths.Root, "connections.json");

    static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static List<ConnectionConfig> Load()
    {
        // ReadAllText drops a byte order mark, which editors like Notepad may add.
        try { return JsonSerializer.Deserialize<List<ConnectionConfig>>(File.ReadAllText(FilePath), Options) ?? []; }
        catch (IOException) { return []; }
        catch (JsonException)
        {
            // Keep the unreadable file instead of overwriting it with the next save.
            File.Move(FilePath, FilePath + ".unreadable", overwrite: true);
            return [];
        }
    }

    public static void Save(List<ConnectionConfig> configs) => Util.WriteAtomic(FilePath, JsonSerializer.SerializeToUtf8Bytes(configs, Options));
}

public static class BackendFactory
{
    /// `onFingerprint` receives an SFTP host key seen for the first time so it can be saved.
    public static IRemoteFileSystem Make(ConnectionConfig c, Action<string> onFingerprint) => c.Kind switch
    {
        BackendKind.Sftp => new SftpBackend(new SftpSettings(c.Host, c.Port, c.Username, c.RemoteFolder,
            Password: c.SftpUseKey ? null : c.Secret(SecretField.Password),
            PrivateKeyPath: c.SftpUseKey ? c.SftpKeyPath : null,
            KeyPassphrase: c.SftpUseKey ? c.Secret(SecretField.KeyPassphrase) : null,
            KnownFingerprint: c.SftpHostFingerprint), onFingerprint),
        BackendKind.Ftp => new FtpBackend(new FtpSettings(c.Host, c.Port, c.Username, c.Secret(SecretField.Password) ?? "",
            c.RemoteFolder, c.FtpUseTLS)),
        BackendKind.S3 => new S3Backend(new S3Settings(
            Uri.TryCreate(c.S3Endpoint, UriKind.Absolute, out var endpoint) ? endpoint : throw RemoteException.Protocol("invalid endpoint"),
            c.S3Region, c.S3Bucket, c.S3AccessKey,
            c.Secret(SecretField.S3SecretKey) is { Length: > 0 } secret ? secret : throw RemoteException.Authentication("the secret access key is missing"),
            c.S3PathStyle, c.RemoteFolder)),
        _ => new GoogleDriveBackend(new GoogleOAuth.Client(c.GoogleClientID, c.Secret(SecretField.GoogleClientSecret) ?? ""),
            c.Secret(SecretField.GoogleRefreshToken) ?? throw RemoteException.Authentication("sign in with Google first")),
    };
}
