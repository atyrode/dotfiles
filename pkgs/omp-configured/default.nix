{
  bigpowers,
  lib,
  omp,
  runCommand,
  writeShellApplication,
}:

let
  baseConfig = ../../omp/config.yml;
  presets = {
    budget = ../../omp/presets/budget.yml;
    fable = ../../omp/presets/fable-primary.yml;
    gpt = ../../omp/presets/gpt56.yml;
    opusFallback = ../../omp/presets/opus-fallback.yml;
  };
  bigpowersDir = "${bigpowers}/share/omp/plugins/bigpowers";

  ompWrapper = writeShellApplication {
    name = "omp";
    text = ''
      raw_omp=${lib.escapeShellArg (lib.getExe omp)}

      is_bigpowers_target() {
        case "$1" in
          bigpowers|bigpowers@*|npm:bigpowers*) return 0 ;;
          *) return 1 ;;
        esac
      }

      case "''${1:-}" in
        update)
          printf '%s\n' 'OMP is managed by Nix. Update the pinned derivation, then run zconf.' >&2
          exit 2
          ;;
        install)
          for target in "''${@:2}"; do
            if is_bigpowers_target "$target"; then
              printf '%s\n' 'Bigpowers is managed by Nix. Update the pinned derivation, then run zconf.' >&2
              exit 2
            fi
          done
          ;;
        plugin)
          case "''${2:-}" in
            install|link|uninstall|upgrade)
              for target in "''${@:3}"; do
                if is_bigpowers_target "$target"; then
                  printf '%s\n' 'Bigpowers is managed by Nix. Update the pinned derivation, then run zconf.' >&2
                  exit 2
                fi
              done
              ;;
          esac
          ;;
      esac

      case "''${1:-}" in
        __complete|acp|agents|auth-broker|auth-gateway|bench|commit|completions|config|dry-balance|gallery|gc|grep|grievances|install|join|models|plugin|read|say|search|setup|shell|ssh|stats|tiny-models|token|ttsr|update|usage|worktree)
          exec "$raw_omp" "$@"
          ;;
      esac

      managed_args=(
        --config ${lib.escapeShellArg (toString baseConfig)}
        --plugin-dir ${lib.escapeShellArg bigpowersDir}
      )
      local_config="''${XDG_CONFIG_HOME:-$HOME/.config}/omp/local.yml"
      if [[ -f "$local_config" ]]; then
        managed_args+=(--config "$local_config")
      fi

      exec "$raw_omp" "''${managed_args[@]}" "$@"
    '';
  };

  mkPresetCommand =
    name: presetArgs:
    writeShellApplication {
      inherit name;
      text = ''
        exec ${lib.escapeShellArg (lib.getExe ompWrapper)} ${
          lib.concatMapStringsSep " " (path: "--config ${lib.escapeShellArg (toString path)}") presetArgs
        } "$@"
      '';
    };

  ompBudget = mkPresetCommand "ompb" [ presets.budget ];
  ompFable = mkPresetCommand "ompf" [ presets.fable ];
  ompGpt = mkPresetCommand "ompg" [ presets.gpt ];
  ompOpus = mkPresetCommand "ompo" [
    presets.gpt
    presets.opusFallback
  ];
in
runCommand "omp-configured-${lib.getVersion omp}"
  {
    pname = "omp-configured";
    version = lib.getVersion omp;

    passthru = {
      inherit
        baseConfig
        bigpowers
        omp
        presets
        ;
    };

    meta = omp.meta // {
      description = "Declaratively configured OMP with Bigpowers and atyrode model presets";
      mainProgram = "omp";
    };
  }
  ''
    mkdir -p "$out/bin" "$out/share/zsh/site-functions"
    ln -s ${lib.getExe ompWrapper} "$out/bin/omp"
    ln -s ${lib.getExe ompBudget} "$out/bin/ompb"
    ln -s ${lib.getExe ompFable} "$out/bin/ompf"
    ln -s ${lib.getExe ompGpt} "$out/bin/ompg"
    ln -s ${lib.getExe ompOpus} "$out/bin/ompo"
    ln -s ${omp}/share/zsh/site-functions/_omp "$out/share/zsh/site-functions/_omp"
  ''
