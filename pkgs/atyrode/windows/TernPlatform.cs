using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Atyrode.Windows
{
    internal static class TernPlatform
    {
        internal const string Tunnel = "atyrode-tern";
        private static readonly string ProgramFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        private static readonly string Vendor = Path.Combine(ProgramFiles, "Atyrode");
        private static readonly string Store = Path.Combine(Vendor, "Tern");
        private static readonly string WireGuardDirectory = Path.Combine(ProgramFiles, "WireGuard");
        internal static readonly string ProfilePath = Path.Combine(Store, Tunnel + ".conf.dpapi");
        internal static readonly string WireGuard = Path.Combine(WireGuardDirectory, "wireguard.exe");
        internal static readonly string Wg = Path.Combine(WireGuardDirectory, "wg.exe");
        private static readonly string[] StoreDirectories = { Vendor, Store };
        private static readonly string[] WireGuardExecutables = { WireGuard, Wg };

        private static readonly SecurityIdentifier Admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        private static readonly SecurityIdentifier SystemUser = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        private static readonly SecurityIdentifier Installer = new SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464");
        private static readonly Regex LocalRoot = new Regex(@"\A[A-Za-z]:\\\z", RegexOptions.CultureInvariant);
        private static readonly Regex WireGuardDescription = new Regex(@"\AWireGuard Tunnel(?: #[0-9]+)?\z", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
        private const string CimNamespace = @"root\StandardCimv2";
        private const AceFlags DirectoryInheritance = AceFlags.ContainerInherit | AceFlags.ObjectInherit;

        internal static bool IsAdmin
        {
            get
            {
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                    return new WindowsPrincipal(identity).IsInRole(Admins);
            }
        }

        internal static void AssertProgramFiles()
        {
            if (!Environment.Is64BitProcess)
                throw new TernException("Run the 64-bit native Windows Tern helper.");

            string root = ProgramFiles.Length == 0 ? null : Path.GetPathRoot(ProgramFiles);
            if (root == null || !LocalRoot.IsMatch(root) || new DriveInfo(root).DriveType != DriveType.Fixed ||
                !String.Equals(Path.GetDirectoryName(ProgramFiles), root, StringComparison.OrdinalIgnoreCase) ||
                !PathExists(root, true) || !PathExists(ProgramFiles, true))
                throw new TernException("Program Files is not an ordinary directory at the local volume root.");

            AssertProgramAcl(root, true, true);
            AssertProgramAcl(ProgramFiles, true, false);
        }

        internal static bool ProfileExists()
        {
            foreach (string directory in StoreDirectories)
            {
                if (!PathExists(directory, true)) return false;
                AssertProtectedAcl(directory, true);
            }
            if (!PathExists(ProfilePath, false)) return false;
            AssertProtectedAcl(ProfilePath, false);
            return true;
        }

        internal static void AssertProfile()
        {
            if (!ProfileExists())
                throw new TernException("The reserved Tern profile is missing. The Windows service was not changed.");
        }

        internal static IDisposable LockStore()
        {
            foreach (string directory in StoreDirectories)
            {
                if (!PathExists(directory, true))
                {
                    var security = new DirectorySecurity();
                    RestrictAcl(security, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit);
                    Directory.CreateDirectory(directory, security);
                }
                if (!PathExists(directory, true))
                    throw new TernException("The protected Tern store disappeared during Apply.");
                AssertProtectedAcl(directory, true);
            }

            string path = Path.Combine(Store, "apply.lock");
            if (PathExists(path, false)) AssertProtectedAcl(path, false);
            var fileSecurity = new FileSecurity();
            RestrictAcl(fileSecurity, InheritanceFlags.None);
            try
            {
                return new FileStream(path, FileMode.OpenOrCreate, FileSystemRights.Read | FileSystemRights.Write,
                    FileShare.None, 4096, FileOptions.None, fileSecurity);
            }
            catch (IOException)
            {
                throw new TernException("Cannot lock the protected Tern store for Apply. Another native Apply may already be running.");
            }
        }

        internal static bool WireGuardInstalled()
        {
            if (!PathExists(WireGuardDirectory, true)) return false;
            AssertProgramAcl(WireGuardDirectory, true, false);

            // Check only these reserved manager names. Never open a manager profile.
            string data = Path.Combine(WireGuardDirectory, "Data");
            string configs = Path.Combine(data, "Configurations");
            if (PathExists(data, true))
            {
                AssertProgramAcl(data, true, false);
                if (PathExists(configs, true))
                {
                    AssertProgramAcl(configs, true, false);
                    if (PathExists(Path.Combine(configs, Tunnel + ".conf"), false) ||
                        PathExists(Path.Combine(configs, Tunnel + ".conf.dpapi"), false))
                        throw new TernException("A WireGuard manager profile already uses the reserved Tern name. It was not modified.");
                }
            }
            foreach (string executable in WireGuardExecutables)
            {
                if (!PathExists(executable, false)) return false;
                AssertProgramAcl(executable, false, false);
            }
            return true;
        }

        private static bool PathExists(string path, bool directory)
        {
            FileAttributes attributes;
            try { attributes = File.GetAttributes(path); }
            catch (FileNotFoundException) { return false; }
            catch (DirectoryNotFoundException) { return false; }

            if ((attributes & FileAttributes.ReparsePoint) != 0 ||
                ((attributes & FileAttributes.Directory) != 0) != directory)
                throw new TernException("Unexpected file type or reparse point at the reserved Windows path: " + path);
            return true;
        }

        private static RawSecurityDescriptor PathSecurity(string path, bool directory)
        {
            const AccessControlSections sections = AccessControlSections.Owner | AccessControlSections.Access;
            FileSystemSecurity security = directory
                ? (FileSystemSecurity)Directory.GetAccessControl(path, sections) : File.GetAccessControl(path, sections);
            return new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
        }

        private static void AssertProtectedAcl(string path, bool directory)
        {
            RawSecurityDescriptor security = PathSecurity(path, directory);
            RawAcl acl = security.DiscretionaryAcl;
            if ((!Admins.Equals(security.Owner) && !SystemUser.Equals(security.Owner)) || acl == null || acl.Count != 2 ||
                (directory && (security.ControlFlags & ControlFlags.DiscretionaryAclProtected) == 0))
                throw new TernException("The reserved Tern path is not protected for Administrators and SYSTEM: " + path);

            AceFlags inheritance = directory ? DirectoryInheritance : AceFlags.None;
            bool admins = false, system = false;
            foreach (GenericAce entry in acl)
            {
                var rule = entry as CommonAce;
                if (rule == null || rule.IsCallback || rule.AceQualifier != AceQualifier.AccessAllowed ||
                    rule.AccessMask != (int)FileSystemRights.FullControl || (rule.AceFlags & ~AceFlags.Inherited) != inheritance)
                    throw new TernException("Unexpected access rules at the reserved Windows path: " + path);
                admins |= Admins.Equals(rule.SecurityIdentifier);
                system |= SystemUser.Equals(rule.SecurityIdentifier);
            }
            if (!admins || !system)
                throw new TernException("Unexpected owner permissions at the reserved Windows path: " + path);
        }

        private static void RestrictAcl(FileSystemSecurity security, InheritanceFlags inheritance)
        {
            security.SetOwner(Admins);
            security.SetAccessRuleProtection(true, false);
            foreach (SecurityIdentifier sid in new[] { Admins, SystemUser })
                security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                    inheritance, PropagationFlags.None, AccessControlType.Allow));
        }

        private static bool TrustedProgramOwner(SecurityIdentifier sid)
        {
            return Admins.Equals(sid) || SystemUser.Equals(sid) || Installer.Equals(sid);
        }

        private static void AssertProgramAcl(string path, bool directory, bool root)
        {
            RawSecurityDescriptor security = PathSecurity(path, directory);
            if (!TrustedProgramOwner(security.Owner))
                throw new TernException("Windows Program Files or WireGuard has an unexpected owner: " + path);

            // Stock Windows lets users create their own directories at the drive root. They must
            // not be able to delete/replace Program Files, nor write inside any reserved directory.
            const int genericAll = 0x10000000, genericWrite = 0x40000000;
            int mask = genericAll | (int)(FileSystemRights.DeleteSubdirectoriesAndFiles |
                FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership);
            if (!root) mask |= genericWrite | (int)(FileSystemRights.Write | FileSystemRights.Delete);
            RawAcl acl = security.DiscretionaryAcl;
            if (acl == null)
                throw new TernException("Windows Program Files or WireGuard has no protective access rules: " + path);

            foreach (GenericAce entry in acl)
            {
                if ((entry.AceFlags & AceFlags.InheritOnly) != 0) continue;
                var rule = entry as QualifiedAce;
                if (rule == null || (rule.AceQualifier == AceQualifier.AccessAllowed &&
                    !TrustedProgramOwner(rule.SecurityIdentifier) && (rule.AccessMask & mask) != 0))
                    throw new TernException("Windows Program Files or WireGuard grants untrusted write access: " + path);
            }
        }

        internal static TernService ReadService()
        {
            return TernService.Open(IsAdmin);
        }

        internal static void AssertAdapterOwnership(TernService service)
        {
            int count = 0;
            foreach (ManagementBaseObject adapter in FindAdapters())
                if (++count > 1 || service == null || !IsWireGuard(adapter))
                    throw new TernException("A foreign adapter already uses the reserved Tern name. It was not modified.");
        }

        internal static bool NetworkHealthy(string address, string serverAddress)
        {
            uint index = 0;
            foreach (ManagementBaseObject adapter in FindAdapters())
            {
                // IF_OPER_STATUS_UP
                if (index != 0 || !IsWireGuard(adapter) || !IsNumber(adapter["InterfaceOperationalStatus"], 1))
                    return false;
                index = Convert.ToUInt32(adapter["InterfaceIndex"], CultureInfo.InvariantCulture);
                if (index == 0) return false;
            }
            if (index == 0) return false;

            // AF_INET = 2; Store = 1 is ActiveStore. The Windows stack also creates its own
            // multicast/broadcast routes; inspect the reserved server host route, not those.
            string ipv4 = " WHERE InterfaceIndex = " + index.ToString(CultureInfo.InvariantCulture) +
                " AND AddressFamily = 2 AND Store = 1";
            string destination = serverAddress + "/32";
            return ExactlyOne(Query("SELECT IPAddress, PrefixLength FROM MSFT_NetIPAddress" + ipv4),
                    row => (string)row["IPAddress"] == address && IsNumber(row["PrefixLength"], 32)) &&
                ExactlyOne(Query("SELECT Forwarding FROM MSFT_NetIPInterface" + ipv4), row => IsNumber(row["Forwarding"], 0)) &&
                ExactlyOne(Query("SELECT NextHop FROM MSFT_NetRoute" + ipv4 + " AND DestinationPrefix = '" + destination + "'"),
                    row => (string)row["NextHop"] == "0.0.0.0");
        }

        private static bool IsWireGuard(ManagementBaseObject adapter)
        {
            return WireGuardDescription.IsMatch((string)adapter["InterfaceDescription"] ?? "");
        }

        private static IEnumerable<ManagementBaseObject> FindAdapters()
        {
            // Unlike Get-NetAdapter's default view, the provider query includes hidden adapters.
            return Query("SELECT InterfaceDescription, InterfaceIndex, InterfaceOperationalStatus FROM MSFT_NetAdapter WHERE Name = '" + Tunnel + "'");
        }

        private static IEnumerable<ManagementBaseObject> Query(string query)
        {
            using (var search = new ManagementObjectSearcher(CimNamespace, query))
            using (ManagementObjectCollection results = search.Get())
                foreach (ManagementBaseObject row in results)
                    using (row) yield return row;
        }

        private static bool ExactlyOne(IEnumerable<ManagementBaseObject> rows, Func<ManagementBaseObject, bool> matches)
        {
            bool found = false;
            foreach (ManagementBaseObject row in rows)
            {
                if (found || !matches(row)) return false;
                found = true;
            }
            return found;
        }

        private static bool IsNumber(object value, uint expected)
        {
            return value != null && Convert.ToUInt32(value, CultureInfo.InvariantCulture) == expected;
        }
    }

    internal sealed class TernService : IDisposable
    {
        private const string Name = "WireGuardTunnel$" + TernPlatform.Tunnel;
        private const uint ScManagerConnect = 0x0001;
        private const uint ServiceQueryConfig = 0x0001, ServiceChangeConfig = 0x0002, ServiceQueryStatus = 0x0004;
        private const uint ServiceStart = 0x0010, ServiceStop = 0x0020;
        private const uint ServiceWin32OwnProcess = 0x0010, ServiceAutoStart = 2, ServiceNoChange = 0xffffffff;
        private const uint ServiceControlStop = 1;
        private const int ErrorServiceDoesNotExist = 1060;
        private const string TunnelVerb = " /tunnelservice ";
        private static readonly string ExecutableArgument = ServiceArgument(TernPlatform.WireGuard);
        private static readonly string ExpectedImage = ExecutableArgument + TunnelVerb + ServiceArgument(TernPlatform.ProfilePath);
        private readonly ServiceHandle handle;

        private TernService(ServiceHandle handle)
        {
            this.handle = handle;
        }

        internal static TernService Open(bool mayChange)
        {
            ServiceHandle service;
            using (ServiceHandle manager = OpenSCManagerW(null, null, ScManagerConnect))
            {
                if (manager.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                uint access = ServiceQueryConfig | ServiceQueryStatus;
                if (mayChange) access |= ServiceChangeConfig | ServiceStart | ServiceStop;
                service = OpenServiceW(manager, Name, access);
                if (service.IsInvalid)
                {
                    int error = Marshal.GetLastWin32Error();
                    service.Dispose();
                    if (error == ErrorServiceDoesNotExist) return null;
                    throw new Win32Exception(error);
                }
            }
            var result = new TernService(service);
            try
            {
                result.Automatic = result.ReadOwnedStartType() == ServiceAutoStart;
                return result;
            }
            catch
            {
                result.Dispose();
                throw;
            }
        }

        internal bool Automatic { get; private set; }

        internal ServiceControllerStatus Status
        {
            get
            {
                ServiceStatus status;
                if (!QueryServiceStatus(handle, out status)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return (ServiceControllerStatus)status.CurrentState;
            }
        }

        internal void Stop()
        {
            ReadOwnedStartType();
            ServiceStatus ignored;
            if (!ControlService(handle, ServiceControlStop, out ignored))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        internal void Start()
        {
            ReadOwnedStartType();
            if (!StartServiceW(handle, 0, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        internal void MakeAutomatic()
        {
            if (ReadOwnedStartType() == ServiceAutoStart)
            {
                Automatic = true;
                return;
            }
            if (!ChangeServiceConfigW(handle, ServiceNoChange, ServiceAutoStart, ServiceNoChange,
                null, null, IntPtr.Zero, null, null, null, null))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            Automatic = true;
        }

        public void Dispose()
        {
            handle.Dispose();
        }

        private uint ReadOwnedStartType()
        {
            // QueryServiceConfigW documents 8 KiB as the maximum buffer size.
            const int size = 8192;
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                uint ignored;
                if (!QueryServiceConfigW(handle, buffer, size, out ignored))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                var config = Marshal.PtrToStructure<ServiceConfig>(buffer);
                string image = Marshal.PtrToStringUni(config.BinaryPathName);
                if (config.ServiceType != ServiceWin32OwnProcess ||
                    !String.Equals(Marshal.PtrToStringUni(config.ServiceStartName), "LocalSystem", StringComparison.OrdinalIgnoreCase) ||
                    !String.Equals(image, ExpectedImage, StringComparison.OrdinalIgnoreCase) ||
                    String.CompareOrdinal(image, ExecutableArgument.Length, TunnelVerb, 0, TunnelVerb.Length) != 0)
                    throw new TernException("The reserved WireGuard service already exists with a foreign executable, profile, or identity. It was not modified.");
                return config.StartType;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private static string ServiceArgument(string path)
        {
            // Go's service manager quotes path arguments containing whitespace.
            return path.IndexOf(' ') < 0 && path.IndexOf('\t') < 0 ? path : "\"" + path + "\"";
        }

        private sealed class ServiceHandle : SafeHandleZeroOrMinusOneIsInvalid
        {
            private ServiceHandle() : base(true) { }
            protected override bool ReleaseHandle() { return CloseServiceHandle(handle); }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ServiceConfig
        {
            internal uint ServiceType, StartType, ErrorControl;
            internal IntPtr BinaryPathName, LoadOrderGroup;
            internal uint TagId;
            internal IntPtr Dependencies, ServiceStartName, DisplayName;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ServiceStatus
        {
            internal uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern ServiceHandle OpenSCManagerW(string machineName, string databaseName, uint access);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern ServiceHandle OpenServiceW(ServiceHandle manager, string serviceName, uint access);

        [DllImport("advapi32.dll", ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseServiceHandle(IntPtr service);

        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryServiceConfigW(ServiceHandle service, IntPtr config, uint size, out uint needed);

        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryServiceStatus(ServiceHandle service, out ServiceStatus status);

        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ControlService(ServiceHandle service, uint control, out ServiceStatus status);

        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool StartServiceW(ServiceHandle service, uint argumentCount, IntPtr arguments);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ChangeServiceConfigW(ServiceHandle service, uint serviceType, uint startType, uint errorControl,
            string binaryPath, string loadOrderGroup, IntPtr tagId, string dependencies, string startName, string password, string displayName);
    }
}
