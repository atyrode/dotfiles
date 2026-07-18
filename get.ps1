#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Apply,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$')]
    [string]$Ref = 'main',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$DistroName = 'atyrode-nixos',
    [string]$InstallLocation = (Join-Path $env:LOCALAPPDATA 'atyrode\wsl')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repository = 'atyrode/dotfiles'
$HostId = 'alex-x86_64-linux-wsl'
$Username = 'alex'
$MinimumWslVersion = [Version]'2.4.4'
$NixosWslVersion = '2605.7.2'
$NixosWslUri = "https://github.com/nix-community/NixOS-WSL/releases/download/$NixosWslVersion/nixos.wsl"
$NixosWslSha256 = 'e7180ad555fdcb8e1e057e2ef056de467603a5e502ff8531053738371be3f6b9'
$ManagedMarker = '/etc/atyrode/wsl-host.json'
$PendingMarker = '/etc/atyrode-bootstrap-pending'

function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    & $script:WslExe @Arguments | ForEach-Object { Write-Host $_ }
    $status = $LASTEXITCODE
    if (-not $AllowFailure -and $status -ne 0) {
        throw "wsl.exe $($Arguments -join ' ') failed with exit code $status"
    }
    return $status
}

function Resolve-Revision {
    param([Parameter(Mandatory = $true)][string]$RequestedRef)

    $encoded = [Uri]::EscapeDataString($RequestedRef)
    $uri = "https://api.github.com/repos/$Repository/commits/$encoded"
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'atyrode-windows-bootstrap'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $response = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri $uri
    $revision = [string]$response.sha
    if ($revision -notmatch '^[0-9a-f]{40}$') {
        throw "GitHub did not resolve '$RequestedRef' to an exact commit"
    }
    return $revision
}

