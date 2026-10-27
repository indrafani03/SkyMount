using System.Runtime.InteropServices;
using System.Text;

namespace SkyMount.Core;

/// Secrets live in Windows Credential Manager (as "SkyMount/…" generic credentials), never in
/// connections.json.
public static class CredentialStore
{
    const string Prefix = "SkyMount/";
    const uint Generic = 1, PersistLocalMachine = 2, ErrorNotFound = 1168;

    public static string? Get(string account)
    {
        if (!CredRead(Prefix + account, Generic, 0, out var ptr)) return null;
        try
        {
            var cred = Marshal.PtrToStructure<Credential>(ptr);
            var blob = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, blob, 0, blob.Length);
            return Encoding.UTF8.GetString(blob);
        }
        finally { CredFree(ptr); }
    }

    public static void Set(string? value, string account)
    {
        if (string.IsNullOrEmpty(value))
        {
            if (!CredDelete(Prefix + account, Generic, 0) && Marshal.GetLastWin32Error() != ErrorNotFound)
                throw new IOException($"could not remove the saved secret ({Marshal.GetLastWin32Error()})");
            return;
        }
        var blob = Encoding.UTF8.GetBytes(value);
        var ptr = Marshal.AllocHGlobal(blob.Length);
        try
        {
            Marshal.Copy(blob, 0, ptr, blob.Length);
            var cred = new Credential
            {
                Type = Generic,
                TargetName = Prefix + account,
                Comment = "SkyMount connection secret",
                CredentialBlobSize = (uint)blob.Length,
                CredentialBlob = ptr,
                Persist = PersistLocalMachine,
                UserName = account,
            };
            if (!CredWrite(ref cred, 0)) throw new IOException($"could not save the secret ({Marshal.GetLastWin32Error()})");
        }
        finally { Marshal.FreeHGlobal(ptr); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Credential
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref Credential credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr buffer);
}
