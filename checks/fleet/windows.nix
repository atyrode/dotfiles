{
  lib,
  nixosConfig,
  pkgs,
  windowsPackages,
}:

let
  inherit (nixosConfig) config;
  markerFile = pkgs.writeText "wsl-host.json" config.environment.etc."atyrode/wsl-host.json".text;
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
assert lib.assertMsg (config.networking.hostName == "wsl") "the WSL hostname must be stable";
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
      and .id == "wsl"
      and .activation == "nixos-wsl"
      and .hostname == "wsl"
      and .system == "x86_64-linux"
      and .username == "alex"
    ' ${markerFile} >/dev/null

    jq -e '
      .schemaVersion == 2
      and (.packages | length) == 3
      and ([.packages[] | select(
        .id == "Zen-Team.Zen-Browser.Twilight"
        and .source == "winget"
        and .installVersion == "1.23t"
        and (.versionPolicy | startswith("install 1.23t;"))
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
        .id == "WireGuard.WireGuard"
        and .source == "winget"
        and .installVersion == null
        and .conflicts == []
      )] | length == 1)
    ' ${packageFile} >/dev/null

    export BOOTSTRAP_PATH=${../../get.ps1}
    export WSL_STATE="$TMPDIR/wsl-state"
    export WSL_STUB_LOG="$TMPDIR/wsl.log"
    export INSTALL_LOCATION="$TMPDIR/windows-install"
    export CANDIDATE=/nix/store/00000000000000000000000000000000-nixos-system-wsl-fixture
    export CANDIDATE_CLI="$CANDIDATE/etc/profiles/per-user/alex/bin/atyrode"
    mkdir -p "$TMPDIR/bin" "$WSL_STATE"

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
      *'--exec /run/current-system/sw/bin/env PATH=/run/wrappers/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin /run/current-system/sw/bin/nix --extra-experimental-features nix-command flakes build --no-link --print-out-paths github:atyrode/dotfiles/0123456789abcdef0123456789abcdef01234567#nixosConfigurations.wsl.config.system.build.toplevel')
        test -f "$WSL_STATE/distro"
        printf '%s\n' "$CANDIDATE"
        ;;
      *"--exec /run/current-system/sw/bin/test -x $CANDIDATE/home-path/bin/atyrode")
        exit 1
        ;;
      *"--exec /run/current-system/sw/bin/test -x $CANDIDATE_CLI"|*"--exec /run/current-system/sw/bin/test -x $CANDIDATE/bin/switch-to-configuration")
        ;;
      "-d atyrode-nixos -u root --exec $CANDIDATE_CLI windows bootstrap-preflight --json")
        if [[ "''${BOOTSTRAP_PREFLIGHT:-}" == inspect ]]; then
          printf '%s\n' '{"schemaVersion":2,"command":"windows plan","host":"wsl","ready":true,"canApply":false}'
        else
          printf '%s\n' '{"schemaVersion":2,"command":"windows plan","host":"wsl","ready":true,"canApply":true}'
          touch "$WSL_STATE/preflight"
        fi
        ;;
      "-d atyrode-nixos -u root --exec /run/current-system/sw/bin/nix-env --profile /nix/var/nix/profiles/system --set $CANDIDATE")
        test -f "$WSL_STATE/preflight"
        touch "$WSL_STATE/profile"
        ;;
      "-d atyrode-nixos -u root --exec $CANDIDATE/bin/switch-to-configuration switch")
        test -f "$WSL_STATE/profile"
        touch "$WSL_STATE/managed"
        ;;
      *'--exec /run/current-system/sw/bin/rm -f /etc/atyrode-bootstrap-pending'*)
        rm -f "$WSL_STATE/pending"
        ;;
      *'--install --from-file '*' --name atyrode-nixos '*' --no-launch'*)
        touch "$WSL_STATE/distro"
        ;;
      '--terminate atyrode-nixos')
        test -f "$WSL_STATE/managed"
        test ! -e "$WSL_STATE/pending"
        touch "$WSL_STATE/restarted"
        ;;
      "-d atyrode-nixos -u alex --cd /home/alex --exec $CANDIDATE_CLI windows apply wsl")
        test -f "$WSL_STATE/restarted"
        touch "$WSL_STATE/reconciled"
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
    # The Linux fixture substitutes only the native Windows token probe; the
    # production elevation gate and the rest of the script still run.
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $env:BOOTSTRAP_PATH, [ref]$tokens, [ref]$errors
    )
    if ($errors.Count -ne 0) {
        $errors | ForEach-Object { Write-Error $_ }
        exit 1
    }
    $probe = $ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Test-Administrator'
    }
    $extent = $probe.Body.Extent
    $script = $ast.Extent.Text.Remove($extent.StartOffset, $extent.EndOffset - $extent.StartOffset)
    $script = $script.Insert($extent.StartOffset, '{ return ($env:BOOTSTRAP_ADMIN -eq "1") }')
    & ([scriptblock]::Create($script)) @parameters
    EOF

    export BOOTSTRAP_ADMIN=1

    # Plan is read-only even for a completely fresh machine.
    : > "$WSL_STUB_LOG"
    env OS=Windows_NT BOOTSTRAP_ADMIN=0 BOOTSTRAP_APPLY=0 BOOTSTRAP_FAKE_HASH=unused \
      pwsh -NoLogo -NoProfile -NonInteractive -File "$TMPDIR/run-bootstrap.ps1" \
      >/dev/null
    test ! -e "$WSL_STATE/distro"
    grep -qF -- '--install' "$WSL_STUB_LOG" && false

    # An explicit -Apply without a native admin token must not import or start a guest.
    : > "$WSL_STUB_LOG"
    if env OS=Windows_NT BOOTSTRAP_ADMIN=0 BOOTSTRAP_APPLY=1 BOOTSTRAP_FAKE_HASH=unused \
      pwsh -NoLogo -NoProfile -NonInteractive -File "$TMPDIR/run-bootstrap.ps1" \
      > "$TMPDIR/bootstrap-not-admin.out" 2> "$TMPDIR/bootstrap-not-admin.err"; then
      exit 1
    fi
    grep -qF 'requires an elevated PowerShell' "$TMPDIR/bootstrap-not-admin.err"
    grep -qE -- '--install|--exec' "$WSL_STUB_LOG" && false
    test ! -e "$INSTALL_LOCATION"

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
    grep -qF 'marker' "$TMPDIR/bootstrap-unmanaged.err"
    grep -qF -- '--install' "$WSL_STUB_LOG" && false

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
    grep -qF 'mismatch' "$TMPDIR/bootstrap-hash.err"
    grep -qF -- '--install --from-file' "$WSL_STUB_LOG" && false
    test ! -e "$WSL_STATE/distro"

    # Provision only the pinned stock image if the native probe cannot apply.
    # It stays pending, without a new profile, activated marker or native apply.
    : > "$WSL_STUB_LOG"
    if env OS=Windows_NT BOOTSTRAP_APPLY=1 BOOTSTRAP_PREFLIGHT=inspect \
      BOOTSTRAP_FAKE_HASH=e7180ad555fdcb8e1e057e2ef056de467603a5e502ff8531053738371be3f6b9 \
      pwsh -NoLogo -NoProfile -NonInteractive -File "$TMPDIR/run-bootstrap.ps1" \
      > "$TMPDIR/bootstrap-inspect.out" 2> "$TMPDIR/bootstrap-inspect.err"; then
      exit 1
    fi
    grep -qF 'no generation was activated' "$TMPDIR/bootstrap-inspect.err"
    grep -qF -- '--install --from-file' "$WSL_STUB_LOG"
    grep -qF -- "$CANDIDATE_CLI windows bootstrap-preflight --json" "$WSL_STUB_LOG"
    grep -qE -- 'nix-env|switch-to-configuration switch|windows apply|--terminate' "$WSL_STUB_LOG" && false
    test -f "$WSL_STATE/distro"
    test -f "$WSL_STATE/pending"
    test ! -e "$WSL_STATE/managed"
    test ! -e "$WSL_STATE/profile"

    # A retry reuses the pending stock guest. The stub requires the exact
    # revision's candidate to pass preflight before that same closure switches.
    : > "$WSL_STUB_LOG"
    env OS=Windows_NT BOOTSTRAP_APPLY=1 \
      BOOTSTRAP_FAKE_HASH=e7180ad555fdcb8e1e057e2ef056de467603a5e502ff8531053738371be3f6b9 \
      pwsh -NoLogo -NoProfile -NonInteractive -File "$TMPDIR/run-bootstrap.ps1" \
      >/dev/null
    grep -qF -- '--install --from-file' "$WSL_STUB_LOG" && false
    grep -qF -- "$CANDIDATE_CLI windows bootstrap-preflight --json" "$WSL_STUB_LOG"
    grep -qF -- "$CANDIDATE/bin/switch-to-configuration switch" "$WSL_STUB_LOG"
    grep -qF -- "$CANDIDATE_CLI windows apply wsl" "$WSL_STUB_LOG"
    test -f "$WSL_STATE/reconciled"
    test -f "$WSL_STATE/managed"
    test ! -e "$WSL_STATE/pending"

    mkdir "$out"
  ''
