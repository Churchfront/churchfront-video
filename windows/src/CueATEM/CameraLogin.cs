using System.Runtime.InteropServices;
using System.Text;

namespace CueATEM;

/// <summary>
/// The cameras' admin login, kept in Windows Credential Manager (never in the config file).
/// Only needed for changing presets stored on the cameras themselves; everyday control and
/// Churchfront Video's own shots work without it. One login is used for every Canon camera.
/// Shows in Control Panel, Credential Manager, Windows Credentials as "CueVideo camera admin login".
/// </summary>
public static class CameraLogin
{
    private const string Target = "CueVideo camera admin login";

    public sealed record Credential(string User, string Password);

    public static Credential? Load()
    {
        if (!OperatingSystem.IsWindows()) return null;
        if (!CredReadW(Target, CRED_TYPE_GENERIC, 0, out var p)) return null;
        try
        {
            var c = Marshal.PtrToStructure<CREDENTIAL>(p);
            var user = c.UserName ?? "";
            var pass = c.CredentialBlobSize > 0 && c.CredentialBlob != IntPtr.Zero
                ? Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2)
                : "";
            return new Credential(user, pass);
        }
        finally { CredFree(p); }
    }

    /// <summary>Saves (or replaces) the login. Returns false if Windows refused.</summary>
    public static bool Save(string user, string password)
    {
        if (!OperatingSystem.IsWindows()) return false;
        var blob = Encoding.Unicode.GetBytes(password);
        var mem = Marshal.AllocHGlobal(Math.Max(1, blob.Length));
        try
        {
            Marshal.Copy(blob, 0, mem, blob.Length);
            var c = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = Target,
                UserName = user,
                CredentialBlob = mem,
                CredentialBlobSize = (uint)blob.Length,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                Comment = "Canon camera admin login for Churchfront Video",
            };
            return CredWriteW(ref c, 0);
        }
        finally
        {
            for (int i = 0; i < blob.Length; i++) Marshal.WriteByte(mem, i, 0);
            Marshal.FreeHGlobal(mem);
        }
    }

    public static void Clear()
    {
        if (OperatingSystem.IsWindows()) CredDeleteW(Target, CRED_TYPE_GENERIC, 0);
    }

    public static bool IsSaved => Load() != null;

    /// <summary>The saved user name, for showing in Setup (the password is never shown).</summary>
    public static string? SavedUser => Load()?.User;

    // MARK: Credential Manager

    private const uint CRED_TYPE_GENERIC = 1;
    private const uint CRED_PERSIST_LOCAL_MACHINE = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}