function Get-WslVersion {
    $lines = @(& $script:WslExe --version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    foreach ($line in $lines) {
        $text = ([string]$line).Replace([string][char]0, '').Trim()
        if ($text -match '([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)') {
            return [Version]$Matches[1]
        }
    }
    return $null
}

function Get-WslDistros {
    $lines = @(& $script:WslExe --list --quiet 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return @()
    }
    return @($lines | ForEach-Object {
            ([string]$_).Replace([string][char]0, '').Trim()
        } | Where-Object { $_ })
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DistroFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    & $script:WslExe -d $DistroName -u root --exec test -f $Path 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-ManagedDistro {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $allArguments = @('-d', $DistroName, '-u', 'root', '--exec') + $Arguments
    $status = Invoke-Wsl -Arguments $allArguments
    if ($status -ne 0) {
        throw "managed NixOS-WSL command failed"
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'get.ps1 requires native Windows PowerShell; run get.sh on macOS or Linux'
}

$wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue
if ($null -eq $wslCommand) {
    throw 'wsl.exe is unavailable; this bootstrap requires Windows 11 with WSL support'
}
$script:WslExe = $wslCommand.Source

$revision = Resolve-Revision -RequestedRef $Ref
$flake = "github:$Repository/$revision#$HostId"
$wslVersion = Get-WslVersion
$distros = Get-WslDistros
$distroExists = ($distros -contains $DistroName)
$wslReady = ($null -ne $wslVersion -and $wslVersion -ge $MinimumWslVersion)

Write-Host "atyrode Windows bootstrap plan"
Write-Host "  repository ref:  $Ref"
Write-Host "  exact revision:  $revision"
Write-Host "  NixOS host:       $HostId"
Write-Host "  WSL distribution: $DistroName"
Write-Host "  install location: $InstallLocation"
Write-Host "  WSL version:      $(if ($null -eq $wslVersion) { 'unavailable or legacy' } else { $wslVersion })"
Write-Host "  existing distro:  $distroExists"
Write-Host "  image:            NixOS-WSL $NixosWslVersion ($NixosWslSha256)"
Write-Host '  phase 1:          install or verify the pinned NixOS-WSL image'
Write-Host '  phase 2:          activate the exact dotfiles revision with nixos-rebuild'
Write-Host '  phase 3:          reconcile native Windows packages through winget.exe'
Write-Host '  rollback boundary: Nix generations cover phase 2 only; Windows package state is non-transactional'

if (-not $Apply) {
    Write-Host 'Plan only; no files, distributions, Nix generations, or Windows packages were changed.'
    Write-Host 'Re-run with -Apply after reviewing this plan.'
    return
}

if (-not $wslReady) {
    if (-not (Test-Administrator)) {
        throw "WSL $MinimumWslVersion or newer is required. Re-run this bootstrap from an elevated PowerShell once to install or update WSL, then reboot if Windows requests it."
    }
    Write-Host 'Installing or updating the native WSL prerequisite...'
    Invoke-Wsl -Arguments @('--install', '--no-distribution') | Out-Null
    Invoke-Wsl -Arguments @('--update') | Out-Null
    Write-Host 'WSL prerequisite updated. Reboot if Windows requests it, then run the same -Apply command again.'
    return
}

if ($distroExists) {
    $managed = Test-DistroFile -Path $ManagedMarker
    $pending = Test-DistroFile -Path $PendingMarker
    if (-not $managed -and -not $pending) {
        throw "WSL distribution '$DistroName' already exists but has no atyrode ownership marker; refusing to reuse or overwrite it"
    }
    Write-Host "Reusing verified atyrode distribution '$DistroName'."
}
else {
    if (Test-Path -LiteralPath $InstallLocation) {
        $entries = @(Get-ChildItem -Force -LiteralPath $InstallLocation)
        if ($entries.Count -ne 0) {
            throw "install location '$InstallLocation' is non-empty while '$DistroName' is absent; refusing to overwrite it"
        }
    }
    else {
        New-Item -ItemType Directory -Path $InstallLocation -Force | Out-Null
    }

    $cacheDirectory = Join-Path ([IO.Path]::GetTempPath()) 'atyrode-bootstrap'
    $imagePath = Join-Path $cacheDirectory "nixos-wsl-$NixosWslVersion.wsl"
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    $download = $true
    if (Test-Path -LiteralPath $imagePath) {
        $cachedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $imagePath).Hash.ToLowerInvariant()
        $download = ($cachedHash -ne $NixosWslSha256)
    }
    if ($download) {
        Write-Host "Downloading pinned NixOS-WSL $NixosWslVersion image..."
        Invoke-WebRequest -UseBasicParsing -Uri $NixosWslUri -OutFile $imagePath
    }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $imagePath).Hash.ToLowerInvariant()
    if ($actualHash -ne $NixosWslSha256) {
        Remove-Item -Force -LiteralPath $imagePath
        throw "NixOS-WSL image hash mismatch: expected $NixosWslSha256, found $actualHash"
    }

    Write-Host "Installing '$DistroName' from the verified image..."
    Invoke-Wsl -Arguments @(
        '--install',
        '--from-file', $imagePath,
        '--name', $DistroName,
        '--location', $InstallLocation,
        '--no-launch'
    ) | Out-Null
    Invoke-ManagedDistro -Arguments @(
        'sh', '-c',
        "umask 022; printf '%s\n' '$revision' > $PendingMarker"
    )
}

Write-Host "Activating $flake inside NixOS-WSL..."
Invoke-ManagedDistro -Arguments @(
    'nixos-rebuild', 'switch', '--flake', $flake,
    '--option', 'experimental-features', 'nix-command flakes'
)
if (-not (Test-DistroFile -Path $ManagedMarker)) {
    throw "NixOS activation completed without creating $ManagedMarker"
}
Invoke-ManagedDistro -Arguments @('rm', '-f', $PendingMarker)
Invoke-Wsl -Arguments @('--terminate', $DistroName) | Out-Null

Write-Host 'Reconciling native Windows packages from the managed WSL control plane...'
$windowsArguments = @(
    '-d', $DistroName,
    '-u', $Username,
    '--cd', "/home/$Username",
    '--exec', "/etc/profiles/per-user/$Username/bin/atyrode", 'windows', 'apply'
)
$status = Invoke-Wsl -Arguments $windowsArguments -AllowFailure
if ($status -ne 0) {
    throw "NixOS activation succeeded, but native Windows reconciliation failed. Start '$DistroName' and run 'atyrode windows plan', then 'atyrode windows apply' after resolving its remediation."
}

Write-Host "Bootstrap complete. Enter the managed environment with: wsl.exe -d $DistroName"
