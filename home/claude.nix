{
  config,
  lib,
  pkgs,
  ...
}:

let
  settingsText = builtins.toJSON {
    permissions.allow = [ "Bash(gh pr merge:*)" ];
  };
  settingsTemplate = pkgs.writeText "claude-settings.json" settingsText;
  settingsDirectory = "${config.home.homeDirectory}/.claude";
  settingsPath = "${settingsDirectory}/settings.json";
in
{
  # Nix owns Claude Code's durable operator policy: the instructions come from
  # the generated agent context (home/agents.nix) and the permission rules
  # from here. The live settings file remains a regular writable file so
  # tooling may extend it between activations; every activation restores the
  # reviewed template, which is also kept in place for evaluation checks.
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
