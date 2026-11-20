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

function Get-TestPublicKey([string]$PrivateKey) {
    # Windows PowerShell's native pipeline honors this encoding. A .NET
    # Framework Process.StandardInput writer can prepend a BOM to wg's input.
    $OutputEncoding = [Text.Encoding]::ASCII
    $public = $PrivateKey | & $wg pubkey 2>$null
    Assert-That ($LASTEXITCODE -eq 0 -and $public -is [string] -and $public -cmatch $publicKeyPattern) 'WireGuard did not derive a public key from ASCII stdin.'
    $public
}

function New-TestPeer {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $privateBytes = [byte[]]::new(32)
    try {
        $rng.GetBytes($privateBytes)
        $privateBytes[0] = $privateBytes[0] -band 248
        $privateBytes[31] = ($privateBytes[31] -band 127) -bor 64
        Get-TestPublicKey ([Convert]::ToBase64String($privateBytes))
    } finally {
        [Array]::Clear($privateBytes, 0, $privateBytes.Length)
        $rng.Dispose()
    }
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

function Assert-NoPlaintext([string]$PublicKey) {
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
        Assert-That ((Get-TestPublicKey $privateKey) -ceq $PublicKey) 'The DPAPI profile private key did not match the live public key.'
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
    $peer = New-TestPeer
    $manifest = [ordered]@{
        address = '192.0.2.213'
        serverAddress = '198.51.100.214'
        serverPublicKey = $peer
        expectedPublicKey = $null
        endpoint = '127.0.0.1'
        port = 51837
    }
    Set-TestManifest

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
    Assert-NoPlaintext $identity

    $phase = 'approve key, verify no-op and fail closed on identity mismatch'
    Write-Host $phase
    $manifest.expectedPublicKey = $identity
    Set-TestManifest
    $plan = Invoke-Tern Plan 'Enrolled plan'
    Assert-That ($plan.status -eq 'configured' -and $plan.enrolled -and $plan.publicKey -ceq $identity) 'Plan did not verify the enrolled identity.'
    $again = Invoke-Tern Apply 'Repeat apply'
    Assert-That ($again.status -eq 'configured' -and $again.enrolled -and $again.publicKey -ceq $identity) 'Repeat apply did not preserve the enrolled identity.'
    $newPeer = New-TestPeer
    Assert-That ($newPeer -cne $peer -and $newPeer -cne $identity) 'Throwaway peer unexpectedly reused a public key.'
    $manifest.expectedPublicKey = $newPeer
    Set-TestManifest
    $blocked = Invoke-Tern Apply 'Mismatched identity apply' -ExpectFailure
    Assert-That ($blocked.status -eq 'blocked' -and -not $blocked.enrolled) 'Apply did not report a blocked identity mismatch.'
    Assert-That ((Get-FileHash -LiteralPath $profilePath).Hash -ceq $originalHash -and (Get-ServiceProcess) -eq $originalProcess) 'Plan, no-op apply or mismatched identity altered the encrypted config or restarted the service.'
    Assert-LiveTunnel $identity $peer

    $phase = 'reenroll the server peer without rotating client identity'
    Write-Host $phase
    $manifest.expectedPublicKey = $identity
    $manifest.serverPublicKey = $newPeer
    Set-TestManifest
    $changed = Invoke-Tern Plan 'Changed peer plan'
    Assert-That ($changed.status -eq 'change' -and (Get-FileHash -LiteralPath $profilePath).Hash -ceq $originalHash -and
        (Get-ServiceProcess) -eq $originalProcess) 'Changed peer plan did not report drift, or it changed managed state.'
    $updated = Invoke-Tern Apply 'Apply changed peer'
    Assert-That ($updated.status -eq 'configured' -and $updated.enrolled -and $updated.publicKey -ceq $identity) 'Reapplying the server peer did not preserve the enrolled client identity.'
    Assert-OwnedProfile
    Assert-LiveTunnel $identity $newPeer
    $updatedHash = (Get-FileHash -LiteralPath $profilePath).Hash
    Assert-That ($updatedHash -cne $originalHash) 'The server peer changed only at runtime, not in the encrypted config.'

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
    Assert-NoPlaintext $identity

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
