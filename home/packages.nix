{ pkgs, lib, ... }:

let
  codex-use = pkgs.writeShellApplication {
    name = "codex-use";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
    ];
    text = ''
      profile_root="$HOME/.codex-profiles"
      active_path="$HOME/.codex"

      usage() {
        cat <<'EOF'
Usage:
  codex-use
  codex-use <default|main|profile>
  codex-use migrate
  codex-use list
  codex-use ps
  codex-use stop [--force]

Profiles are stored in ~/.codex-profiles/<profile>.
The active profile is exposed to normal Codex as ~/.codex.
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

      validate_profile() {
        if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
          printf 'Invalid Codex profile: %s\n' "$1" >&2
          exit 2
        fi
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

        if [[ ! -L "$active_path" ]]; then
          printf 'legacy\n'
          return
        fi

        target="$(readlink "$active_path")"
        case "$target" in
          "$profile_root"/*)
            printf '%s\n' "''${target#"$profile_root"/}"
            ;;
          *)
            printf 'external:%s\n' "$target"
            ;;
        esac
      }

      show_current() {
        profile="$(current_profile)"
        printf 'active Codex profile: %s\n' "$profile"
        if [[ "$profile" == "legacy" ]]; then
          printf 'CODEX_HOME=%s\n' "$active_path"
          printf 'Run %s after closing Codex to enable profile switching.\n' "codex-use migrate"
        elif [[ "$profile" == external:* ]]; then
          printf 'CODEX_HOME=%s\n' "$(readlink "$active_path")"
        elif [[ "$profile" == "none" ]]; then
          printf 'CODEX_HOME=%s\n' "$active_path"
        else
          printf 'CODEX_HOME=%s\n' "$(profile_path "$profile")"
        fi
      }

      migrate_profiles() {
        ensure_no_codex_processes

        mkdir -p "$profile_root"
        chmod 700 "$profile_root"

        if [[ -e "$active_path" && ! -L "$active_path" ]]; then
          default_target="$(profile_path default)"
          if [[ -e "$default_target" ]]; then
            backup_target="$profile_root/recovered-$(date +%Y%m%d%H%M%S)"
            mv "$active_path" "$backup_target"
            chmod 700 "$backup_target"
            printf 'Moved leftover %s to %s.\n' "$active_path" "$backup_target"
          else
            mv "$active_path" "$default_target"
            chmod 700 "$default_target"
          fi
          ln -s "$default_target" "$active_path"
        elif [[ ! -e "$active_path" ]]; then
          mkdir -p "$(profile_path default)"
          chmod 700 "$(profile_path default)"
          ln -s "$(profile_path default)" "$active_path"
        fi

        for legacy_dir in "$HOME"/.codex-*; do
          [[ -d "$legacy_dir" ]] || continue
          [[ "$legacy_dir" != "$profile_root" ]] || continue

          profile="''${legacy_dir##*/.codex-}"
          validate_profile "$profile"
          target="$(profile_path "$profile")"

          if [[ -e "$target" ]]; then
            printf 'Skipping %s: %s already exists.\n' "$legacy_dir" "$target" >&2
            continue
          fi

          mv "$legacy_dir" "$target"
          chmod 700 "$target"
        done

        show_current
      }

      switch_profile() {
        ensure_no_codex_processes

        profile="$(canonical_profile "$1")"
        validate_profile "$profile"
        target="$(profile_path "$profile")"

        if [[ -e "$active_path" && ! -L "$active_path" ]]; then
          printf '%s is a real directory, so switching is not enabled yet.\n' "$active_path" >&2
          printf 'Close Codex, then run %s once.\n' "codex-use migrate" >&2
          exit 1
        fi

        mkdir -p "$target"
        chmod 700 "$target"
        ln -sfn "$target" "$active_path"

        printf 'active Codex profile: %s\n' "$profile"
        printf 'CODEX_HOME=%s\n' "$target"
      }

      list_profiles() {
        mkdir -p "$profile_root"
        for profile_dir in "$profile_root"/*; do
          [[ -d "$profile_dir" ]] || continue
          printf '%s\n' "''${profile_dir##*/}"
        done
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

  cliPackages = with pkgs; [
    # File navigation & search
    zoxide
    fzf
    fd
    bat
    tree
    
    # System monitoring
    btop
    dua
    fastfetch
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
  ];

  developmentPackages = with pkgs; [
    # Development tools
    git
    gh
    tmux
    cargo
    rustc
    rustfmt
    clippy
    rust-analyzer
    codex
    codex-use
  ];

  darwinPackages = with pkgs; [
    # Add macOS-only packages here.
  ];

  linuxPackages = with pkgs; [
    # Container tools
    docker
    docker-compose
    dive

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
