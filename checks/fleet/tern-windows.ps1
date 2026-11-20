#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Acceptance: $Message" }
}

# Capture both streams without printing any of the child output, even on failure.
# No shell is involved, and all arguments are fixed switches, names or file paths.
function Invoke-Captured {
    param(
        [string]$File,
        [string[]]$NativeArguments,
        [string]$Step,
        [int]$TimeoutSeconds = 30,
        [switch]$AllowFailure
    )
    $start = [Diagnostics.ProcessStartInfo]::new($File)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Arguments = ($NativeArguments | ForEach-Object {
        Assert-That ($_ -notmatch '["\r\n]|\\$') 'Unsupported argument to native process.'
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
    if ($null -ne $scratch) {
        $start.WorkingDirectory = $scratch
        $start.EnvironmentVariables['TEMP'] = $scratch
        $start.EnvironmentVariables['TMP'] = $scratch
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "Acceptance: $Step timed out after $TimeoutSeconds seconds."
        }
        Assert-That ($stdout.Wait(2000) -and $stderr.Wait(2000)) "$Step did not close its output streams."
        $code = $process.ExitCode
        if (-not $AllowFailure) { Assert-That ($code -eq 0) "$Step failed (exit $code)." }
        [pscustomobject]@{ Code = $code; Stdout = $stdout.Result; Stderr = $stderr.Result }
    } finally {
        $process.Dispose()
    }
}

function Wait-Until([string]$Step, [scriptblock]$Condition) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 300
    } while ($watch.Elapsed.TotalSeconds -lt 45)
    throw "Acceptance: $Step did not converge within 45 seconds."
}

function Get-ReservedService {
    Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -OperationTimeoutSec 5
}

function Get-ServiceProcess {
    $service = Get-ReservedService
    Assert-That ($null -ne $service -and $service.State -eq 'Running' -and $service.ProcessId -gt 0) 'Reserved service is not running.'
    $process = Get-Process -Id $service.ProcessId
    try { '{0}:{1}' -f $process.Id, $process.StartTime.ToUniversalTime().Ticks } finally { $process.Dispose() }
}

function Get-ServerRoutes {
    Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore |
        Where-Object DestinationPrefix -eq "$serverAddress/32"
}

function Get-ServerRouteState {
    (Get-ServerRoutes | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}' -f $_.InterfaceIndex, $_.InterfaceAlias, $_.NextHop, $_.RouteMetric, $_.Protocol
    } | Sort-Object) -join "`n"
}

function Set-TestManifest {
    $manifest | ConvertTo-Json -Compress | Set-Content -LiteralPath $manifestFile -Encoding Ascii
}

function Invoke-Tern([string]$Mode, [string]$Step, [switch]$ExpectFailure) {
    $result = Invoke-Captured $entry @($Mode) $Step -TimeoutSeconds 90 -AllowFailure
    $streams.Add($result.Stdout)
    $streams.Add($result.Stderr)
    $line = $result.Stdout.Trim()
    Assert-That ($line -match '^\{[^\r\n]*\}$') "$Step did not emit exactly one JSON object (exit $($result.Code))."
    try { $status = $line | ConvertFrom-Json } catch { throw "Acceptance: $Step emitted invalid status JSON (exit $($result.Code))." }
    $fields = @($status.PSObject.Properties.Name | Sort-Object) -join ','
    Assert-That ($fields -ceq 'detail,enrolled,publicKey,status') "$Step used an unexpected status schema."
    Assert-That ($status.status -cin @('missing', 'change', 'configured', 'inspect', 'blocked') -and $status.enrolled -is [bool] -and
        ($null -eq $status.publicKey -or ($status.publicKey -is [string] -and $status.publicKey -cmatch $publicKeyPattern)) -and
        $status.detail -is [string] -and -not [string]::IsNullOrWhiteSpace($status.detail)) "$Step emitted invalid status values."
    if ($ExpectFailure) {
        Assert-That ($result.Code -ne 0) "$Step unexpectedly succeeded (status $($status.status))."
    } else {
        # Only the helper's public diagnostic; never print raw streams or key-shaped values.
        $detail = $status.detail -replace '[A-Za-z0-9+/=_-]{32,}', '[redacted]' -replace '[\r\n]', ' '
        Assert-That ($result.Code -eq 0) "$Step failed (exit $($result.Code), status $($status.status)): $detail"
    }
    $status
}

