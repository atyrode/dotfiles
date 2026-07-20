{
  hostConfigs,
  lib,
  pkgs,
}:

let
  packageName = package: package.pname or (lib.getName package);
  hostNames = builtins.attrNames hostConfigs;
  agentToolHosts = lib.filter (
    name: builtins.elem "agent-tools" hostConfigs.${name}.config.atyrode.capabilities.selected
  ) hostNames;
  linuxAgentToolHosts = lib.filter (name: hostConfigs.${name}.pkgs.stdenv.isLinux) agentToolHosts;
  packagesFor = name: map packageName hostConfigs.${name}.config.home.packages;
  linuxLinksFor = name: hostConfigs.${name}.config.home.file;
  claudeHookEvents = [
    "UserPromptSubmit"
    "Stop"
    "StopFailure"
    "SubagentStart"
    "SubagentStop"
    "TeammateIdle"
    "PreToolUse"
    "PostToolUse"
    "PostToolUseFailure"
    "PermissionRequest"
  ];
  matchedClaudeHookEvents = [
    "PreToolUse"
    "PostToolUse"
    "PostToolUseFailure"
    "PermissionRequest"
  ];
in
assert lib.assertMsg (
  agentToolHosts != [ ]
) "the Orca check requires at least one agent-tools host";
assert lib.assertMsg (lib.all (
  name: builtins.elem "orca-ide" (packagesFor name)
) agentToolHosts) "every agent-tools host must carry the pinned Orca package";
assert lib.assertMsg (lib.all
  (
    name:
    let
      settingsFile = hostConfigs.${name}.config.home.file.".claude/settings.json";
      settings = builtins.fromJSON settingsFile.text;
      hookEntry = event: builtins.head settings.hooks.${event};
      hookCommand = event: (builtins.head (hookEntry event).hooks).command;
    in
    settingsFile.force
    && lib.all (event: builtins.hasAttr event settings.hooks) claudeHookEvents
    && lib.all (
      event: lib.hasInfix "/.orca/agent-hooks/claude-hook.sh" (hookCommand event)
    ) claudeHookEvents
    && lib.all (event: (hookEntry event).matcher == "*") matchedClaudeHookEvents
  )
  agentToolHosts
) "agent-tools hosts must declare and forcibly restore Orca's Claude hooks in Nix-owned settings";
assert lib.assertMsg
  (lib.all (
    name:
    let
      links = linuxLinksFor name;
      package = hostConfigs.${name}.pkgs.orca-ide;
    in
    links ? ".local/bin/orca"
    && links ? ".local/bin/orca-ide"
    && links.".local/bin/orca".source == lib.getExe package
    && links.".local/bin/orca-ide".source == "${package}/bin/orca-ide"
  ) linuxAgentToolHosts)
  "Linux agent-tools hosts must reserve Orca's mutable ~/.local/bin launchers with Home Manager links";
assert lib.assertMsg (lib.all
  (
    name:
    let
      services = hostConfigs.${name}.config.systemd.user.services;
    in
    !(services ? orca) && !(services ? orca-serve)
  )
  linuxAgentToolHosts
) "dotfiles must not auto-run an Orca server; production service policy belongs to infrastructure";
pkgs.runCommand "check-orca-integration" { } ''
  test -x ${lib.getExe pkgs.orca-ide}
  mkdir "$out"
''
