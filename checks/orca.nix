{
  hostConfigs,
  lib,
  pkgs,
}:

let
  packageName = package: package.pname or (lib.getName package);
  orcaExecutable =
    if pkgs.stdenv.isDarwin then
      "${pkgs.orca-ide}/Applications/Orca.app/Contents/MacOS/Orca"
    else
      lib.getExe pkgs.orca-ide;
  hostNames = builtins.attrNames hostConfigs;
  agentToolHosts = lib.filter (
    name: builtins.elem "agent-tools" hostConfigs.${name}.config.atyrode.capabilities.selected
  ) hostNames;
  linuxAgentToolHosts = lib.filter (name: hostConfigs.${name}.pkgs.stdenv.isLinux) agentToolHosts;
  nativeAgentToolHosts = lib.filter (
    name: hostConfigs.${name}.pkgs.stdenv.hostPlatform.system == pkgs.stdenv.hostPlatform.system
  ) agentToolHosts;
  nativeDesktopAgentToolHosts = lib.filter (
    name: builtins.elem "desktop" hostConfigs.${name}.config.atyrode.capabilities.selected
  ) nativeAgentToolHosts;
  nativeNonDesktopAgentToolHosts = lib.subtractLists nativeDesktopAgentToolHosts nativeAgentToolHosts;
  packagesFor = name: map packageName hostConfigs.${name}.config.home.packages;
  homeFilesFor = name: hostConfigs.${name}.config.home.file;
  skillsFor = name: (homeFilesFor name).".agents/skills".source;
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
assert lib.assertMsg (lib.all (
  name: builtins.elem "nodejs" (packagesFor name)
) agentToolHosts) "every agent-tools host must carry npx for Orca registry and relay workflows";
assert lib.assertMsg (lib.all (
  name: builtins.elem "bun" (packagesFor name)
) agentToolHosts) "every agent-tools host must carry Bun for agent-generated local review proxies";
assert lib.assertMsg (lib.all
  (
    name:
    lib.all (package: builtins.elem package (packagesFor name)) [
      "procps"
      "systemd"
    ]
  )
  linuxAgentToolHosts
) "Linux agent-tools hosts must expose process and user-service diagnostics inside Orca terminals";
assert lib.assertMsg (lib.all
  (
    name:
    let
      homeFiles = homeFilesFor name;
      settingsFile = homeFiles.".local/share/atyrode/claude-settings.json";
      settings = builtins.fromJSON settingsFile.text;
      hookEntry = event: builtins.head settings.hooks.${event};
      hookCommand = event: (builtins.head (hookEntry event).hooks).command;
    in
    !(homeFiles ? ".claude/settings.json")
    && hostConfigs.${name}.config.home.activation ? installClaudeSettings
    && lib.all (event: builtins.hasAttr event settings.hooks) claudeHookEvents
    && lib.all (
      event: lib.hasInfix "/.orca/agent-hooks/claude-hook.sh" (hookCommand event)
    ) claudeHookEvents
    && lib.all (event: (hookEntry event).matcher == "*") matchedClaudeHookEvents
  )
  agentToolHosts
) "agent-tools hosts must restore Orca's Claude hooks into a writable live settings file";
assert lib.assertMsg (lib.all (
  name:
  let
    links = homeFilesFor name;
  in
  !(links ? ".local/bin/orca")
  && !(links ? ".local/bin/orca-ide")
  && hostConfigs.${name}.config.home.activation ? removeOrcaManagedLaunchers
) linuxAgentToolHosts) "Linux agent-tools hosts must reconcile only Orca-owned mutable launchers";
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
  test -x ${orcaExecutable}
  ${lib.optionalString pkgs.stdenv.isDarwin ''
    test ! -e ${pkgs.orca-ide}/bin/orca
  ''}
  grep -qF 'ORCA_SKILL_UPSTREAM_VERSION=${pkgs.orca-ide.version}' ${../agents/desktop-skills/computer-use/SKILL.md}
  ${lib.concatMapStringsSep "\n" (name: ''
    test ! -e ${skillsFor name}/orca-cli
  '') nativeAgentToolHosts}
  ${lib.concatMapStringsSep "\n" (name: ''
    test ! -e ${skillsFor name}/orchestration
  '') nativeAgentToolHosts}
  ${lib.concatMapStringsSep "\n" (name: ''
    test -f ${skillsFor name}/computer-use/SKILL.md
  '') nativeDesktopAgentToolHosts}
  ${lib.concatMapStringsSep "\n" (name: ''
    test ! -e ${skillsFor name}/computer-use
  '') nativeNonDesktopAgentToolHosts}
  mkdir "$out"
''