function Assert-OwnedProfile {
    Assert-That (Test-Path -LiteralPath $profilePath -PathType Leaf) 'Native DPAPI config is missing.'
    $acl = Get-Acl -LiteralPath $profilePath
    $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    $sids = @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) -join ','
    Assert-That ($acl.AreAccessRulesProtected -and $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544' -and
        $sids -eq 'S-1-5-18,S-1-5-32-544') 'Native DPAPI config is not exclusively owned and ACL-protected by Administrators/SYSTEM.'
    $service = Get-ReservedService
    $expectedPath = '"{0}" /tunnelservice "{1}"' -f $wireguard, $profilePath
    Assert-That ($null -ne $service -and $service.PathName -ieq $expectedPath -and
        $service.StartMode -eq 'Auto' -and $service.StartName -eq 'LocalSystem') 'SCM does not bind an automatic LocalSystem service to the exact DPAPI config.'
}

function Assert-LiveTunnel([string]$PublicKey, [string]$PeerKey) {
    Wait-Until 'Running tunnel service, /32 address and server route' {
        $service = Get-ReservedService
        if ($null -eq $service -or $service.State -ne 'Running') { return $false }
        $addresses = @(Get-NetIPAddress -InterfaceAlias $tunnel -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $expectedAddress = @($addresses | Where-Object { $_.IPAddress -eq $manifest.address -and $_.PrefixLength -eq 32 })
        if (-not $expectedAddress -or $addresses.Count -ne $expectedAddress.Count) { return $false }
        $routes = @(Get-NetRoute -InterfaceAlias $tunnel -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
        $serverRoute = @($routes | Where-Object { $_.DestinationPrefix -eq "$($manifest.serverAddress)/32" -and $_.NextHop -eq '0.0.0.0' })
        $defaultRoute = @($routes | Where-Object DestinationPrefix -eq '0.0.0.0/0')
        $serverRoute.Count -gt 0 -and $defaultRoute.Count -eq 0
    }
    $interface = Get-NetIPInterface -InterfaceAlias $tunnel -AddressFamily IPv4
    Assert-That ($interface.Forwarding -eq 'Disabled') 'IPv4 forwarding was enabled on the tunnel adapter.'
    $peerFields = [ordered]@{
        'public-key' = $PublicKey
        'peers' = $PeerKey
        'allowed-ips' = "$PeerKey $($manifest.serverAddress)/32"
        'endpoints' = "$PeerKey $($manifest.endpoint):$($manifest.port)"
        'persistent-keepalive' = "$PeerKey 25"
        'latest-handshakes' = "$PeerKey 0"
    }
    foreach ($field in $peerFields.Keys) {
        $result = Invoke-Captured $wg @('show', $tunnel, $field) "Read live WireGuard $field"
        Assert-That (($result.Stdout.Trim() -replace '\s+', ' ') -ceq $peerFields[$field]) "Unexpected live WireGuard $field."
    }
}

function New-IsolatedAliasProfile([string]$Path, [string]$Name) {
    # WireGuard checks the DPAPI description against the tunnel basename.
    # Generate the key and seal the fixture before anything is written to disk.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

public static class TernAliasProfileFixture
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Blob
    {
        internal int Size;
        internal IntPtr Data;
    }

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref Blob input, string description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, uint flags, out Blob output);

    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static void Write(string path, string name)
    {
        const string header = "[Interface]\nPrivateKey = ";
        var key = new byte[32];
        var base64 = new char[44];
        var config = new byte[header.Length + base64.Length + 1];
        GCHandle pin = GCHandle.Alloc(config, GCHandleType.Pinned);
        Blob output = new Blob();
        try
        {
            using (RandomNumberGenerator random = RandomNumberGenerator.Create())
                random.GetBytes(key);
            key[0] &= 248;
            key[31] = (byte)((key[31] & 127) | 64);
            Convert.ToBase64CharArray(key, 0, key.Length, base64, 0);
            Encoding.ASCII.GetBytes(header, 0, header.Length, config, 0);
            Encoding.ASCII.GetBytes(base64, 0, base64.Length, config, header.Length);
            config[config.Length - 1] = (byte)'\n';

            var input = new Blob { Size = config.Length, Data = pin.AddrOfPinnedObject() };
            const uint uiForbidden = 1, localMachine = 4;
            if (!CryptProtectData(ref input, name, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                uiForbidden | localMachine, out output))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var encrypted = new byte[output.Size];
            Marshal.Copy(output.Data, encrypted, 0, encrypted.Length);
            File.WriteAllBytes(path, encrypted);
        }
        finally
        {
            Array.Clear(key, 0, key.Length);
            Array.Clear(base64, 0, base64.Length);
            Array.Clear(config, 0, config.Length);
            pin.Free();
            if (output.Data != IntPtr.Zero)
                LocalFree(output.Data);
        }
    }
}
'@
    [TernAliasProfileFixture]::Write($Path, $Name)
}

