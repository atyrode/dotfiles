{ pkgs, lib, ... }:

let
  codexAgents = ../codex/AGENTS.md;
  codexConfig = ../codex/config.toml;

  codex-use = pkgs.writeShellApplication {
    name = "codex-use";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
    ];
    text = ''
      profile_root="$HOME/.codex-profiles"
      active_path="$HOME/.codex"
      active_state="$profile_root/.active-profile"
      codex_agents_source="${codexAgents}"
      codex_config_source="${codexConfig}"

      usage() {
        cat <<'EOF'
Usage:
  codex-use
  codex-use <default|main|profile>
  codex-use migrate
  codex-use list
  codex-use path [default|main|profile]
  codex-use ps
  codex-use stop [--force]

Inactive profiles are stored in ~/.codex-profiles/<profile>.
The active profile is always a real ~/.codex directory.
EOF
      }

      canonical_profile() {
        case "$1" in
          main)
            printf 'default\n'
            ;;
          *)
            printf '%s\n' "$1"
            ;;
        esac
      }

      profile_path() {
        printf '%s/%s\n' "$profile_root" "$(canonical_profile "$1")"
      }

      timestamp() {
        date +%Y%m%d%H%M%S
      }

      install_managed_profile_files() {
        profile_dir="$1"
        mkdir -p "$profile_dir"
        chmod 700 "$profile_dir"

        if [[ -d "$profile_dir/AGENTS.md" && ! -L "$profile_dir/AGENTS.md" ]]; then
          printf '%s\n' "Cannot manage $profile_dir/AGENTS.md: it is a directory." >&2
          exit 1
        fi

        rm -f "$profile_dir/AGENTS.md"
        ln -s "$codex_agents_source" "$profile_dir/AGENTS.md"

        if [[ ! -s "$profile_dir/config.toml" ]]; then
          if [[ -d "$profile_dir/config.toml" && ! -L "$profile_dir/config.toml" ]]; then
            printf '%s\n' "Cannot seed $profile_dir/config.toml: it is a directory." >&2
            exit 1
          fi

          rm -f "$profile_dir/config.toml"
          cp "$codex_config_source" "$profile_dir/config.toml"
          chmod 600 "$profile_dir/config.toml"
        fi
      }

      validate_profile() {
        if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
          printf 'Invalid Codex profile: %s\n' "$1" >&2
          exit 2
        fi
      }

      read_active_state() {
        if [[ ! -f "$active_state" ]]; then
          return 1
        fi

        IFS= read -r profile < "$active_state"
        profile="$(canonical_profile "$profile")"
        validate_profile "$profile"
        printf '%s\n' "$profile"
      }

      write_active_state() {
        profile="$(canonical_profile "$1")"
        validate_profile "$profile"
        mkdir -p "$profile_root"
        chmod 700 "$profile_root"
        printf '%s\n' "$profile" > "$active_state"
        chmod 600 "$active_state"
      }

      codex_processes() {
        pgrep -u "$(id -u)" -af '(^|[ /])(\.codex-wrapped|codex)([[:space:]]|$)' || true
      }

      ensure_no_codex_processes() {
        processes="$(codex_processes)"

        if [[ -n "$processes" ]]; then
          printf 'Codex processes are still running. Close them before switching profiles.\n' >&2
          printf '%s\n' "$processes" >&2
          printf 'Inspect them with %s or stop them with %s.\n' "codex-use ps" "codex-use stop" >&2
          exit 1
        fi
      }

      stop_codex_processes() {
        signal="TERM"

        if [[ $# -gt 1 ]]; then
          usage >&2
          exit 2
        fi

        case "''${1:-}" in
          "")
            ;;
          --force)
            signal="KILL"
            ;;
          *)
            usage >&2
            exit 2
            ;;
        esac

        processes="$(codex_processes)"

        if [[ -z "$processes" ]]; then
          printf 'No Codex processes found.\n'
          exit 0
        fi

        printf 'Stopping Codex processes with %s:\n' "$signal"
        printf '%s\n' "$processes"

        while IFS= read -r process_line; do
          pid="''${process_line%% *}"
          kill "-$signal" "$pid" 2>/dev/null || true
        done <<< "$processes"

        if [[ "$signal" == "TERM" ]]; then
          sleep 2
          remaining="$(codex_processes)"

          if [[ -n "$remaining" ]]; then
            printf 'Some Codex processes are still running:\n' >&2
            printf '%s\n' "$remaining" >&2
            printf 'Run %s if you want to force-stop them.\n' "codex-use stop --force" >&2
            exit 1
          fi
        fi
      }

      current_profile() {
        if [[ ! -e "$active_path" ]]; then
          printf 'none\n'
          return
        fi

        if [[ -L "$active_path" ]]; then
          target="$(readlink "$active_path")"
          case "$target" in
            "$profile_root"/*)
              printf '%s\n' "''${target#"$profile_root"/}"
              ;;
            *)
              printf 'external:%s\n' "$target"
              ;;
          esac
          return
        fi

        read_active_state || printf 'legacy\n'
      }

      show_current() {
        profile="$(current_profile)"
        printf 'active Codex profile: %s\n' "$profile"
        if [[ "$profile" == "legacy" ]]; then
          printf 'CODEX_HOME=%s\n' "$active_path"
          printf 'Run %s after closing Codex to enable profile switching.\n' "codex-use migrate"
        elif [[ "$profile" == external:* ]]; then
          printf 'CODEX_HOME=%s\n' "$(readlink "$active_path")"
          printf 'Run %s after closing Codex to convert ~/.codex back to a real directory.\n' "codex-use migrate"
        elif [[ "$profile" == "none" ]]; then
          printf 'CODEX_HOME=%s\n' "$active_path"
        else
          printf 'CODEX_HOME=%s\n' "$active_path"
        fi
      }

      active_profile_path() {
        if [[ $# -gt 1 ]]; then
          usage >&2
          exit 2
        fi

        if [[ $# -eq 0 ]]; then
          profile="$(current_profile)"
        else
          profile="$(canonical_profile "$1")"
          validate_profile "$profile"
        fi

        current="$(current_profile)"
        if [[ "$profile" == "$current" && -d "$active_path" && ! -L "$active_path" ]]; then
          printf '%s\n' "$active_path"
        elif [[ "$profile" == "none" || "$profile" == "legacy" || "$profile" == external:* ]]; then
          printf '%s\n' "$active_path"
        else
          printf '%s\n' "$(profile_path "$profile")"
        fi
      }

      migrate_legacy_profile_dirs() {
        mkdir -p "$profile_root"
        chmod 700 "$profile_root"

        active_profile="''${1:-}"

        shopt -s nullglob
        for legacy_dir in "$HOME"/.codex-*; do
          [[ -d "$legacy_dir" ]] || continue
          [[ "$legacy_dir" != "$profile_root" ]] || continue

          profile="''${legacy_dir##*/.codex-}"
          validate_profile "$profile"
          target="$(profile_path "$profile")"

          if [[ "$profile" == "$active_profile" ]]; then
            backup_target="$profile_root/recovered-$profile-$(timestamp)"
            mv "$legacy_dir" "$backup_target"
            chmod 700 "$backup_target"
            printf 'Moved duplicate active legacy profile %s to %s.\n' "$legacy_dir" "$backup_target" >&2
            continue
          fi

          if [[ -e "$target" ]]; then
            printf 'Skipping %s: %s already exists.\n' "$legacy_dir" "$target" >&2
            continue
          fi

          mv "$legacy_dir" "$target"
          chmod 700 "$target"
        done
        shopt -u nullglob
      }

      migrate_profiles() {
        ensure_no_codex_processes

        mkdir -p "$profile_root"
        chmod 700 "$profile_root"

        if [[ -L "$active_path" ]]; then
          target="$(readlink "$active_path")"
          case "$target" in
            "$profile_root"/*)
              profile="''${target#"$profile_root"/}"
              validate_profile "$profile"

              if [[ ! -d "$target" ]]; then
                printf 'Active profile target is missing: %s\n' "$target" >&2
                exit 1
              fi

              unlink "$active_path"
              mv "$target" "$active_path"
              chmod 700 "$active_path"
              write_active_state "$profile"
              migrate_legacy_profile_dirs "$profile"
              ;;
            *)
              printf '%s points outside %s: %s\n' "$active_path" "$profile_root" "$target" >&2
              printf 'Replace it with a real directory manually, then run %s again.\n' "codex-use migrate" >&2
              exit 1
              ;;
          esac
        elif [[ -d "$active_path" ]]; then
          if read_active_state >/dev/null; then
            profile="$(read_active_state)"
          else
            profile="default"
            default_target="$(profile_path "$profile")"

            if [[ -e "$default_target" ]]; then
              backup_target="$profile_root/recovered-$(timestamp)"
              mv "$active_path" "$backup_target"
              chmod 700 "$backup_target"
              mv "$default_target" "$active_path"
              chmod 700 "$active_path"
              printf 'Moved leftover %s to %s.\n' "$active_path" "$backup_target"
            else
              chmod 700 "$active_path"
            fi

            write_active_state "$profile"
          fi

          migrate_legacy_profile_dirs "$profile"
        elif [[ ! -e "$active_path" ]]; then
          profile="default"
          default_target="$(profile_path "$profile")"

          if [[ -d "$default_target" ]]; then
            mv "$default_target" "$active_path"
          else
            mkdir -p "$active_path"
          fi

          chmod 700 "$active_path"
          write_active_state "$profile"
          migrate_legacy_profile_dirs "$profile"
        else
          printf '%s exists but is not a directory.\n' "$active_path" >&2
          exit 1
        fi

        install_managed_profile_files "$active_path"
        show_current
      }

      ensure_migrated() {
        if [[ -e "$active_path" && ! -L "$active_path" ]]; then
          if read_active_state >/dev/null; then
            return
          fi
        fi

        migrate_profiles >/dev/null
      }

      switch_profile() {
        ensure_no_codex_processes
        ensure_migrated

        profile="$(canonical_profile "$1")"
        validate_profile "$profile"
        current="$(read_active_state)"

        if [[ "$profile" == "$current" ]]; then
          chmod 700 "$active_path"
          install_managed_profile_files "$active_path"
          printf 'active Codex profile: %s\n' "$profile"
          printf 'CODEX_HOME=%s\n' "$active_path"
          return
        fi

        target="$(profile_path "$profile")"
        if [[ -e "$target" && ! -d "$target" ]]; then
          printf '%s exists but is not a directory.\n' "$target" >&2
          exit 1
        fi

        current_target="$(profile_path "$current")"
        if [[ -e "$current_target" ]]; then
          backup_target="$profile_root/recovered-$current-$(timestamp)"
          mv "$current_target" "$backup_target"
          chmod 700 "$backup_target"
          printf 'Moved existing inactive %s profile to %s.\n' "$current" "$backup_target" >&2
        fi

        mv "$active_path" "$current_target"
        chmod 700 "$current_target"

        if [[ -d "$target" ]]; then
          mv "$target" "$active_path"
        else
          mkdir -p "$active_path"
        fi

        chmod 700 "$active_path"
        write_active_state "$profile"
        install_managed_profile_files "$active_path"

        printf 'active Codex profile: %s\n' "$profile"
        printf 'CODEX_HOME=%s\n' "$active_path"
      }

      list_profiles() {
        mkdir -p "$profile_root"
        active_profile="$(current_profile)"

        case "$active_profile" in
          none|legacy|external:*)
            ;;
          *)
            printf '%s\n' "$active_profile"
            ;;
        esac

        shopt -s nullglob
        for profile_dir in "$profile_root"/*; do
          [[ -d "$profile_dir" ]] || continue
          profile="''${profile_dir##*/}"
          [[ "$profile" != "$active_profile" ]] || continue
          printf '%s\n' "$profile"
        done
        shopt -u nullglob
      }

      show_path() {
        shift
        active_profile_path "$@"
      }

      case "''${1:-}" in
        "")
          show_current
          ;;
        -h|--help|help)
          usage
          ;;
        migrate)
          migrate_profiles
          ;;
        list)
          list_profiles
          ;;
        path)
          show_path "$@"
          ;;
        ps)
          codex_processes
          ;;
        stop)
          shift
          stop_codex_processes "$@"
          ;;
        *)
          if [[ $# -ne 1 ]]; then
            usage >&2
            exit 2
          fi
          switch_profile "$1"
          ;;
      esac
    '';
  };

  lichess = import ./pkgs/lichess.nix {
    inherit lib pkgs;
  };

  cliPackages = with pkgs; [
    # File navigation & search
    zoxide
    fzf
    fd
    bat
    tree
    ripgrep
    
    # System monitoring
    btop
    dua
    fastfetch

    # Shell helpers
    direnv
    shellcheck
    shfmt
  ];

  pythonPackages = with pkgs; [
    # Python tooling
    (python3.withPackages (ps: with ps; [
      pillow
    ]))
    uv
  ];

  javascriptPackages = with pkgs; [
    # JavaScript/TypeScript tooling
    nodejs_24
    bun
    deno
  ];

  developmentPackages = with pkgs; [
    # Development tools
    git
    gh
    tmux
    jq
    ffmpeg
    go
    nmap
    socat
    android-tools
    scrcpy
    dive
    clamav
    cargo
    rustc
    rustfmt
    clippy
    rust-analyzer
    nixd
    nixfmt
    codex
    codex-use
  ];

  darwinPackages = with pkgs; [
    chatgpt
    discord
    godot
    lichess
    obsidian
    orbstack
    postman
    prismlauncher
    reaper
    signal-desktop
    spotify
    vlc-bin
    vscode
    whatsapp-for-mac
  ];

  linuxPackages = with pkgs; [
    # Container tools
    docker
    docker-compose

    # Linux-only development tools
    gcc
    bubblewrap
  ];
in
{
  home.packages =
    cliPackages
    ++ pythonPackages
    ++ javascriptPackages
    ++ developmentPackages
    ++ lib.optionals pkgs.stdenv.isDarwin darwinPackages
    ++ lib.optionals pkgs.stdenv.isLinux linuxPackages;
}
