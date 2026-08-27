{ lib, pkgs }:

let
  inherit (import ./lib/omp-fixtures.nix { inherit lib pkgs; }) evalAgentTools;
  ollamaStub = pkgs.writeShellScriptBin "ollama" ''
    printf 'OLLAMA_HOST=%s\n' "$OLLAMA_HOST" >> "''${OLLAMA_STUB_LOG:?}"
    printf 'args=%s\n' "$*" >> "$OLLAMA_STUB_LOG"
  '';
  linuxClassifierTools =
    evalAgentTools
      (
        pkgs
        // {
          ollama = ollamaStub;
          stdenv = pkgs.stdenv // {
            isLinux = true;
            isDarwin = false;
          };
        }
      )
      {
        localClassifier.enable = true;
      };
  classifierService = linuxClassifierTools.systemd.user.services.ollama-pull-classifier;
  classifierTimer = linuxClassifierTools.systemd.user.timers.ollama-pull-classifier;
in
pkgs.runCommand "check-agent-classifier-schedule" { } ''
    # Exercise the evaluated ExecStart with a stub daemon client, proving both
    # the pinned daemon endpoint and model passed to the service at runtime.
    export OLLAMA_STUB_LOG="$TMPDIR/ollama-invocations"
    : > "$OLLAMA_STUB_LOG"
    pull=${lib.escapeShellArg classifierService.Service.ExecStart}
    "$pull"
    cat > "$TMPDIR/expected-ollama-invocations" <<'EOF'
  OLLAMA_HOST=127.0.0.1:11434
  args=list
  OLLAMA_HOST=127.0.0.1:11434
  args=list
  OLLAMA_HOST=127.0.0.1:11434
  args=pull qwen2.5:3b
  EOF
    cmp "$TMPDIR/expected-ollama-invocations" "$OLLAMA_STUB_LOG"
    test ${lib.escapeShellArg (lib.concatStringsSep " " classifierService.Unit.After)} = 'ollama.service'
    test ${lib.escapeShellArg (lib.concatStringsSep " " classifierService.Unit.Wants)} = 'ollama.service'

    # The service must stay out of the startup transaction: a first-boot
    # multi-GB download inside it holds `is-system-running` at "starting".
    test ${if classifierService ? Install then "1" else "0"} = 0

    # The timer owns scheduling instead: outside readiness, after startup.
    test ${lib.escapeShellArg (toString classifierTimer.Timer.OnActiveSec)} = '30s'
    test ${lib.escapeShellArg (toString classifierTimer.Timer.AccuracySec)} = '1s'
    test ${lib.escapeShellArg (lib.concatStringsSep " " classifierTimer.Install.WantedBy)} = 'timers.target'
    mkdir "$out"
''
