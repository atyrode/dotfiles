{
  lib,
  nixosConfig,
  pkgs,
  windowsPackages,
}:

let
  inherit (nixosConfig) config;
  markerFile =
    pkgs.writeText "atyrode-wsl-host.json"
      config.environment.etc."atyrode/wsl-host.json".text;
  packageFile = pkgs.writeText "atyrode-windows-packages.json" (builtins.toJSON windowsPackages);
in
assert lib.assertMsg config.wsl.enable "the managed Windows host must enable NixOS-WSL";
assert lib.assertMsg (config.wsl.defaultUser == "alex") "NixOS-WSL must launch as the managed user";
assert lib.assertMsg config.wsl.interop.register
  "NixOS-WSL must register Windows executable interop";
assert lib.assertMsg config.wsl.interop.includePath
  "NixOS-WSL must import the Windows executable path";
assert lib.assertMsg config.wsl.wslConf.interop.enabled "wsl.conf must enable Windows interop";
assert lib.assertMsg config.wsl.wslConf.interop.appendWindowsPath
  "wsl.conf must append the Windows path";
assert lib.assertMsg (
  config.networking.hostName == "atyrode-wsl"
) "the WSL hostname must be stable";
assert lib.assertMsg config.users.users.alex.isNormalUser "the managed WSL user must exist";
assert lib.assertMsg (builtins.hasAttr "alex" config.home-manager.users)
  "Home Manager must be integrated into NixOS-WSL";
assert lib.assertMsg (
  config.system.stateVersion == "26.05"
) "the WSL state version changed unexpectedly";
assert lib.assertMsg (builtins.isString config.system.build.toplevel.drvPath)
  "the NixOS-WSL system must evaluate to a toplevel derivation";
