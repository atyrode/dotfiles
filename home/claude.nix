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
  # Nix owns Claude Code's durable operator policy. The live settings file
  # remains a regular writable file so tooling may extend it between
  # activations; every activation restores the reviewed template.
  home.file.".claude/CLAUDE.md".source = ./claude/CLAUDE.md;

  # Keep a managed template for evaluation checks and restore it on every
  # activation. Tooling may update the writable live copy between activations.
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
