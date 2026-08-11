{
  config,
  lib,
  pkgs,
  ...
}:

let
  automationDirectory = "${config.home.homeDirectory}/Applications/Managed Automation";
  signingIdentity = "atyrode Local Automation";
  skhdApp = "${pkgs.skhd}/Applications/skhd.app";
  bridgeApp = "${pkgs.macos-automation-bridge}/Applications/atyrode-automation-bridge.app";
in
lib.mkIf pkgs.stdenv.isDarwin {
  home.packages = [ pkgs.yabai ];

  xdg.configFile = {
    "sketchybar" = {
      source = ../darwin/window-management/sketchybar-lua;
      recursive = true;
    };
    "sketchybar/sketchybarrc" = {
      executable = true;
      text = ''
        #!/bin/bash
        # Generated bootstrap: exec the pinned Lua runtime against this tree.
        export LUA_CPATH="${pkgs.sbarlua}/lib/lua/5.5/?.so;;"
        export LUA_PATH="$HOME/.config/sketchybar/?.lua;$HOME/.config/sketchybar/?/init.lua;;"
        exec ${pkgs.lua5_5}/bin/lua "$HOME/.config/sketchybar/init.lua"
      '';
    };
  };

  # The source apps are immutable and content-pinned in the Nix store, but an
  # ad-hoc signature does not provide a stable macOS privacy identity across
  # rebuilds. Copy only these two owned bundles to a stable path and sign them
  # with the workstation-local code-signing identity. Any byte-level drift
  # invalidates verification and forces a clean replacement on the next apply.
  home.activation.installSignedAutomationApps = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    identity=${lib.escapeShellArg signingIdentity}
    destination_root=${lib.escapeShellArg automationDirectory}
    receipt_root="''${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/automation-apps"

    if [[ -v DRY_RUN ]]; then
      echo "Would install and sign managed automation apps in $destination_root"
    else
      if ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/grep -Fq "\"$identity\""; then
        echo "home-manager: missing local code-signing identity '$identity'" >&2
        echo "run 'atyrode automation signing-bootstrap' once, then retry apply" >&2
        exit 1
      fi

      /bin/mkdir -p "$destination_root" "$receipt_root"

      install_signed_app() {
        source_app="$1"
        app_name="$2"
        bundle_id="$3"
        destination="$destination_root/$app_name"
        receipt="$receipt_root/$app_name.source"

        if [[ -f "$receipt" ]] \
          && /usr/bin/grep -Fxq "$source_app" "$receipt" \
          && /usr/bin/codesign --verify --deep --strict "$destination" >/dev/null 2>&1 \
          && /usr/bin/codesign -dv --verbose=4 "$destination" 2>&1 \
            | /usr/bin/grep -Fq "Authority=$identity"; then
          return
        fi

        staged="$destination_root/.$app_name.staged.$$"
        previous="$destination_root/.$app_name.previous.$$"
        # A killed activation must not leave an unsigned app-shaped bundle in
        # the stable automation directory. These globs match only our names.
        /bin/rm -rf "$destination_root/.$app_name.staged."* \
          "$destination_root/.$app_name.previous."*
        /bin/rm -rf "$staged" "$previous"
        /usr/bin/ditto "$source_app" "$staged"
        /bin/chmod -R u+w "$staged"
        /usr/bin/codesign --force --timestamp=none --options runtime \
          --identifier "$bundle_id" --sign "$identity" "$staged"
        /usr/bin/codesign --verify --deep --strict "$staged"
        /usr/bin/codesign -dv --verbose=4 "$staged" 2>&1 \
          | /usr/bin/grep -Fq "Authority=$identity"

        if [[ -e "$destination" ]]; then
          /bin/mv "$destination" "$previous"
        fi
        if ! /bin/mv "$staged" "$destination"; then
          if [[ -e "$previous" ]]; then /bin/mv "$previous" "$destination"; fi
          exit 1
        fi
        /bin/rm -rf "$previous"
        /usr/bin/printf '%s\n' "$source_app" > "$receipt"
      }

      install_signed_app ${lib.escapeShellArg skhdApp} skhd.app com.jackielii.skhd
      install_signed_app ${lib.escapeShellArg bridgeApp} \
        atyrode-automation-bridge.app dev.tyrode.automation-bridge
    fi
  '';

  # Reload every consumer after the signed bundles and managed Lua tree are in
  # place. These are stable app identities; package generations no longer leak
  # into TCC or Background Items identity.
  home.activation.restartManagedDesktopConsumers =
    lib.hm.dag.entryAfter [ "installSignedAutomationApps" ]
      ''
        if [[ -v DRY_RUN ]]; then
          echo "Would relaunch managed skhd, SketchyBar, and automation bridge agents"
        else
          user_domain="gui/$(${pkgs.coreutils}/bin/id -u)"
          /bin/launchctl kickstart -k "$user_domain/org.nixos.skhd" >/dev/null 2>&1 || true
          /bin/launchctl kickstart -k "$user_domain/org.nixos.sketchybar" >/dev/null 2>&1 || true
          /bin/launchctl kickstart -k "$user_domain/org.nixos.macos-automation-bridge" >/dev/null 2>&1 || true
        fi
      '';
}
