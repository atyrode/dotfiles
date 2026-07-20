{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Orca runs alongside Herdr during the trial. Every agent-tools host receives
  # the same release version: desktop apps can advertise themselves as a server,
  # while a headless Linux machine can be started manually with `orca serve`.
  # Nix owns the signed macOS app bundle but leaves its supported CLI launcher to
  # Orca; reviewed skills remain Home Manager-owned and update with the package
  # pin rather than through Orca's mutable skill updater. Persistent services,
  # pairing addresses, firewall policy, and secrets remain infrastructure
  # concerns and are intentionally absent here.
  home.packages = [ pkgs.orca-ide ];

  # Orca's headless installer creates user-local launchers that point directly
  # into the current extracted AppImage. Remove only launchers carrying Orca's
  # own signatures during activation so a package update falls back to the new
  # Nix profile binary; the next `orca serve` recreates matching launchers.
  home.activation.removeOrcaManagedLaunchers = lib.mkIf pkgs.stdenv.isLinux (
    lib.hm.dag.entryAfter
      [
        "installPackages"
        "linkGeneration"
      ]
      ''
        binDirectory=${lib.escapeShellArg "${config.home.homeDirectory}/.local/bin"}
        orcaIde="$binDirectory/orca-ide"
        orca="$binDirectory/orca"

        orcaIdeTarget="$(${pkgs.coreutils}/bin/readlink "$orcaIde" 2>/dev/null || :)"
        case "$orcaIdeTarget" in
          /nix/store/*-orca-ide-*-extracted/resources/bin/orca-ide)
            if [[ -v DRY_RUN ]]; then
              echo "Would remove Orca-managed launcher $orcaIde"
            else
              ${pkgs.coreutils}/bin/rm -f "$orcaIde"
            fi
            ;;
        esac

        if [[ -f "$orca" && ! -L "$orca" ]] \
          && ${pkgs.gnugrep}/bin/grep -qF '# orca-serve-bare-orca-dispatcher' "$orca"; then
          if [[ -v DRY_RUN ]]; then
            echo "Would remove Orca-managed dispatcher $orca"
          else
            ${pkgs.coreutils}/bin/rm -f "$orca"
          fi
        fi
      ''
  );
}