pkgs.runCommand "check-windows-control-plane"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.powershell
    ];
  }
  ''
    jq -e '
      .schemaVersion == 1
      and .id == "alex-x86_64-linux-wsl"
      and .activation == "nixos-wsl"
      and .hostname == "atyrode-wsl"
      and .system == "x86_64-linux"
      and .username == "alex"
    ' ${markerFile} >/dev/null

    jq -e '
      .schemaVersion == 2
      and (.packages | length) == 3
      and ([.packages[] | select(
        .id == "Zen-Team.Zen-Browser.Twilight"
        and .source == "winget"
        and .conflicts == ["Zen-Team.Zen-Browser"]
        and (.mutableStateOwner | contains("Zen Browser owns"))
      )] | length == 1)
      and ([.packages[] | select(
        .id == "DEVCOM.JetBrainsMonoNerdFont"
        and .source == "winget"
        and .conflicts == []
        and .versionPolicy == "installed; WinGet owns normal font updates"
        and (.mutableStateOwner | contains("Windows owns the installed font files"))
      )] | length == 1)
      and ([.packages[] | select(
        .id == "raphamorim.rio"
        and .source == "github-release"
        and .version == "0.4.7"
        and (.installer.sha256 | test("^[0-9a-f]{64}$"))
        and .config.destination == "%LOCALAPPDATA%\\rio\\config.toml"
        and .versionPolicy == "pinned to the nixpkgs pin"
        and .mutableStateOwner == "Rio owns its runtime state; Nix owns the config artifact"
      )] | length == 1)
    ' ${packageFile} >/dev/null

    export BOOTSTRAP_PATH=${../get.ps1}
    export WSL_STATE="$TMPDIR/wsl-state"
    export WSL_STUB_LOG="$TMPDIR/wsl.log"
    export INSTALL_LOCATION="$TMPDIR/windows-install"
    mkdir -p "$TMPDIR/bin" "$WSL_STATE"

    pwsh -NoLogo -NoProfile -NonInteractive -Command '
      $tokens = $null
      $errors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile(
        $env:BOOTSTRAP_PATH,
        [ref]$tokens,
        [ref]$errors
      )
      if ($errors.Count -ne 0) {
        $errors | ForEach-Object { Write-Error $_ }
        exit 1
      }
    '

    cat > "$TMPDIR/bin/wsl.exe" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    printf '%s\n' "$*" >> "$WSL_STUB_LOG"
    if [[ "''${1:-}" == --version ]]; then
      printf 'WSL version: 2.5.9\n'
      exit 0
    fi
    if [[ "''${1:-}" == --list && "''${2:-}" == --quiet ]]; then
      [[ -f "$WSL_STATE/distro" ]] && printf 'atyrode-nixos\n'
      exit 0
    fi
    case "$*" in
      *'--exec /run/current-system/sw/bin/test -f /etc/atyrode/wsl-host.json'*)
        test -f "$WSL_STATE/managed"
        ;;
      *'--exec /run/current-system/sw/bin/test -f /etc/atyrode-bootstrap-pending'*)
        test -f "$WSL_STATE/pending"
        ;;
      *'--exec /bin/sh -c '*' /etc/atyrode-bootstrap-pending'*)
        touch "$WSL_STATE/pending"
        ;;
      *'--exec /run/current-system/sw/bin/env PATH=/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin /run/current-system/sw/bin/nix --extra-experimental-features nix-command flakes shell github:atyrode/dotfiles/0123456789abcdef0123456789abcdef01234567#nixosConfigurations.alex-x86_64-linux-wsl.pkgs.nixos-rebuild --command nixos-rebuild switch --flake github:atyrode/dotfiles/0123456789abcdef0123456789abcdef01234567#alex-x86_64-linux-wsl'*)
        touch "$WSL_STATE/managed"
        ;;
      *'--exec /run/current-system/sw/bin/rm -f /etc/atyrode-bootstrap-pending'*)
        rm -f "$WSL_STATE/pending"
        ;;
      *'--install --from-file '*' --name atyrode-nixos '*' --no-launch'*)
        touch "$WSL_STATE/distro"
        ;;
      '--terminate atyrode-nixos')
        ;;
      *'--exec /etc/profiles/per-user/alex/bin/atyrode windows apply')
        ;;
      *)
        exit 97
        ;;
    esac
    EOF
    chmod +x "$TMPDIR/bin/wsl.exe"
    export PATH="$TMPDIR/bin:$PATH"

    cat > "$TMPDIR/run-bootstrap.ps1" <<'EOF'
    function global:Invoke-RestMethod {
        [CmdletBinding()]
        param([switch]$UseBasicParsing, $Headers, [string]$Uri)
        [pscustomobject]@{ sha = '0123456789abcdef0123456789abcdef01234567' }
    }
    function global:Invoke-WebRequest {
        [CmdletBinding()]
        param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile)
        Set-Content -LiteralPath $OutFile -Value 'fixture NixOS-WSL image'
    }
    function global:Get-FileHash {
        [CmdletBinding()]
        param([string]$Algorithm, [string]$LiteralPath)
        [pscustomobject]@{ Hash = $env:BOOTSTRAP_FAKE_HASH }
    }
    $parameters = @{
        Ref = 'main'
        InstallLocation = $env:INSTALL_LOCATION
    }
    if ($env:BOOTSTRAP_APPLY -eq '1') {
        $parameters.Apply = $true
    }
    & $env:BOOTSTRAP_PATH @parameters
    EOF

    # Plan is read-only even for a completely fresh machine.
    : > "$WSL_STUB_LOG"
    env OS=Windows_NT BOOTSTRAP_APPLY=0 BOOTSTRAP_FAKE_HASH=unused \
      pwsh -NoLogo -NoProfile -NonInteractive -File "$TMPDIR/run-bootstrap.ps1" \
      > "$TMPDIR/bootstrap-plan.out"
    grep -qF 'Plan only; no files, distributions, Nix generations, or Windows packages were changed.' \
      "$TMPDIR/bootstrap-plan.out"
    test ! -e "$WSL_STATE/distro"
    ! grep -qF -- '--install' "$WSL_STUB_LOG"

    # An unrelated distribution with the selected name is never reused or overwritten.
    touch "$WSL_STATE/distro"
    : > "$WSL_STUB_LOG"
    set +e
    env OS=Windows_NT BOOTSTRAP_APPLY=1 BOOTSTRAP_FAKE_HASH=unused \
      pwsh -NoLogo -NoProfile -NonInteractive -File "$TMPDIR/run-bootstrap.ps1" \
      > "$TMPDIR/bootstrap-unmanaged.out" 2> "$TMPDIR/bootstrap-unmanaged.err"
    unmanaged_status="$?"
    set -e
    test "$unmanaged_status" -ne 0
    grep -qF 'ownership marker' "$TMPDIR/bootstrap-unmanaged.err"
    ! grep -qF -- '--install' "$WSL_STUB_LOG"

    # A downloaded image with the wrong SHA-256 is deleted before WSL sees it.
    rm -rf "$WSL_STATE" "$INSTALL_LOCATION"
    mkdir -p "$WSL_STATE"
    : > "$WSL_STUB_LOG"
    set +e
    env OS=Windows_NT BOOTSTRAP_APPLY=1 \
      BOOTSTRAP_FAKE_HASH=0000000000000000000000000000000000000000000000000000000000000000 \
      pwsh -NoLogo -NoProfile -NonInteractive -File "$TMPDIR/run-bootstrap.ps1" \
      > "$TMPDIR/bootstrap-hash.out" 2> "$TMPDIR/bootstrap-hash.err"
    hash_status="$?"
    set -e
    test "$hash_status" -ne 0
    grep -qF 'NixOS-WSL image hash mismatch' "$TMPDIR/bootstrap-hash.err"
    ! grep -qF -- '--install --from-file' "$WSL_STUB_LOG"
    test ! -e "$WSL_STATE/distro"

    # A fresh image has no nixos-rebuild command yet. The bootstrap installs
    # the target flake's pinned rebuild package, activates that exact revision,
    # removes the pending marker, then invokes native reconciliation.
    rm -rf "$WSL_STATE" "$INSTALL_LOCATION"
    mkdir -p "$WSL_STATE"
    : > "$WSL_STUB_LOG"
    env OS=Windows_NT BOOTSTRAP_APPLY=1 \
      BOOTSTRAP_FAKE_HASH=e7180ad555fdcb8e1e057e2ef056de467603a5e502ff8531053738371be3f6b9 \
      pwsh -NoLogo -NoProfile -NonInteractive -File "$TMPDIR/run-bootstrap.ps1" \
      > "$TMPDIR/bootstrap-apply.out"
    grep -qF 'Bootstrap complete.' "$TMPDIR/bootstrap-apply.out"
    grep -qF -- '--install --from-file' "$WSL_STUB_LOG"
    grep -qF -- '--exec /run/current-system/sw/bin/env PATH=/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin /run/current-system/sw/bin/nix --extra-experimental-features nix-command flakes shell github:atyrode/dotfiles/0123456789abcdef0123456789abcdef01234567#nixosConfigurations.alex-x86_64-linux-wsl.pkgs.nixos-rebuild --command nixos-rebuild switch --flake github:atyrode/dotfiles/0123456789abcdef0123456789abcdef01234567#alex-x86_64-linux-wsl --option experimental-features nix-command flakes' \
      "$WSL_STUB_LOG"
    grep -qF -- '--exec /etc/profiles/per-user/alex/bin/atyrode windows apply' "$WSL_STUB_LOG"
    test -f "$WSL_STATE/distro"
    test -f "$WSL_STATE/managed"
    test ! -e "$WSL_STATE/pending"

    mkdir "$out"
  ''
