using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Management;
using System.Net;
using System.Runtime.InteropServices;
using System.Security;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Atyrode.Windows
{
    internal sealed class TernException : Exception
    {
        internal TernException(string detail) : base(detail) { }
    }

    internal static class TernTunnel
    {
        private const string AdminInspection = "Apply needs administrator access to inspect protected Windows state; convergence is not verified.";
        private const string AdminApply = "Windows administrator access is required to verify or change the protected Tern tunnel. Open Windows Terminal as administrator, run wsl -d atyrode-nixos, then run atyrode windows apply.";
        private const string InstallWireGuard = "Install the native Windows WireGuard client before applying the Tern tunnel.";
        private const string MissingIdentity = "The reserved Tern profile is missing but an identity is already expected. Restore the original profile; it will not be replaced.";
        private const string ForeignProfile = "The reserved Tern profile is corrupt or foreign. Restore the original profile rather than replacing its identity.";
        private const string ServiceChanged = "The reserved service changed during Apply; inspect its state before retrying.";
        private const string VerifyFailed = "The reserved service, adapter IPv4 address, /32 route, or WireGuard peer did not verify. Check the WireGuard log.";
        private static readonly TimeSpan ServiceWait = TimeSpan.FromSeconds(30);
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        private static readonly Regex ConfigShape = new Regex(
            @"\A\[Interface\]\nPrivateKey = ([A-Za-z0-9+/]{43}=)\nAddress = ([0-9.]+)/32\n\n\[Peer\]\nPublicKey = ([A-Za-z0-9+/]{43}=)\nAllowedIPs = ([0-9.]+)/32\nEndpoint = ([A-Za-z0-9.-]+):([1-9][0-9]{0,4})\nPersistentKeepalive = 25\n?\z");

        private sealed class Desired
        {
            internal string Address, ServerAddress, ServerPublicKey, ExpectedPublicKey, Endpoint;
            internal int Port;
        }

        private enum Health { Drift, Verified, Unreadable }

        public static int Main(string[] args)
        {
            string action = "validating the installed native package";
            try
            {
                if (args.Length != 1 || (args[0] != "Plan" && args[0] != "Apply"))
                    throw new TernException("Usage: tern-tunnel.exe Plan|Apply");
                bool apply = args[0] == "Apply";
                Desired desired = ReadManifest();
                action = "checking the Program Files boundary";
                TernPlatform.AssertProgramFiles();
                bool admin = TernPlatform.IsAdmin;
                action = "inspecting the reserved service and protected profile";
                bool installed;
                try
                {
                    using (TernService service = TernPlatform.ReadService())
                    {
                        bool profile = CheckIdentityPath(desired, service);
                        installed = TernPlatform.WireGuardInstalled();
                        if (admin)
                            TernPlatform.AssertAdapterOwnership(service);
                        if (!apply)
                            return Plan(desired, service, profile, installed, admin);
                    }
                }
                catch (Exception ex)
                {
                    if (admin || !IsDenied(ex))
                        throw;
                    return apply ? Report("inspect", AdminApply, exitCode: 1) : Report("inspect", AdminInspection);
                }
                if (!installed)
                    throw new TernException(InstallWireGuard);
                if (!admin)
                    return Report("inspect", AdminApply, exitCode: 1);

                action = "applying or verifying the reserved WireGuard service and its adapter";
                using (TernPlatform.LockStore())
                {
                    // Everything that authorizes a read or mutation is freshly checked under the Apply lock.
                    using (TernService service = TernPlatform.ReadService())
                    {
                        bool profile = CheckIdentityPath(desired, service);
                        if (!TernPlatform.WireGuardInstalled())
                            throw new TernException(InstallWireGuard);
                        TernPlatform.AssertAdapterOwnership(service);
                        return ReconcileProfile(desired, service, profile, true);
                    }
                }
            }
            catch (TernException ex)
            {
                return Report("blocked", ex.Message, exitCode: 1);
            }
            catch (Exception ex)
            {
                // Exception messages and native command output may contain protected profile data.
                string detail = IsDenied(ex)
                    ? "Access denied while " + action + ". Check Windows permissions and administrator access."
                    : "Windows failed while " + action + ". Check the native WireGuard installation and the reserved service.";
                return Report("blocked", detail, exitCode: 1);
            }
        }

        private static int Report(string status, string detail, string publicKey = null, bool enrolled = false, int exitCode = 0)
        {
            if (exitCode != 0)
                Console.Error.WriteLine(detail);
            Console.WriteLine(Json.Serialize(new { status, publicKey, enrolled, detail }));
            return exitCode;
        }

        private static int Configured(Desired desired, string publicKey)
        {
            bool enrolled = desired.ExpectedPublicKey != null;
            string detail = enrolled ? "The automatic Windows Tern tunnel and approved local identity are verified."
                : "The automatic Windows Tern tunnel is verified locally; its public key is pending enrollment.";
            return Report("configured", detail, publicKey, enrolled);
        }

        private static bool IsDenied(Exception ex)
        {
            for (; ex != null; ex = ex.InnerException)
            {
                var nativeError = ex as Win32Exception;
                var managementError = ex as ManagementException;
                if (ex is UnauthorizedAccessException || ex is SecurityException || ex.HResult == unchecked((int)0x80070005) ||
                    (nativeError != null && nativeError.NativeErrorCode == 5) ||
                    (managementError != null && managementError.ErrorCode == ManagementStatus.AccessDenied))
                    return true;
            }
            return false;
        }

        private static Desired ReadManifest()
        {
            string path = Path.Combine(Path.GetDirectoryName(typeof(TernTunnel).Assembly.Location), "tern-tunnel.json");
            byte[] bytes = File.ReadAllBytes(path);
            Dictionary<string, object> data;
            try
            {
                string text = new UTF8Encoding(false, true).GetString(bytes).TrimStart('\uFEFF');
                data = Json.DeserializeObject(text) as Dictionary<string, object>;
            }
            catch (ArgumentException)
            {
                throw new TernException("The installed Tern manifest is not valid UTF-8 JSON.");
            }
            catch (InvalidOperationException)
            {
                throw new TernException("The installed Tern manifest is not valid UTF-8 JSON.");
            }
            if (data == null || data.Count != 6 || !data.ContainsKey("address") || !data.ContainsKey("serverAddress") ||
                !data.ContainsKey("serverPublicKey") || !data.ContainsKey("expectedPublicKey") || !data.ContainsKey("endpoint") || !data.ContainsKey("port"))
                throw new TernException("The installed Tern manifest has an invalid schema.");

            var desired = new Desired
            {
                Address = data["address"] as string,
                ServerAddress = data["serverAddress"] as string,
                ServerPublicKey = data["serverPublicKey"] as string,
                ExpectedPublicKey = data["expectedPublicKey"] as string,
                Endpoint = data["endpoint"] as string
            };
            if (!IsIPv4(desired.Address, false) || !IsIPv4(desired.ServerAddress, false) || desired.Address == desired.ServerAddress)
                throw new TernException("The Tern manifest must name distinct unicast IPv4 client and server addresses.");
            if (!IsKey(desired.ServerPublicKey) || (data["expectedPublicKey"] != null &&
                (!IsKey(desired.ExpectedPublicKey) || desired.ExpectedPublicKey == desired.ServerPublicKey)))
                throw new TernException("The Tern manifest has a missing, invalid, or conflicting public key.");
            if (!IsEndpoint(desired.Endpoint) || !(data["port"] is int) || (int)data["port"] < 1 || (int)data["port"] > 65535)
                throw new TernException("The Tern manifest must name a valid DNS or IPv4 endpoint and UDP port.");
            desired.Port = (int)data["port"];
            return desired;
        }

        private static bool IsIPv4(string value, bool allowLoopback)
        {
            IPAddress address;
            if (value == null || !Regex.IsMatch(value, @"\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z") ||
                !IPAddress.TryParse(value, out address) || address.ToString() != value)
                return false;
            byte first = address.GetAddressBytes()[0];
            return first > 0 && (allowLoopback || first != 127) && first < 224;
        }

        private static bool IsKey(string value)
        {
            // A 32-byte Base64 key has two zero pad bits in the last digit.
            if (value == null || !Regex.IsMatch(value, @"\A[A-Za-z0-9+/]{43}=\z") ||
                "AEIMQUYcgkosw048".IndexOf(value[42]) < 0)
                return false;
            for (int i = 0; i < 43; i++)
                if (value[i] != 'A')
                    return true;
            return false;
        }

        private static bool IsEndpoint(string value)
        {
            if (value == null || value.Length > 253)
                return false;
            if (Regex.IsMatch(value, @"\A[0-9.]+\z"))
                return IsIPv4(value, true);
            return Regex.IsMatch(value, @"\A(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z");
        }

        private static bool CheckIdentityPath(Desired desired, TernService service)
        {
            bool profile = TernPlatform.ProfileExists();
            if (!profile && (desired.ExpectedPublicKey != null || service != null))
                throw new TernException(MissingIdentity);
            return profile;
        }

        private static string ReadProfile()
        {
            try { return TernProfileStore.Read(TernPlatform.ProfilePath).Replace("\r\n", "\n"); }
            catch (Exception ex)
            {
                if (IsDenied(ex))
                    throw;
                throw new TernException("The reserved Tern profile could not be decrypted. Restore the original profile rather than replacing its identity.");
            }
        }

        private static string ReadPrivateKey(string text)
        {
            Match shape = ConfigShape.Match(text);
            if (!shape.Success)
                throw new TernException(ForeignProfile);
            string privateKey = shape.Groups[1].Value;
            string address = shape.Groups[2].Value;
            string serverAddress = shape.Groups[4].Value;
            if (!IsKey(privateKey) || !IsIPv4(address, false) || !IsKey(shape.Groups[3].Value) ||
                !IsIPv4(serverAddress, false) || address == serverAddress ||
                !IsEndpoint(shape.Groups[5].Value) || int.Parse(shape.Groups[6].Value, CultureInfo.InvariantCulture) > 65535)
                throw new TernException(ForeignProfile);
            return privateKey;
        }

        private static string BuildConfig(Desired desired, string privateKey)
        {
            // No interface DNS, scripts, default route, or additional peers.
            return string.Format(CultureInfo.InvariantCulture,
                "[Interface]\nPrivateKey = {0}\nAddress = {1}/32\n\n[Peer]\nPublicKey = {2}\nAllowedIPs = {3}/32\nEndpoint = {4}:{5}\nPersistentKeepalive = 25",
                privateKey, desired.Address, desired.ServerPublicKey, desired.ServerAddress, desired.Endpoint, desired.Port);
        }

        // null denotes a native failure; stdout and stderr are never forwarded to the caller.
        private static string RunWireGuard(string executable, string arguments, int timeout, string privateKey = null)
        {
            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            var info = new ProcessStartInfo(executable, arguments)
            {
                WorkingDirectory = system,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.ASCII,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            info.EnvironmentVariables["PATH"] = system;
            using (var input = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable))
            using (Process process = StartWithInput(info, input))
            {
                var timer = Stopwatch.StartNew();
                var output = process.StandardOutput.ReadToEndAsync();
                var errors = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
                // Close the parent copies so pubkey sees EOF after the raw Base64 bytes.
                using (input)
                {
                    input.DisposeLocalCopyOfClientHandle();
                    if (privateKey != null)
                    {
                        byte[] keyBytes = Encoding.ASCII.GetBytes(privateKey);
                        try { input.Write(keyBytes, 0, keyBytes.Length); }
                        finally { Array.Clear(keyBytes, 0, keyBytes.Length); }
                    }
                }
                if (!process.WaitForExit(timeout) ||
                    !Task.WaitAll(new Task[] { output, errors }, timeout - (int)Math.Min(timeout, timer.ElapsedMilliseconds)))
                {
                    if (!process.HasExited)
                        process.Kill();
                    throw new TernException("Native WireGuard did not complete in time. Check the reserved service in the WireGuard log.");
                }
                return process.ExitCode == 0 ? output.Result.Trim() : null;
            }
        }

        private const int StdInputHandle = -10;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetStdHandle(int handle, IntPtr value);

        private static Process StartWithInput(ProcessStartInfo info, AnonymousPipeServerStream input)
        {
            // Framework's redirected stdin can prepend the console encoding's BOM. Pass our
            // byte pipe as inherited stdin instead, changing only this process's handle table.
            IntPtr previous = GetStdHandle(StdInputHandle);
            if (previous == new IntPtr(-1) || !SetStdHandle(StdInputHandle, input.ClientSafePipeHandle.DangerousGetHandle()))
                throw new Win32Exception();
            Process process = null;
            try
            {
                process = Process.Start(info);
                return process;
            }
            finally
            {
                if (!SetStdHandle(StdInputHandle, previous))
                {
                    var error = new Win32Exception();
                    if (process != null)
                        process.Dispose();
                    throw error;
                }
            }
        }

        private static string GeneratePrivateKey()
        {
            string key = RunWireGuard(TernPlatform.Wg, "genkey", 10000);
            if (!IsKey(key))
                throw new TernException("WireGuard did not return a valid private key for the reserved Tern profile.");
            return key;
        }

        private static string GetPublicKey(Desired desired, string privateKey)
        {
            string key = RunWireGuard(TernPlatform.Wg, "pubkey", 10000, privateKey);
            if (!IsKey(key))
                throw new TernException("WireGuard could not derive the public key for the reserved Tern profile.");
            if (desired.ExpectedPublicKey != null && key != desired.ExpectedPublicKey)
                throw new TernException("The reserved Tern public key does not match the approved identity. The Windows profile was not modified.");
            if (key == desired.ServerPublicKey)
                throw new TernException("The client key conflicts with the configured Tern server key.");
            return key;
        }

        private static Health CheckHealth(TernService service, Desired desired, string publicKey)
        {
            if (service == null || service.Status != ServiceControllerStatus.Running || !TernPlatform.NetworkHealthy(desired.Address, desired.ServerAddress))
                return Health.Drift;

            Health result = CompareLive("public-key", publicKey);
            if (result != Health.Verified) return result;
            result = CompareLive("peers", desired.ServerPublicKey);
            if (result != Health.Verified) return result;
            result = CompareLive("allowed-ips", desired.ServerPublicKey + "\t" + desired.ServerAddress + "/32");
            if (result != Health.Verified) return result;
            // Check the endpoint against the protected profile only; WireGuard peers roam.
            return CompareLive("persistent-keepalive", desired.ServerPublicKey + "\t25");
        }

        private static Health CompareLive(string field, string expected)
        {
            string value = RunWireGuard(TernPlatform.Wg, "show " + TernPlatform.Tunnel + " " + field, 10000);
            return value == null ? Health.Unreadable : value == expected ? Health.Verified : Health.Drift;
        }

        private static int Plan(Desired desired, TernService service, bool profile, bool installed, bool admin)
        {
            if (!profile)
                return Report("missing", "The Windows Tern identity is not provisioned. Apply creates a new Windows-local key.");
            if (!installed)
                return Report("inspect", "Install the native Windows WireGuard client before verifying the protected Tern identity.");
            if (!admin)
                return Report("inspect", AdminInspection);

            return ReconcileProfile(desired, service, true, false);
        }

        private static int ReconcileProfile(Desired desired, TernService service, bool profile, bool apply)
        {
            string text = profile ? ReadProfile() : null;
            string privateKey = profile ? ReadPrivateKey(text) : GeneratePrivateKey();
            string publicKey = GetPublicKey(desired, privateKey);
            string config = BuildConfig(desired, privateKey);
            // The parser permits only one optional final newline.
            bool write = text == null || (text != config &&
                (text.Length != config.Length + 1 || !text.StartsWith(config, StringComparison.Ordinal)));
            Health health = write ? Health.Drift : CheckHealth(service, desired, publicKey);
            if (health == Health.Unreadable)
                throw new TernException(VerifyFailed);
            if (health == Health.Verified && service.Automatic)
                return Configured(desired, publicKey);
            if (!apply)
                return Report("change", "Apply reconciles the reserved Windows Tern profile or service without replacing its key.", publicKey, desired.ExpectedPublicKey != null);

            if (service != null && health != Health.Verified)
            {
                // Stop before writing, so an interruption cannot leave the service running with stale settings.
                ServiceControllerStatus status = service.Status;
                if (status != ServiceControllerStatus.Stopped)
                {
                    if (status != ServiceControllerStatus.StopPending)
                        service.Stop();
                    var stopTimer = Stopwatch.StartNew();
                    while (service.Status != ServiceControllerStatus.Stopped)
                    {
                        if (stopTimer.Elapsed >= ServiceWait)
                            throw new TernException("The reserved WireGuard service did not stop. Check the WireGuard log.");
                        Thread.Sleep(250);
                    }
                }
            }
            if (write)
            {
                try { TernProfileStore.Write(TernPlatform.ProfilePath, config); }
                catch (Exception ex)
                {
                    if (IsDenied(ex))
                        throw;
                    throw new TernException("Could not safely write the protected Tern profile. Check permissions on the reserved store.");
                }
                TernPlatform.AssertProfile();
            }

            if (service == null)
            {
                // The official installer can remove a stopped service of this name. Never invoke it over an existing service.
                using (TernService current = TernPlatform.ReadService())
                {
                    if (current != null)
                        throw new TernException(ServiceChanged);
                }
                if (RunWireGuard(TernPlatform.WireGuard, "/installtunnelservice \"" + TernPlatform.ProfilePath + "\"", 120000) == null)
                    throw new TernException("Could not install or start the reserved Tern tunnel service. Check the WireGuard log.");
            }
            else
            {
                if (!service.Automatic)
                    service.MakeAutomatic();
                if (health != Health.Verified)
                    service.Start();
            }

            // SCM can announce Running before the adapter and route are available.
            var timer = Stopwatch.StartNew();
            do
            {
                using (TernService current = TernPlatform.ReadService())
                {
                    if (current == null || current.Status == ServiceControllerStatus.Stopped)
                        break;
                    TernPlatform.AssertAdapterOwnership(current);
                    if (current.Automatic && CheckHealth(current, desired, publicKey) == Health.Verified)
                        return Configured(desired, publicKey);
                }
                Thread.Sleep(500);
            } while (timer.Elapsed < ServiceWait);
            throw new TernException(VerifyFailed);
        }
    }
}
