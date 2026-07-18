#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('plan', 'apply')]
    [string]$Action = 'plan'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'windows/apply.ps1 requires native Windows; use the Nix bootstrap on macOS, Linux, or WSL.'
}

$configPath = Join-Path $PSScriptRoot 'configuration.winget'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "WinGet configuration is missing: $configPath"
}

$winget = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
if ($null -eq $winget) {
    throw 'WinGet is required. Install or update App Installer from the Microsoft Store, then retry.'
}
$wingetPath = $winget.Source

function Invoke-WinGet {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & $wingetPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "winget $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

$rawVersion = Invoke-WinGet -Arguments @('--version') | Select-Object -First 1
try {
    $wingetVersion = [version]$rawVersion.Trim().TrimStart('v')
}
catch {
    throw "Could not parse WinGet version '$rawVersion'. Install a stable WinGet release and retry."
}

$minimumVersion = [version]'1.6.2631'
if ($wingetVersion -lt $minimumVersion) {
    throw "WinGet $minimumVersion or newer is required; found $wingetVersion. Update App Installer and retry."
}

Write-Host "WinGet configuration: $configPath"
Invoke-WinGet -Arguments @('configure', 'validate', '--file', $configPath)
Invoke-WinGet -Arguments @('configure', 'show', '--file', $configPath)

if ($Action -eq 'plan') {
    Write-Host 'Plan complete; no configuration was applied. Re-run with apply after reviewing the resources above.'
    return
}

Invoke-WinGet -Arguments @(
    'configure',
    '--file', $configPath,
    '--accept-configuration-agreements'
)
Write-Host 'Windows configuration applied.'
