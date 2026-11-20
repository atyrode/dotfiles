using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Management;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
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
        private const string ForeignAdapter = "A foreign adapter already uses the reserved Tern name. It was not modified.";
        private const string ForeignRoute = "Another adapter already has the Tern server /32 route. It was not modified.";
        private const string ActiveIPv4 = " AND AddressFamily = 2 AND Store = 1";
        private const string CimNamespace = @"root\StandardCimv2";
        private const AceFlags DirectoryInheritance = AceFlags.ContainerInherit | AceFlags.ObjectInherit;
        private static readonly DevPropKey WireGuardNameProperty = new DevPropKey
        {
            Format = new Guid("65726957-7547-7261-644e-616d654b6579"),
            Id = 3 // WireGuardNT's DEVPKEY_WireGuard_Name
        };

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

        internal static void AssertNetworkOwnership(TernService service, string serverAddress, Func<bool> matchesProfileKey)
        {
            ReservedAdapter adapter = ReadReservedAdapter();
            if (adapter.Index != 0 &&
                (service == null || service.Status != ServiceControllerStatus.Running || !matchesProfileKey()))
                throw new TernException(ForeignAdapter);
            ReadServerHostRoute(serverAddress, adapter.Index);
        }

        internal static void AssertStartNetworkClear(string serverAddress)
        {
            // WireGuard can rename the existing occupant to free an alias. A stopped
            // service does not authorize that, even if the occupant is a WireGuard NIC.
            if (ReadReservedAdapter().Index != 0)
                throw new TernException(ForeignAdapter);
            ReadServerHostRoute(serverAddress, 0);
        }

        internal static bool NetworkHealthy(string address, string serverAddress)
        {
            ReservedAdapter adapter = ReadReservedAdapter();
            bool hostRoute = ReadServerHostRoute(serverAddress, adapter.Index);
            if (!adapter.HasAlias || !adapter.Up || !hostRoute) return false;

            string ipv4 = " WHERE InterfaceIndex = " + adapter.Index.ToString(CultureInfo.InvariantCulture) + ActiveIPv4;
            return ExactlyOne(Query("SELECT IPAddress, PrefixLength FROM MSFT_NetIPAddress" + ipv4),
                    row => (string)row["IPAddress"] == address && IsNumber(row["PrefixLength"], 32)) &&
                ExactlyOne(Query("SELECT Forwarding FROM MSFT_NetIPInterface" + ipv4), row => IsNumber(row["Forwarding"], 0)) &&
                IsBestRoute(serverAddress, adapter.Index);
        }

        private static bool ReadServerHostRoute(string serverAddress, uint ownedIndex)
        {
            // Match globally, not only on the expected NIC. Even a competing /32 of
            // lower priority is a conflict. Broader routes do not claim this host route.
            bool found = false, uniqueOnLink = false;
            foreach (ManagementBaseObject row in Query("SELECT InterfaceIndex, NextHop FROM MSFT_NetRoute" +
                " WHERE DestinationPrefix = '" + serverAddress + "/32'" + ActiveIPv4))
            {
                if (ownedIndex == 0 || !IsNumber(row["InterfaceIndex"], ownedIndex))
                    throw new TernException(ForeignRoute);
                uniqueOnLink = !found && (string)row["NextHop"] == "0.0.0.0";
                found = true;
            }
            return uniqueOnLink;
        }

        private static bool IsBestRoute(string serverAddress, uint ownedIndex)
        {
            // GetBestRoute is an unbound IPv4 lookup; do not force the tunnel as the source.
            uint destination = BitConverter.ToUInt32(IPAddress.Parse(serverAddress).GetAddressBytes(), 0);
            IPv4Route route;
            return GetBestRoute(destination, 0, out route) == 0 &&
                route.Index == ownedIndex && route.Destination == destination &&
                route.Mask == UInt32.MaxValue && route.NextHop == 0;
        }

        private struct ReservedAdapter
        {
            internal uint Index;
            internal bool HasAlias, Up;
        }

        private static ReservedAdapter ReadReservedAdapter()
        {
            var result = new ReservedAdapter();
            // Include hidden adapters, and identify the kernel adapter by the same
            // WireGuard device property wg.exe uses, not by the cosmetic interface description.
            foreach (ManagementBaseObject row in Query(
                "SELECT Name, PnPDeviceID, InterfaceIndex, InterfaceOperationalStatus FROM MSFT_NetAdapter"))
            {
                bool alias = String.Equals((string)row["Name"], Tunnel, StringComparison.OrdinalIgnoreCase);
                string deviceName = WireGuardDeviceName((string)row["PnPDeviceID"]);
                bool wireGuardName = String.Equals(deviceName, Tunnel, StringComparison.OrdinalIgnoreCase);
                if (!alias && !wireGuardName) continue;
                if (result.Index != 0 || !String.Equals(deviceName, Tunnel, StringComparison.Ordinal))
                    throw new TernException(ForeignAdapter);

                result.Index = Convert.ToUInt32(row["InterfaceIndex"], CultureInfo.InvariantCulture);
                if (result.Index == 0) throw new TernException(ForeignAdapter);
                result.HasAlias = alias;
                result.Up = IsNumber(row["InterfaceOperationalStatus"], 1); // IF_OPER_STATUS_UP
            }
            if (!result.HasAlias)
            {
                // Independently check the alias lookup WireGuardNT uses to find an
                // incumbent to rename, including any alias missing from the CIM view.
                ulong ignored;
                int error = ConvertInterfaceAliasToLuid(Tunnel, out ignored);
                if (error == 0) throw new TernException(ForeignAdapter);
                // FILE_NOT_FOUND, INVALID_PARAMETER (unknown alias), NOT_FOUND.
                if (error != 2 && error != 87 && error != 1168) throw new Win32Exception(error);
            }
            return result;
        }

        private static string WireGuardDeviceName(string deviceId)
        {
            if (deviceId == null || !deviceId.StartsWith(@"SWD\WireGuard\", StringComparison.OrdinalIgnoreCase))
                return null;

            uint device;
            if (CM_Locate_DevNodeW(out device, deviceId, 0) != 0) return null;
            DevPropKey key = WireGuardNameProperty;
            var name = new StringBuilder(128); // WireGuardNT's MAX_ADAPTER_NAME
            uint bytes = (uint)name.Capacity * sizeof(char), type;
            return CM_Get_DevNode_PropertyW(device, ref key, out type, name, ref bytes, 0) == 0 &&
                type == 0x12 ? name.ToString() : null; // DEVPROP_TYPE_STRING
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DevPropKey
        {
            internal Guid Format;
            internal uint Id;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IPv4Route
        {
            // MIB_IPFORWARDROW
            internal uint Destination, Mask, Policy, NextHop, Index, Type, Protocol, Age, NextHopAs;
            internal uint Metric1, Metric2, Metric3, Metric4, Metric5;
        }

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint CM_Locate_DevNodeW(out uint device, string deviceId, uint flags);

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint CM_Get_DevNode_PropertyW(uint device, ref DevPropKey key, out uint type,
            [Out] StringBuilder value, ref uint size, uint flags);

        [DllImport("iphlpapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int ConvertInterfaceAliasToLuid(string name, out ulong luid);

        [DllImport("iphlpapi.dll", ExactSpelling = true)]
        private static extern uint GetBestRoute(uint destination, uint source, out IPv4Route route);

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
        private const uint ScManagerConnect = 0x0001, ScManagerCreateService = 0x0002;
        private const uint ServiceQueryConfig = 0x0001, ServiceChangeConfig = 0x0002, ServiceQueryStatus = 0x0004;
        private const uint ServiceStart = 0x0010, ServiceStop = 0x0020, Delete = 0x00010000;
        private const uint ServiceWin32OwnProcess = 0x0010, ServiceAutoStart = 2, ServiceDemandStart = 3, ServiceNoChange = 0xffffffff;
        private const uint ServiceControlStop = 1, ServiceErrorNormal = 1;
        private const uint ServiceConfigSidInfo = 5, ServiceSidTypeUnrestricted = 1;
        private const int ErrorServiceDoesNotExist = 1060, ErrorServiceMarkedForDelete = 1072, ErrorServiceExists = 1073;
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
                result.Automatic = result.VerifyAutomatic();
                return result;
            }
            catch
            {
                result.Dispose();
                throw;
            }
        }

        internal static TernService Create()
        {
            using (ServiceHandle manager = OpenSCManagerW(null, null, ScManagerCreateService))
            {
                if (manager.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());

                // Match WireGuard's InstallTunnel settings, except defer boot startup until
                // after the explicit, network-checked Start. Dependencies are a UTF-16 MULTI_SZ.
                ServiceHandle service = CreateServiceW(manager, Name, "WireGuard Tunnel: " + TernPlatform.Tunnel,
                    ServiceQueryConfig | ServiceQueryStatus | ServiceChangeConfig | ServiceStart | Delete,
                    ServiceWin32OwnProcess, ServiceDemandStart, ServiceErrorNormal, ExpectedImage,
                    null, IntPtr.Zero, "Nsi\0TcpIp\0\0", null, null);
                if (service.IsInvalid)
                {
                    int error = Marshal.GetLastWin32Error();
                    service.Dispose();
                    if (error == ErrorServiceExists || error == ErrorServiceMarkedForDelete)
                        throw new TernException("The reserved service changed during Apply; inspect its state before retrying.");
                    throw new Win32Exception(error);
                }

                var info = new ServiceSidInfo { SidType = ServiceSidTypeUnrestricted };
                if (!ChangeServiceConfig2W(service, ServiceConfigSidInfo, ref info))
                {
                    int error = Marshal.GetLastWin32Error();
                    // Roll back only on the handle returned by successful creation, never by name.
                    try { DeleteService(service); }
                    finally { service.Dispose(); }
                    throw new Win32Exception(error);
                }
                return new TernService(service);
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

        internal bool VerifyAutomatic()
        {
            return ReadOwnedStartType() == ServiceAutoStart;
        }

        internal void MakeAutomatic()
        {
            if (VerifyAutomatic())
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

        [StructLayout(LayoutKind.Sequential)]
        private struct ServiceSidInfo
        {
            internal uint SidType;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern ServiceHandle OpenSCManagerW(string machineName, string databaseName, uint access);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern ServiceHandle OpenServiceW(ServiceHandle manager, string serviceName, uint access);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern ServiceHandle CreateServiceW(ServiceHandle manager, string serviceName, string displayName,
            uint access, uint serviceType, uint startType, uint errorControl, string binaryPath,
            string loadOrderGroup, IntPtr tagId, string dependencies, string startName, string password);

        [DllImport("advapi32.dll", ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeleteService(ServiceHandle service);

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

        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ChangeServiceConfig2W(ServiceHandle service, uint infoLevel, ref ServiceSidInfo info);
    }
}
