{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.atyrode.agentTools;
  defaultsConfig = ../../omp/defaults.yml;
  policyConfig = ../../omp/policy.yml;
  untrustedConfig = ../../omp/untrusted.yml;
  presets = {
    budget = ../../omp/presets/budget.yml;
    fable = ../../omp/presets/fable-primary.yml;
    gpt = ../../omp/presets/gpt56.yml;
    sonnet = ../../omp/presets/sonnet-value.yml;
    claude = ../../omp/presets/claude-hard.yml;
    context = ../../omp/presets/context-1m.yml;
    fast = ../../omp/presets/fast-mixed.yml;
    gptSpeed = ../../omp/presets/gpt-speed.yml;
    claudeSpeed = ../../omp/presets/claude-speed.yml;
    mixedRegular = ../../omp/presets/mixed-regular.yml;
    mixedSmart = ../../omp/presets/mixed-smart.yml;
    gptOnly = ../../omp/presets/gpt-only.yml;
    claudeOnly = ../../omp/presets/claude-only.yml;
  };

in
{
  options.atyrode.agentTools = {
    enable = lib.mkEnableOption "the declarative OMP stack";

    migrateLegacy = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Back up conflicting legacy agent-tool paths before Home Manager links managed files.";
    };

    seedPlainConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Seed the curated plain-omp defaults into the writable machine
        configuration with drift reporting. Local edits always win.
      '';
    };

    ompPackage = lib.mkPackageOption pkgs "omp-configured" { };
    ompAgentsPackage = lib.mkPackageOption pkgs "omp-agents" { };
    migrationPackage = lib.mkPackageOption pkgs "agent-tools-migrate" { };
    seedPackage = lib.mkPackageOption pkgs "omp-seed" { };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      cfg.ompPackage
    ]
    ++ lib.optional cfg.seedPlainConfig cfg.seedPackage;

    xdg.configFile = {
      "omp/defaults.yml".source = defaultsConfig;
      "omp/policy.yml".source = policyConfig;
      "omp/untrusted.yml".source = untrustedConfig;
      "omp/presets/budget.yml".source = presets.budget;
      "omp/presets/fable-primary.yml".source = presets.fable;
      "omp/presets/gpt56.yml".source = presets.gpt;
      "omp/presets/sonnet-value.yml".source = presets.sonnet;
      "omp/presets/claude-hard.yml".source = presets.claude;
      "omp/presets/context-1m.yml".source = presets.context;
      "omp/presets/fast-mixed.yml".source = presets.fast;
      "omp/presets/gpt-speed.yml".source = presets.gptSpeed;
      "omp/presets/claude-speed.yml".source = presets.claudeSpeed;
      "omp/presets/mixed-regular.yml".source = presets.mixedRegular;
      "omp/presets/mixed-smart.yml".source = presets.mixedSmart;
      "omp/presets/gpt-only.yml".source = presets.gptOnly;
      "omp/presets/claude-only.yml".source = presets.claudeOnly;
    };

    home.file = {
      ".agents/skills" = {
        source = ../../agents/skills;
        recursive = true;
      };
    };

    home.activation = lib.mkMerge [
      (lib.mkIf cfg.migrateLegacy {
        migrateLegacyAgentTools = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
          if [[ -v DRY_RUN ]]; then
            export AGENT_TOOLS_DRY_RUN=1
          fi
          ${lib.getExe cfg.migrationPackage} prepare
        '';

        finalizeLegacyAgentTools = lib.hm.dag.entryAfter [ "installPackages" "linkGeneration" ] ''
          if [[ -v DRY_RUN ]]; then
            export AGENT_TOOLS_DRY_RUN=1
          fi
          ${lib.getExe cfg.migrationPackage} finalize "$newGenPath/home-files"
        '';
      })
      (lib.mkIf cfg.seedPlainConfig {
        # Runs after the legacy migration so a first activation seeds the
        # transformed configuration, never the pre-migration backup source.
        # Seeding is a convenience: a failure (for example unparseable
        # operator YAML) warns instead of failing the whole activation.
        seedPlainOmpConfig =
          lib.hm.dag.entryAfter
            ([ "installPackages" "linkGeneration" ] ++ lib.optional cfg.migrateLegacy "finalizeLegacyAgentTools")
            ''
              if [[ -v DRY_RUN ]]; then
                export AGENT_TOOLS_DRY_RUN=1
              fi
              if ! ${lib.getExe cfg.seedPackage} apply; then
                echo "warning: plain-omp seeding failed; inspect with atyrode-omp-seed status" >&2
              fi
            '';
      })
    ];
  };
}
