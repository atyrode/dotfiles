{ pkgs }:

let
  darwinCasks = import ../darwin/casks.nix;
in
assert builtins.elem "zen@twilight" darwinCasks;
assert !(builtins.elem "zen" darwinCasks);
pkgs.runCommand "check-windows-configuration"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.powershell
      pkgs.yq-go
    ];
  }
  ''
    yq -e '
      .properties.configurationVersion == "0.2.0"
      and (.properties.resources | length == 1)
      and .properties.resources[0].resource == "Microsoft.WinGet.DSC/WinGetPackage"
      and .properties.resources[0].id == "zenTwilight"
      and .properties.resources[0].settings.id == "Zen-Team.Zen-Browser.Twilight"
      and .properties.resources[0].settings.source == "winget"
    ' ${../windows/configuration.winget} >/dev/null

    pwsh -NoLogo -NoProfile -NonInteractive -Command '
      $tokens = $null
      $errors = $null
      [System.Management.Automation.Language.Parser]::ParseFile(
        "${../windows/apply.ps1}",
        [ref]$tokens,
        [ref]$errors
      ) | Out-Null
      if ($errors.Count -ne 0) {
        $errors | ForEach-Object { Write-Error $_ }
        exit 1
      }
    '

    if pwsh -NoLogo -NoProfile -NonInteractive \
      -File ${../windows/apply.ps1} plan >"$TMPDIR/non-windows" 2>&1; then
      echo 'Windows apply command unexpectedly ran on Linux' >&2
      exit 1
    fi
    grep -F 'requires native Windows' "$TMPDIR/non-windows" >/dev/null

    mkdir "$out"
  ''
