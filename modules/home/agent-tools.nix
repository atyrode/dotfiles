{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.atyrode.agentTools;
  baseConfig = ../../omp/config.yml;
  presets = {
    budget = ../../omp/presets/budget.yml;
    fable = ../../omp/presets/fable-primary.yml;
    gpt = ../../omp/presets/gpt56.yml;
    opusFallback = ../../omp/presets/opus-fallback.yml;
  };

  herdrCompletions = pkgs.runCommand "herdr-completions-${lib.getVersion cfg.herdrPackage}" { } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    mkdir -p "$out/share/zsh/site-functions"
    ${lib.getExe cfg.herdrPackage} completion zsh > "$out/share/zsh/site-functions/_herdr"
  '';
in
{
  options.atyrode.agentTools = {
    enable = lib.mkEnableOption "the declarative OMP and Herdr stack";

    migrateLegacy = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Back up conflicting legacy agent-tool paths before Home Manager links managed files.";
    };

    ompPackage = lib.mkPackageOption pkgs "omp-configured" { };
    herdrPackage = lib.mkPackageOption pkgs "herdr-configured" { };
    ompAgentsPackage = lib.mkPackageOption pkgs "omp-agents" { };
    herdrIntegrationPackage = lib.mkPackageOption pkgs "herdr-omp-integration" { };
    migrationPackage = lib.mkPackageOption pkgs "agent-tools-migrate" { };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      cfg.herdrPackage
      herdrCompletions
      cfg.ompPackage
    ];

    xdg.configFile = {
      "omp/base.yml".source = baseConfig;
      "omp/presets/budget.yml".source = presets.budget;
      "omp/presets/fable-primary.yml".source = presets.fable;
      "omp/presets/gpt56.yml".source = presets.gpt;
      "omp/presets/opus-fallback.yml".source = presets.opusFallback;
    };

    home.file = {
      ".agents/skills" = {
        source = ../../agents/skills;
        recursive = true;
      };

      ".omp/agent/agents" = {
        source = "${cfg.ompAgentsPackage}/share/omp/agents";
        recursive = true;
      };

      ".omp/agent/extensions/herdr-omp-agent-state.ts".source =
        "${cfg.herdrIntegrationPackage}/share/omp/extensions/herdr-omp-agent-state.ts";

      ".omp/agent/rules/no-shell-text-surgery.md".source = ../../omp/rules/no-shell-text-surgery.md;
    };

    home.activation.migrateLegacyAgentTools = lib.mkIf cfg.migrateLegacy (
      lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
        if [[ -v DRY_RUN ]]; then
          export AGENT_TOOLS_DRY_RUN=1
        fi
        ${lib.getExe cfg.migrationPackage}
      ''
    );
  };
}
