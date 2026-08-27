{ lib, pkgs }:

let
  defaultsConfig = ../../omp/defaults.yml;
  policyConfig = ../../omp/policy.yml;
  untrustedConfig = ../../omp/untrusted.yml;
  yoloConfig = ../../omp/yolo-session.yml;
  stubOmp =
    pkgs.runCommand "omp-stub"
      {
        meta = {
          mainProgram = "omp";
          platforms = lib.platforms.all;
        };
      }
      ''
            mkdir -p "$out/bin" "$out/share/zsh/site-functions"
            cat > "$out/bin/omp" <<'EOF'
        #!${pkgs.runtimeShell}
        if [[ " $* " == *" auth-broker serve "* ]]; then
          printf '%s\n' "$@" >> "''${BROKER_STUB_LOG:?}"
          trap 'exit 0' INT TERM
          while true; do sleep 1; done
        fi
        if [[ -n "$GOPLS_STUB_LOG" ]]; then
          command -v gopls > "$GOPLS_STUB_LOG"
        fi
        if [[ -n "$TYPESCRIPT_LSP_STUB_LOG" ]]; then
          command -v typescript-language-server > "$TYPESCRIPT_LSP_STUB_LOG"
        fi
        printf '%s\n' "$@"
        EOF
            chmod +x "$out/bin/omp"
            printf '#compdef omp\n' > "$out/share/zsh/site-functions/_omp"
      '';

  configuredStub = pkgs.callPackage ../../pkgs/omp-configured {
    omp = stubOmp;
  };
  evalAgentTools =
    platformPkgs: extraAgentTools:
    (lib.evalModules {
      specialArgs.pkgs = platformPkgs;
      modules = [
        (
          { lib, ... }:
          {
            options = {
              home.packages = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [ ];
              };
              home.sessionVariables = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = { };
              };
              home.file = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              home.activation = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              xdg.stateHome = lib.mkOption { type = lib.types.str; };
              xdg.configHome = lib.mkOption { type = lib.types.str; };
              xdg.cacheHome = lib.mkOption { type = lib.types.str; };
              xdg.configFile = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              services.ollama = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              systemd.user.services = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              systemd.user.timers = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              launchd.agents = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
            };

            config = {
              xdg.configHome = "/tmp/check-agent-auth-broker/xdg-config";
              xdg.stateHome = "/tmp/check-agent-auth-broker/xdg-state";
              xdg.cacheHome = "/tmp/check-agent-auth-broker/xdg-cache";
              atyrode.agentTools = {
                enable = true;
                seedPlainConfig = false;
                ompPackage = configuredStub;
                localClassifier.enable = false;
              }
              // extraAgentTools;
            };
          }
        )
        ../../modules/home/agent-tools.nix
      ];
    }).config;
  linuxAgentTools = evalAgentTools (
    pkgs
    // {
      stdenv = pkgs.stdenv // {
        isLinux = true;
        isDarwin = false;
      };
    }
  ) { };
  darwinAgentTools = evalAgentTools (
    pkgs
    // {
      stdenv = pkgs.stdenv // {
        isLinux = false;
        isDarwin = true;
      };
    }
  ) { };
in
{
  inherit
    configuredStub
    darwinAgentTools
    defaultsConfig
    evalAgentTools
    linuxAgentTools
    policyConfig
    stubOmp
    untrustedConfig
    yoloConfig
    ;
}