function Assert-NoPlaintext {
    # Independently decrypt only our ephemeral profile in memory, without loading
    # the production executable into the acceptance process.
    Add-Type -AssemblyName System.Security
    $encrypted = [IO.File]::ReadAllBytes($profilePath)
    $plaintext = $null
    try {
        # CryptProtectData blobs start with version 1 and the DPAPI provider GUID.
        Assert-That ($encrypted.Length -gt 20 -and [BitConverter]::ToString($encrypted, 0, 20) -eq
            '01-00-00-00-D0-8C-9D-DF-01-15-D1-11-8C-7A-00-C0-4F-C2-97-EB') 'The service profile is not a native DPAPI blob.'
        $plaintext = [Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $match = [regex]::Match([Text.Encoding]::UTF8.GetString($plaintext), '(?im)^\s*PrivateKey\s*=\s*([A-Za-z0-9+/]{43}=)\s*$')
        Assert-That $match.Success 'The native DPAPI file did not yield a valid private key in memory.'
        $privateKey = $match.Groups[1].Value
        # SCM must load this protected file without the provisioner. The cold
        # restart below verifies its live public identity independently via wg.
    } finally {
        if ($null -ne $plaintext) { [Array]::Clear($plaintext, 0, $plaintext.Length) }
        [Array]::Clear($encrypted, 0, $encrypted.Length)
    }
    foreach ($stream in $streams) {
        Assert-That (-not $stream.Contains($privateKey) -and $stream -notmatch '(?i)PrivateKey\s*=') 'A helper output stream contained plaintext key material.'
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $scratch, $store -Force -File -Recurse)) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        try {
            foreach ($encoding in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode, [Text.Encoding]::BigEndianUnicode)) {
                $text = $encoding.GetString($bytes)
                # Search for the exact generated secret, not a template's PrivateKey field.
                Assert-That (-not $text.Contains($privateKey)) 'A test-owned file contained the plaintext private key.'
            }
        } finally {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

$scratch = $null
$fixture = $null
$fixturePath = $null
$ownsReserved = $false
$ownsVendorDir = $false
$cleanupFailed = $false
$failed = $false
$phase = 'verify hosted runner'
try {
    Assert-That ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted' -and
        $env:RUNNER_OS -eq 'Windows' -and $env:RUNNER_ARCH -eq 'X64' -and $env:RUNNER_TEMP) 'Run this script only on a disposable GitHub-hosted x64 Windows runner.'
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-That ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'The hosted runner is not already elevated; this test will not request UAC.'

    $phase = 'read deployed IPv4 address and route from the checkout'
    # Use only the deployed address and route; the peer key and loopback
    # endpoint below are independent of the fleet.
    $networkPath = Join-Path $PSScriptRoot '..\..\fleet\machines\dev-01\tern-network.json'
    $network = Get-Content -LiteralPath $networkPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $clientAddress = $network.clients.windows
    $serverAddress = $network.serverAddress
    $existingAddresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -in @($clientAddress, $serverAddress) })
    $existingRoutes = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore | Where-Object DestinationPrefix -eq "$serverAddress/32")
    Assert-That ($existingAddresses.Count -eq 0 -and $existingRoutes.Count -eq 0) 'A Tern address or server route already exists on the runner; refusing to provision the test tunnel.'

    $phase = 'verify reserved runner state'
    $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
    $wireguard = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
    $wg = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
    $tunnel = 'atyrode-tern'
    $serviceName = 'WireGuardTunnel$' + $tunnel
    $vendorDir = Join-Path $env:ProgramFiles 'Atyrode'
    $store = Join-Path $vendorDir 'Tern'
    $profilePath = Join-Path $store "$tunnel.conf.dpapi"
    $managerStore = Join-Path $env:ProgramFiles 'WireGuard\Data\Configurations'
    $publicKeyPattern = '\A[A-Za-z0-9+/]{43}=\z'
    $streams = [Collections.Generic.List[string]]::new()
    Assert-That (-not (Test-Path -LiteralPath $store) -and $null -eq (Get-ReservedService)) 'The reserved service or profile store predates this test; refusing to touch it.'
    Assert-That ($null -eq (Get-NetAdapter -Name $tunnel -IncludeHidden -ErrorAction SilentlyContinue)) 'A reserved adapter predates this test; refusing to touch it.'
    Assert-That (-not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'WireGuard')) -and
        $null -eq (Get-Service -Name 'WireGuardManager' -ErrorAction SilentlyContinue)) 'WireGuard is already present; refusing to use pre-existing WireGuard state.'
    $ownsReserved = $true
    $ownsVendorDir = -not (Test-Path -LiteralPath $vendorDir)
    $scratch = Join-Path $env:RUNNER_TEMP ("tern-acceptance-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $scratch

    $phase = 'verify and stage the Nix-built Windows executable'
    Write-Host $phase
    $artifactPath = Join-Path $env:RUNNER_TEMP 'tern-tunnel-wsl\tern-tunnel.exe'
    Assert-That (Test-Path -LiteralPath $artifactPath -PathType Leaf) 'The workflow did not download the Nix-built tern-tunnel.exe.'
    $entry = Join-Path $scratch 'tern-tunnel.exe'
    $manifestFile = Join-Path $scratch 'tern-tunnel.json'
    Move-Item -LiteralPath $artifactPath -Destination $entry
    Assert-That ($env:TERN_TUNNEL_ARTIFACT_SHA256 -match '\A[0-9a-f]{64}\z' -and
        (Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash -eq $env:TERN_TUNNEL_ARTIFACT_SHA256) 'The staged executable does not match the SHA-256 from the Nix build job.'

    $phase = 'install official signed WireGuard MSI'
    Write-Host $phase
    $msi = Join-Path $scratch 'wireguard-amd64-1.1.1.msi'
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 45 -Uri 'https://download.wireguard.com/windows-client/wireguard-amd64-1.1.1.msi' -OutFile $msi
    $signature = Get-AuthenticodeSignature -LiteralPath $msi
    Assert-That ($signature.Status -eq 'Valid' -and $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ceq 'WireGuard LLC') 'WireGuard MSI Authenticode signature/publisher verification failed.'
    Assert-That ((Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash -eq
        '7BFED60AD61B785C914B38B61555A975488E1D3EC472DBFB2FCDF498FCA75242') 'Official WireGuard MSI SHA256 did not match the pinned release.'
    $null = Invoke-Captured $msiexec @('/i', $msi, '/quiet', '/norestart', 'DO_NOT_LAUNCH=1') 'Install WireGuard MSI' -TimeoutSeconds 180
    Remove-Item -LiteralPath $msi
    Assert-That ((Test-Path -LiteralPath $wireguard -PathType Leaf) -and (Test-Path -LiteralPath $wg -PathType Leaf)) 'WireGuard CLI executables were not installed.'

    $phase = 'lock unrelated manager fixture'
    Write-Host $phase
    $null = [IO.Directory]::CreateDirectory($managerStore)
    $fixtureName = 'wgfixture-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.conf.dpapi'
    $candidateFixture = Join-Path $managerStore $fixtureName
    # A stand-in for another protected profile, not a key or a tunnel we may use.
    # Deny all byte access by any other process throughout Plan and Apply.
    $initialFixture = [IO.File]::Open($candidateFixture, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $fixturePath = $candidateFixture
    $marker = [guid]::NewGuid().ToByteArray()
    try { $initialFixture.Write($marker, 0, $marker.Length) } finally { $initialFixture.Dispose() }
    $fixtureAcl = (Get-Acl -LiteralPath $fixturePath).Sddl
    $fixture = [IO.File]::Open($fixturePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $managerFiles = @(Get-ChildItem -LiteralPath $managerStore -Force -Name | Sort-Object) -join '|'
    # The disconnected peer needs only a public key. RFC 7748 §6.1 supplies two
    # real X25519 public vectors; no remote or fleet private key is ever needed.
    $peer = 'hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo='
    $manifest = [ordered]@{
        address = $clientAddress
        serverAddress = $serverAddress
        serverPublicKey = $peer
        expectedPublicKey = $null
        endpoint = '127.0.0.1'
        port = 51837
    }
    Set-TestManifest

    $phase = 'refuse an existing stopped foreign service without replacing it'
    Write-Host $phase
    # The test service has nothing executable to start, even if a regression tries.
    $foreignImage = '"{0}"' -f (Join-Path $scratch 'nonexistent-foreign-service.exe')
    New-Service -Name $serviceName -BinaryPathName $foreignImage -StartupType Manual -Description 'Tern acceptance foreign service' |
        ForEach-Object { $_.Dispose() }
    try {
        $foreign = Get-ReservedService
        Assert-That ($null -ne $foreign -and $foreign.State -eq 'Stopped' -and $foreign.PathName -ceq $foreignImage) 'The foreign service fixture was not installed as stopped.'
        foreach ($mode in @('Plan', 'Apply')) {
            $blocked = Invoke-Tern $mode "$mode with stopped foreign service" -ExpectFailure
            Assert-That ($blocked.status -ceq 'blocked' -and -not $blocked.enrolled -and $null -eq $blocked.publicKey -and
                $blocked.detail -like '*foreign executable, profile, or identity*') "$mode did not report foreign service ownership."
            $service = Get-ReservedService
            Assert-That ($null -ne $service -and $service.State -eq 'Stopped' -and $service.ProcessId -eq 0 -and
                $service.ExitCode -eq $foreign.ExitCode -and $service.PathName -ceq $foreign.PathName -and
                $service.StartMode -ceq $foreign.StartMode -and $service.StartName -ceq $foreign.StartName -and
                $service.Description -ceq $foreign.Description) "$mode changed or attempted to start the stopped foreign service."
            Assert-That (-not (Test-Path -LiteralPath $store) -and @(Get-ServerRoutes).Count -eq 0 -and
                $null -eq (Get-NetAdapter -Name $tunnel -IncludeHidden -ErrorAction SilentlyContinue)) "$mode created a protected store, reserved adapter or server route."
        }
    } finally {
        $null = Invoke-Captured $sc @('delete', $serviceName) 'Remove the stopped service fixture'
        Wait-Until 'Stopped service fixture removal' { $null -eq (Get-ReservedService) }
    }

    $phase = 'fresh read-only plan and native provisioning'
    Write-Host $phase
    $stagedBeforePlan = @(Get-ChildItem -LiteralPath $scratch -Recurse -Force -File | Sort-Object FullName | Get-FileHash | ForEach-Object { "$($_.Path) $($_.Hash)" }) -join "`n"
    $plan = Invoke-Tern Plan 'Fresh plan'
    Assert-That ($plan.status -eq 'missing' -and $null -eq $plan.publicKey -and -not $plan.enrolled) 'Fresh plan did not report an unenrolled missing tunnel.'
    Assert-That (-not (Test-Path -LiteralPath $store) -and $null -eq (Get-ReservedService)) 'Fresh plan created managed state.'
    $stagedAfterPlan = @(Get-ChildItem -LiteralPath $scratch -Recurse -Force -File | Sort-Object FullName | Get-FileHash | ForEach-Object { "$($_.Path) $($_.Hash)" }) -join "`n"
    Assert-That ($stagedAfterPlan -ceq $stagedBeforePlan -and (-not $ownsVendorDir -or -not (Test-Path -LiteralPath $vendorDir))) 'Fresh plan changed its staging files or created the protected parent.'
    $first = Invoke-Tern Apply 'Fresh apply'
    Assert-That ($first.status -eq 'configured' -and $first.publicKey -cmatch $publicKeyPattern -and -not $first.enrolled) 'Fresh apply did not provision an identity awaiting enrollment.'
    $identity = $first.publicKey
    Assert-OwnedProfile
    Assert-LiveTunnel $identity $peer
    $originalHash = (Get-FileHash -LiteralPath $profilePath).Hash
    $originalProcess = Get-ServiceProcess
    Assert-NoPlaintext

    $phase = 'approve key, verify no-op and fail closed on identity mismatch'
    Write-Host $phase
    $manifest.expectedPublicKey = $identity
    Set-TestManifest
    $plan = Invoke-Tern Plan 'Enrolled plan'
    Assert-That ($plan.status -eq 'configured' -and $plan.enrolled -and $plan.publicKey -ceq $identity) 'Plan did not verify the enrolled identity.'
    $again = Invoke-Tern Apply 'Repeat apply'
    Assert-That ($again.status -eq 'configured' -and $again.enrolled -and $again.publicKey -ceq $identity) 'Repeat apply did not preserve the enrolled identity.'
    $newPeer = '3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08='
    $manifest.expectedPublicKey = $newPeer
    Set-TestManifest
    $blocked = Invoke-Tern Apply 'Mismatched identity apply' -ExpectFailure
    Assert-That ($blocked.status -eq 'blocked' -and -not $blocked.enrolled) 'Apply did not report a blocked identity mismatch.'
    Assert-That ((Get-FileHash -LiteralPath $profilePath).Hash -ceq $originalHash -and (Get-ServiceProcess) -eq $originalProcess) 'Plan, no-op apply or mismatched identity altered the encrypted config or restarted the service.'
    Assert-LiveTunnel $identity $peer

    $manifest.expectedPublicKey = $identity
    $manifest.serverPublicKey = $newPeer
    Set-TestManifest

    $phase = 'refuse a conflicting server /32 without changing the live tunnel'
    Write-Host $phase
    # Add only an ActiveStore route via the runner's existing IPv4 gateway.
    # The higher metric leaves the live Tern /32 preferred; the default is untouched.
    $gatewayRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -PolicyStore ActiveStore |
        Where-Object { $_.InterfaceAlias -ine $tunnel -and $_.NextHop -ne '0.0.0.0' } |
        Sort-Object RouteMetric, InterfaceIndex, NextHop | Select-Object -First 1
    Assert-That ($null -ne $gatewayRoute) 'The hosted runner has no separate IPv4 gateway interface for a route fixture.'
    $originalRoutes = Get-ServerRouteState
    $originalProfileAcl = (Get-Acl -LiteralPath $profilePath).Sddl
    $conflict = New-NetRoute -DestinationPrefix "$serverAddress/32" -InterfaceIndex $gatewayRoute.InterfaceIndex `
        -NextHop $gatewayRoute.NextHop -RouteMetric 60000 -PolicyStore ActiveStore
    try {
        Assert-That (@(Get-ServerRoutes | Where-Object InterfaceIndex -eq $gatewayRoute.InterfaceIndex).Count -eq 1) 'The conflicting /32 was not present on the separate interface.'
        $conflictingRoutes = Get-ServerRouteState
        foreach ($mode in @('Plan', 'Apply')) {
            $blocked = Invoke-Tern $mode "$mode with conflicting server route" -ExpectFailure
            Assert-That ($blocked.status -ceq 'blocked' -and -not $blocked.enrolled -and $null -eq $blocked.publicKey -and
                $blocked.detail -like '*Another adapter*Tern server /32 route*') "$mode did not report the conflicting /32."
            Assert-That ((Get-ServerRouteState) -ceq $conflictingRoutes -and
                (Get-FileHash -LiteralPath $profilePath).Hash -ceq $originalHash -and
                (Get-Acl -LiteralPath $profilePath).Sddl -ceq $originalProfileAcl -and
                (Get-ServiceProcess) -ceq $originalProcess) "$mode changed the routes, protected profile or running service."
            Assert-LiveTunnel $identity $peer
        }
    } finally {
        Remove-NetRoute -InputObject $conflict -Confirm:$false
    }
    Assert-That ((Get-ServerRouteState) -ceq $originalRoutes) 'Removing the fixture did not restore the original server route state.'

    $phase = 'reenroll the server peer without rotating client identity'
    Write-Host $phase
    $changed = Invoke-Tern Plan 'Changed peer plan'
    Assert-That ($changed.status -eq 'change' -and $changed.enrolled -and $changed.publicKey -ceq $identity -and
        (Get-FileHash -LiteralPath $profilePath).Hash -ceq $originalHash -and (Get-Acl -LiteralPath $profilePath).Sddl -ceq $originalProfileAcl -and
        (Get-ServiceProcess) -ceq $originalProcess -and (Get-ServerRouteState) -ceq $originalRoutes) 'Changed peer plan did not report enrolled drift, or it changed managed state.'
    Assert-LiveTunnel $identity $peer
    $updated = Invoke-Tern Apply 'Apply changed peer'
    Assert-That ($updated.status -eq 'configured' -and $updated.enrolled -and $updated.publicKey -ceq $identity) 'Reapplying the server peer did not preserve the enrolled client identity.'
    Assert-OwnedProfile
    Assert-LiveTunnel $identity $newPeer
    $updatedHash = (Get-FileHash -LiteralPath $profilePath).Hash
    Assert-That ($updatedHash -cne $originalHash) 'The server peer changed only at runtime, not in the encrypted config.'

    $phase = 'stage the owned stopped service without removing its SCM registration'
    Write-Host $phase
    $serviceMarker = 'Tern acceptance stopped service canary'
    $null = Invoke-Captured $sc @('description', $serviceName, $serviceMarker) 'Mark the reserved service registration'
    $null = Invoke-Captured $sc @('stop', $serviceName) 'Stop the reserved tunnel before native Apply'
    Wait-Until 'Owned service stopped and adapter removed' {
        $service = Get-ReservedService
        $null -ne $service -and $service.State -eq 'Stopped' -and $null -eq (Get-NetAdapter -Name $tunnel -IncludeHidden -ErrorAction SilentlyContinue)
    }
    Assert-That ((Get-ReservedService).Description -ceq $serviceMarker) 'The stopped service fixture lost its registration marker.'

    $phase = 'reject a foreign WireGuard adapter at the reserved alias'
    Write-Host $phase
    $aliasName = 'wg-alias-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $aliasServiceName = 'WireGuardTunnel$' + $aliasName
    $aliasServiceFilter = "Name='$aliasServiceName'"
    $aliasProfile = Join-Path $scratch "$aliasName.conf.dpapi"
    Assert-That ($null -eq (Get-CimInstance -ClassName Win32_Service -Filter $aliasServiceFilter -OperationTimeoutSec 5) -and
        $null -eq (Get-NetAdapter -Name $aliasName -IncludeHidden -ErrorAction SilentlyContinue)) 'The isolated WireGuard fixture name is not free.'
    # No address, peer, DNS, or routes are configured; rename only this test-owned adapter.
    New-IsolatedAliasProfile $aliasProfile $aliasName
    $aliasHash = (Get-FileHash -LiteralPath $aliasProfile).Hash
    $stoppedProfileAcl = (Get-Acl -LiteralPath $profilePath).Sddl
    $aliasGuid = $null
    try {
        $null = Invoke-Captured $wireguard @('/installtunnelservice', $aliasProfile) 'Install the isolated alias fixture'
        Wait-Until 'Isolated alias fixture is running' {
            $service = Get-CimInstance -ClassName Win32_Service -Filter $aliasServiceFilter -OperationTimeoutSec 5
            $null -ne $service -and $service.State -eq 'Running' -and
                $null -ne (Get-NetAdapter -Name $aliasName -ErrorAction SilentlyContinue)
        }
        $aliasPid = (Get-CimInstance -ClassName Win32_Service -Filter $aliasServiceFilter -OperationTimeoutSec 5).ProcessId
        $aliasAdapter = Get-NetAdapter -Name $aliasName
        $aliasGuid = $aliasAdapter.InterfaceGuid
        Rename-NetAdapter -InputObject $aliasAdapter -NewName $tunnel
        Wait-Until 'Test-owned adapter occupies the reserved alias' {
            $adapter = Get-NetAdapter -Name $tunnel -IncludeHidden -ErrorAction SilentlyContinue
            $null -ne $adapter -and $adapter.InterfaceGuid -eq $aliasGuid
        }
        foreach ($mode in @('Plan', 'Apply')) {
            $blocked = Invoke-Tern $mode "$mode with foreign adapter alias" -ExpectFailure
            Assert-That ($blocked.status -ceq 'blocked' -and -not $blocked.enrolled -and $null -eq $blocked.publicKey -and
                $blocked.detail -like '*foreign adapter*reserved Tern name*') "$mode did not report foreign adapter ownership."
            $adapter = Get-NetAdapter -Name $tunnel -IncludeHidden
            $aliasService = Get-CimInstance -ClassName Win32_Service -Filter $aliasServiceFilter -OperationTimeoutSec 5
            $service = Get-ReservedService
            Assert-That ($adapter.InterfaceGuid -eq $aliasGuid -and $aliasService.State -eq 'Running' -and
                $aliasService.ProcessId -eq $aliasPid -and $service.State -eq 'Stopped' -and $service.Description -ceq $serviceMarker) "$mode changed the foreign adapter or either service."
            Assert-That (@(Get-ServerRoutes).Count -eq 0 -and (Get-FileHash -LiteralPath $aliasProfile).Hash -ceq $aliasHash -and
                (Get-FileHash -LiteralPath $profilePath).Hash -ceq $updatedHash -and
                (Get-Acl -LiteralPath $profilePath).Sddl -ceq $stoppedProfileAcl) "$mode changed a profile or installed a server route."
        }
    } finally {
        if ($null -ne (Get-CimInstance -ClassName Win32_Service -Filter $aliasServiceFilter -OperationTimeoutSec 5)) {
            $null = Invoke-Captured $wireguard @('/uninstalltunnelservice', $aliasName) 'Uninstall the isolated alias fixture'
        }
        Wait-Until 'Isolated alias fixture removed' {
            $null -eq (Get-CimInstance -ClassName Win32_Service -Filter $aliasServiceFilter -OperationTimeoutSec 5) -and
                ($null -eq $aliasGuid -or @(Get-NetAdapter -IncludeHidden | Where-Object InterfaceGuid -eq $aliasGuid).Count -eq 0)
        }
        Remove-Item -LiteralPath $aliasProfile
    }

    $phase = 'reuse the owned stopped service without replacing its SCM registration'
    Write-Host $phase
    $resumed = Invoke-Tern Apply 'Apply with owned stopped service'
    Assert-That ($resumed.status -ceq 'configured' -and $resumed.enrolled -and $resumed.publicKey -ceq $identity) 'Apply did not restart the existing tunnel with its enrolled identity.'
    Assert-LiveTunnel $identity $newPeer
    Assert-OwnedProfile
    Assert-That ((Get-ReservedService).Description -ceq $serviceMarker -and
        (Get-FileHash -LiteralPath $profilePath).Hash -ceq $updatedHash) 'Apply replaced the owned stopped service registration or rewrote its protected profile.'

    $phase = 'restart from DPAPI with staged inputs unavailable and no reachable peer'
    Write-Host $phase
    Assert-That ($null -eq (Get-Service -Name 'WireGuardManager' -ErrorAction SilentlyContinue)) 'This restart must not rely on the WireGuard manager service.'
    $runningProcess = Get-ServiceProcess
    $offline = Join-Path $scratch 'offline'
    $null = New-Item -ItemType Directory -Path $offline
    Move-Item -LiteralPath $entry, $manifestFile -Destination $offline
    $null = Invoke-Captured $sc @('stop', $serviceName) 'Stop the reserved tunnel'
    Wait-Until 'Service stopped and old adapter removed' {
        $service = Get-ReservedService
        $null -ne $service -and $service.State -eq 'Stopped' -and $null -eq (Get-NetAdapter -Name $tunnel -ErrorAction SilentlyContinue)
    }
    $null = Invoke-Captured $sc @('start', $serviceName) 'Start the reserved tunnel through SCM'
    Assert-LiveTunnel $identity $newPeer
    Assert-OwnedProfile
    Assert-That ((Get-FileHash -LiteralPath $profilePath).Hash -ceq $updatedHash -and (Get-ServiceProcess) -ne $runningProcess) 'Native restart did not reload the persisted identity and peer unchanged.'
    Assert-NoPlaintext

    $phase = 'verify the unrelated manager fixture remained isolated'
    $observed = [byte[]]::new($marker.Length)
    $fixture.Position = 0
    Assert-That ($fixture.Read($observed, 0, $observed.Length) -eq $marker.Length -and
        $fixture.Length -eq $marker.Length -and [Convert]::ToBase64String($observed) -ceq [Convert]::ToBase64String($marker)) 'The unrelated locked profile bytes changed.'
    $fixture.Dispose()
    $fixture = $null
    Assert-That ((Get-Acl -LiteralPath $fixturePath).Sddl -ceq $fixtureAcl -and
        (@(Get-ChildItem -LiteralPath $managerStore -Force -Name | Sort-Object) -join '|') -ceq $managerFiles) 'The unrelated profile ACL or its manager file inventory changed.'
} catch {
    $failed = $true
    # Never render exception details from native commands, decryption or JSON parsing.
    $message = if ($_.Exception.Message.StartsWith('Acceptance: ')) { $_.Exception.Message } else {
        "Unexpected $($_.Exception.GetType().Name) at acceptance script line $($_.InvocationInfo.ScriptLineNumber)."
    }
    Write-Error -ErrorAction Continue "Phase '$phase' failed. $message"
} finally {
    try {
        if ($null -ne $fixture) { $fixture.Dispose() }
        if ($null -ne $fixturePath) { Remove-Item -LiteralPath $fixturePath -Force }
    } catch {
        Write-Error -ErrorAction Continue 'Could not remove the test-owned unrelated profile fixture.'
        $cleanupFailed = $true
    }
    try {
        if ($ownsReserved -and $null -ne (Get-ReservedService)) {
            $null = Invoke-Captured $wireguard @('/uninstalltunnelservice', $tunnel) 'Uninstall the test-owned tunnel'
            Wait-Until 'Reserved service removal' { $null -eq (Get-ReservedService) }
        }
        if ($ownsReserved -and (Test-Path -LiteralPath $store)) {
            Remove-Item -LiteralPath $store -Force -Recurse
        }
        if ($ownsVendorDir -and (Test-Path -LiteralPath $vendorDir) -and
            @(Get-ChildItem -LiteralPath $vendorDir -Force).Count -eq 0) {
            Remove-Item -LiteralPath $vendorDir
        }
    } catch {
        Write-Error -ErrorAction Continue 'Could not clean the test-owned tunnel/service store; the ephemeral runner will be discarded.'
        $cleanupFailed = $true
    }
    try {
        if ($null -ne $scratch -and (Test-Path -LiteralPath $scratch)) { Remove-Item -LiteralPath $scratch -Force -Recurse }
    } catch {
        Write-Error -ErrorAction Continue 'Could not remove the isolated staging directory; the ephemeral runner will be discarded.'
        $cleanupFailed = $true
    }
}
if ($failed -or $cleanupFailed) { exit 1 }
Write-Host 'Native Windows Tern tunnel acceptance passed.'
