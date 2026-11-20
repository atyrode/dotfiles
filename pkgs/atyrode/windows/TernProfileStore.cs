// The caller must establish and verify the directory ACL before using either method.
// Machine-scope DPAPI lets LocalSystem decrypt the profile; the ACL controls who can read it.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace Atyrode.Windows
{
    public static class TernProfileStore
    {
        // WireGuard treats .conf.dpapi as a raw DPAPI blob and checks the description
        // against the tunnel name. See wireguard-windows docs/enterprise.md and conf/dpapi.
        private const string Name = "atyrode-tern";
        private const string FileName = Name + ".conf.dpapi";
        private const uint UiForbidden = 0x1;
        private const uint LocalMachine = 0x4;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);

        [StructLayout(LayoutKind.Sequential)]
        private struct DataBlob
        {
            internal uint Size;
            internal IntPtr Data;
        }

        [DllImport("crypt32.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CryptProtectData(ref DataBlob input, string description,
            IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out DataBlob output);

        [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CryptUnprotectData(ref DataBlob input, out IntPtr description,
            IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out DataBlob output);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern IntPtr LocalFree(IntPtr memory);

        private static string GetProfilePath(string path)
        {
            if (path.Length < 3 || path[1] != ':' || path[2] != '\\' || path.IndexOf(':', 2) != -1 ||
                !String.Equals(Path.GetFileName(path), FileName, StringComparison.Ordinal))
                throw new IOException("Use a fully qualified local path ending in " + FileName + ".");

            path = Path.GetFullPath(path);
            CheckDirectory(Path.GetDirectoryName(path));
            return path;
        }

        private static void CheckDirectory(string directory)
        {
            // Check from the root down so a reparse point is not traversed, even to inspect attributes.
            string parent = Path.GetDirectoryName(directory);
            if (parent != null)
                CheckDirectory(parent);
            if ((File.GetAttributes(directory) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) !=
                FileAttributes.Directory)
                throw new IOException("The Tern profile directory path must not contain reparse points or files.");
        }

        private static bool CheckTarget(string path)
        {
            FileAttributes attributes;
            try { attributes = File.GetAttributes(path); }
            catch (FileNotFoundException) { return false; }
            if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                throw new IOException("The Tern profile target must be a regular file, not a directory or reparse point.");
            return true;
        }

        public static string Read(string path)
        {
            path = GetProfilePath(path);
            if (!CheckTarget(path))
                throw new FileNotFoundException("The encrypted Tern profile is missing.");

            byte[] encrypted = File.ReadAllBytes(path);
            GCHandle pin = GCHandle.Alloc(encrypted, GCHandleType.Pinned);
            DataBlob output = new DataBlob();
            IntPtr description = IntPtr.Zero;
            byte[] plaintext = null;
            try
            {
                var input = new DataBlob { Size = (uint)encrypted.Length, Data = pin.AddrOfPinnedObject() };
                if (!CryptUnprotectData(ref input, out description, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    UiForbidden, out output))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot decrypt the Tern profile with DPAPI.");
                if (!String.Equals(Marshal.PtrToStringUni(description), Name, StringComparison.Ordinal))
                    throw new IOException("The Tern profile's DPAPI description does not match its reserved tunnel name.");

                plaintext = new byte[checked((int)output.Size)];
                Marshal.Copy(output.Data, plaintext, 0, plaintext.Length);
                try { return Utf8.GetString(plaintext); }
                catch (DecoderFallbackException) { throw new IOException("The Tern profile is not valid UTF-8."); }
            }
            finally
            {
                if (plaintext != null)
                    Array.Clear(plaintext, 0, plaintext.Length);
                if (output.Data != IntPtr.Zero)
                {
                    for (uint i = 0; i < output.Size; ++i)
                        Marshal.WriteByte(output.Data, (int)i, 0);
                    LocalFree(output.Data);
                }
                if (description != IntPtr.Zero)
                    LocalFree(description);
                pin.Free();
            }
        }

        private static byte[] Protect(string text)
        {
            byte[] plaintext;
            try { plaintext = Utf8.GetBytes(text); }
            catch (EncoderFallbackException) { throw new IOException("The Tern profile cannot be encoded as UTF-8."); }
            GCHandle pin = new GCHandle();
            DataBlob output = new DataBlob();
            try
            {
                pin = GCHandle.Alloc(plaintext, GCHandleType.Pinned);
                var input = new DataBlob { Size = (uint)plaintext.Length, Data = pin.AddrOfPinnedObject() };
                if (!CryptProtectData(ref input, Name, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    UiForbidden | LocalMachine, out output))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot encrypt the Tern profile with DPAPI.");
                var encrypted = new byte[checked((int)output.Size)];
                Marshal.Copy(output.Data, encrypted, 0, encrypted.Length);
                return encrypted;
            }
            finally
            {
                Array.Clear(plaintext, 0, plaintext.Length);
                if (output.Data != IntPtr.Zero)
                    LocalFree(output.Data);
                if (pin.IsAllocated)
                    pin.Free();
            }
        }

        private static FileSecurity ProfileFileSecurity()
        {
            var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            var security = new FileSecurity();
            security.SetOwner(administrators);
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new FileSystemAccessRule(administrators, FileSystemRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(system, FileSystemRights.FullControl, AccessControlType.Allow));
            return security;
        }

        public static void Write(string path, string text)
        {
            path = GetProfilePath(path);
            bool replace = CheckTarget(path);
            byte[] encrypted = Protect(text);
            string temp = Path.Combine(Path.GetDirectoryName(path), Name + "-" + Guid.NewGuid().ToString("N") + ".tmp");
            bool created = false;
            try
            {
                // Apply owner and ACL as part of creation, before there is an encrypted file to expose.
                using (var stream = new FileStream(temp, FileMode.CreateNew,
                    FileSystemRights.Write | FileSystemRights.ReadPermissions | FileSystemRights.Synchronize,
                    FileShare.None, 4096, FileOptions.None, ProfileFileSecurity()))
                {
                    created = true;
                    stream.Write(encrypted, 0, encrypted.Length);
                    stream.Flush(true);
                }

                if (replace)
                {
                    if (!CheckTarget(path))
                        throw new IOException("The Tern profile disappeared during replacement.");
                    File.Replace(temp, path, null);
                }
                else
                {
                    File.Move(temp, path);
                }
                created = false;
            }
            finally
            {
                if (created)
                    File.Delete(temp);
            }
        }
    }
}
