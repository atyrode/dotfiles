{
  config,
  lib,
  pkgs,
  ...
}:

let
  orcaHookCommand = "if [ -f '${config.home.homeDirectory}/.orca/agent-hooks/claude-hook.sh' ] && [ -r '${config.home.homeDirectory}/.orca/agent-hooks/claude-hook.sh' ] && [ -x '${config.home.homeDirectory}/.orca/agent-hooks/claude-hook.sh' ]; then /bin/sh '${config.home.homeDirectory}/.orca/agent-hooks/claude-hook.sh'; else cat >/dev/null 2>&1 || :; fi";
  orcaHook = {
    hooks = [
      {
        type = "command";
        command = orcaHookCommand;
        timeout = 10;
      }
    ];
  };
  matchedOrcaHook = orcaHook // {
    matcher = "*";
  };
  settingsText = builtins.toJSON {
    permissions.allow = [ "Bash(gh pr merge:*)" ];
    hooks = {
      UserPromptSubmit = [ orcaHook ];
      Stop = [ orcaHook ];
      StopFailure = [ orcaHook ];
      SubagentStart = [ orcaHook ];
      SubagentStop = [ orcaHook ];
      TeammateIdle = [ orcaHook ];
      PreToolUse = [ matchedOrcaHook ];
      PostToolUse = [ matchedOrcaHook ];
      PostToolUseFailure = [ matchedOrcaHook ];
      PermissionRequest = [ matchedOrcaHook ];
    };
  };
  settingsTemplate = pkgs.writeText "claude-settings.json" settingsText;
  settingsDirectory = "${config.home.homeDirectory}/.claude";
  settingsPath = "${settingsDirectory}/settings.json";
in
{
  # Nix owns Claude Code's durable operator policy and the required Orca hook
  # contract. The live settings file remains a regular writable file so Orca
  # can make its managed-hook backup/update without fighting a store symlink.
  home.file.".claude/CLAUDE.md".source = ./claude/CLAUDE.md;

  # Keep a managed template for evaluation checks and restore it on every
  # activation. Orca may update the writable live copy between activations.
  home.file.".local/share/atyrode/claude-settings.json".text = settingsText;

  home.activation.installClaudeSettings =
    lib.hm.dag.entryAfter
      [
        "installPackages"
        "linkGeneration"
      ]
      ''
        if [[ -v DRY_RUN ]]; then
          echo "Would install writable Claude settings at ${settingsPath}"
        else
          ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg settingsDirectory}
          ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg "${settingsPath}.bak"}
          temporary=${lib.escapeShellArg "${settingsPath}.tmp"}.$$
          ${pkgs.coreutils}/bin/install -m 0600 ${settingsTemplate} "$temporary"
          ${pkgs.coreutils}/bin/mv -f "$temporary" ${lib.escapeShellArg settingsPath}
        fi
      '';
}
