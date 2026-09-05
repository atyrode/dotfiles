# Every owned machine is a declared spoke. Native service contracts must keep
# unenrolled machines inert and credentials outside the Nix store while making
# enrolled agents durable on both user managers.
{
  hosts,
  lib,
  nixosConfigs,
  darwinConfigs,
  pkgs,
  serverConfig,
  system,
}:

let
  inventory = builtins.fromJSON (builtins.readFile ../../fleet/manifold.json);
  supported = builtins.elem system inventory.supportedSystems;
  spokesHere = lib.filter (name: hosts.${name}.system == system) inventory.spokes;
  homeConfigs =
    lib.optionalAttrs (serverConfig != null) {
      "the server profile" = serverConfig;
    }
    // lib.listToAttrs (
      map (
        name:
        lib.nameValuePair name (
          if hosts.${name}.platform == "darwin" then
            darwinConfigs.${name}.config.home-manager.users.${hosts.${name}.username}
          else
            nixosConfigs.${name}.config.home-manager.users.${hosts.${name}.username}
        )
      ) spokesHere
    );
  splitHomeConfigs = lib.listToAttrs (
    map (
      name:
      let
        machine =
          (if hosts.${name}.platform == "darwin" then darwinConfigs.${name} else nixosConfigs.${name})
          .extendModules
            {
              modules = [
                {
                  nixpkgs.overlays = [
                    (_final: previous: {
                      manifold-agent = previous.manifold-agent.overrideAttrs (old: {
                        passthru = (old.passthru or { }) // {
                          terminalHostProtocol = 1;
                        };
                      });
                    })
                  ];
                }
              ];
            };
      in
      lib.nameValuePair name machine.config.home-manager.users.${hosts.${name}.username}
    ) spokesHere
  );
  one = value: lib.toList value;
  contract =
    split: name: homeConfig:
    let
      unit = homeConfig.systemd.user.services.manifold-agent or null;
      launchAgent = homeConfig.launchd.agents.manifold-agent or null;
      hostUnit = homeConfig.systemd.user.services.manifold-terminal-host or null;
      hostLaunch = homeConfig.launchd.agents.manifold-terminal-host or null;
      packageNames = map lib.getName homeConfig.home.packages;
      machineName = homeConfig.home.sessionVariables.ATYRODE_HOST or "%H";
      tokenFile = "${homeConfig.home.homeDirectory}/.config/manifold/machine.token";
      environment = lib.toList (unit.Service.Environment or [ ]);
      hasEnvironment = entry: builtins.elem entry environment;
    in
    if !supported then
      assert lib.assertMsg (
        !(builtins.elem "manifold-agent" packageNames)
      ) "unsupported systems must not install manifold-agent";
      assert lib.assertMsg (
        unit == null && launchAgent == null
      ) "unsupported systems must not declare a Manifold service";
      true
    else
      assert lib.assertMsg (builtins.elem "manifold-agent" packageNames)
        "${name} must install the pinned agent";
      if pkgs.stdenv.hostPlatform.isDarwin then
        assert lib.assertMsg (unit == null) "Darwin must not depend on systemd";
        assert lib.assertMsg (
          launchAgent != null && launchAgent.enable
        ) "${name} must enable the launchd agent";
        assert lib.assertMsg (
          launchAgent.config.ProgramArguments == [ (lib.getExe pkgs.manifold-agent) ]
        ) "the Mac must run the pinned agent";
        assert lib.assertMsg (launchAgent.config.KeepAlive.PathState.${tokenFile} or false
        ) "an unenrolled Mac must remain inert; its placed token enables the agent";
        assert lib.assertMsg (
          launchAgent.config.EnvironmentVariables.MANIFOLD_SERVER_URL == inventory.masterUrl
          && launchAgent.config.EnvironmentVariables.MANIFOLD_MACHINE_NAME == machineName
          && launchAgent.config.EnvironmentVariables.MANIFOLD_MACHINE_TOKEN_FILE == tokenFile
          && !(launchAgent.config.EnvironmentVariables ? MANIFOLD_MACHINE_TOKEN)
        ) "launchd must use reviewed discovery, canonical identity and a token path, never token bytes";
        assert lib.assertMsg (
          launchAgent.config.StandardOutPath
          == "${homeConfig.home.homeDirectory}/.local/state/manifold/agent.log"
          && launchAgent.config.StandardErrorPath == launchAgent.config.StandardOutPath
        ) "connection diagnosis needs the agent event log";
        assert lib.assertMsg (
          if split then
            hostLaunch != null
            && hostLaunch.enable
            &&
              hostLaunch.config.ProgramArguments == [
                "${homeConfig.home.profileDirectory}/bin/manifold-agent"
                "--terminal-host"
              ]
            && !(hostLaunch.config.EnvironmentVariables ? MANIFOLD_MACHINE_TOKEN_FILE)
            &&
              launchAgent.config.EnvironmentVariables.MANIFOLD_TERMINAL_HOST_SOCKET
              == hostLaunch.config.EnvironmentVariables.MANIFOLD_TERMINAL_HOST_SOCKET
          else
            hostLaunch == null && !(launchAgent.config ? "X-Atyrode-SessionOwner")
        ) "the launchd owner must remain stable across transport pin changes and receive no hub credential";
        true
      else
        assert lib.assertMsg (
          unit != null && launchAgent == null
        ) "${name} must enable only the systemd agent";
        assert lib.assertMsg (
          one unit.Service.ExecStart == [ (lib.getExe pkgs.manifold-agent) ]
        ) "the Linux service must run the pinned agent";
        assert lib.assertMsg (
          one unit.Service.Restart == [ "always" ]
          && one unit.Service.RestartSec == [ 3 ]
          && one unit.Unit.StartLimitIntervalSec == [ 0 ]
        ) "the agent must recover from disconnects without exhausting its start limit";
        assert lib.assertMsg (
          one unit.Unit.ConditionPathExists == [ "%h/.config/manifold/machine.token" ]
        ) "an unenrolled Linux machine must remain inert";
        assert lib.assertMsg (
          hasEnvironment "MANIFOLD_SERVER_URL=${inventory.masterUrl}"
          && hasEnvironment "MANIFOLD_MACHINE_NAME=${machineName}"
          && hasEnvironment "MANIFOLD_MACHINE_TOKEN_FILE=%h/.config/manifold/machine.token"
          && !(lib.any (lib.hasPrefix "MANIFOLD_MACHINE_TOKEN=") environment)
        ) "systemd must use reviewed discovery, canonical identity and a token path, never token bytes";
        assert lib.assertMsg (
          lib.toList unit.Install.WantedBy == [ "default.target" ]
        ) "the agent must start with the user manager";
        assert lib.assertMsg (
          if split then
            hostUnit != null
            &&
              one hostUnit.Service.ExecStart == [
                "${homeConfig.home.profileDirectory}/bin/manifold-agent --terminal-host"
              ]
            && one hostUnit.Unit."X-SwitchMethod" == [ "keep-old" ]
            && one hostUnit.Unit.RefuseManualStop == [ true ]
            && (hostUnit.Unit.PartOf or [ ]) == [ ]
            && (hostUnit.Unit.BindsTo or [ ]) == [ ]
            && one unit.Unit."X-Atyrode-SessionOwner" == [ false ]
            && !(lib.any (lib.hasPrefix "MANIFOLD_MACHINE_TOKEN") (one hostUnit.Service.Environment))
          else
            hostUnit == null
            && one unit.Unit."X-SwitchMethod" == [ "keep-old" ]
            && !(unit.Unit.RefuseManualStop or false)
        ) "transport replacement must not stop its independently supervised terminal owner";
        true;
  # The credentials are clan vars: the owner key shared, operator-only and
  # never deployed; the token per machine, placed for the account whose agent
  # reads it, behind the link at the path every unit and the CLI name. A
  # machine that received the owner key, or a token that landed as a file the
  # units cannot find, would pass the unit contract above and still be wrong.
  custody =
    name:
    let
      machine =
        if hosts.${name}.platform == "darwin" then darwinConfigs.${name} else nixosConfigs.${name};
      generators = machine.config.clan.core.vars.generators;
      token = generators.manifold-agent.files."machine-token";
      link = homeConfigs.${name}.home.file.".config/manifold/machine.token";
    in
    assert lib.assertMsg (
      generators.manifold-custody.share && !generators.manifold-custody.files."owner-key".deploy
    ) "${name}: the hub owner key must be shared custody that no machine receives";
    assert lib.assertMsg (
      !generators.manifold-agent.share
      && token.secret
      && token.owner == hosts.${name}.username
      && token.mode == "0600"
    ) "${name}: the machine token must be this machine's own 0600 secret, owned by its account";
    assert lib.assertMsg (
      link.force && link.source != null
    ) "${name}: ~/.config/manifold/machine.token must be the forced link to the placed token";
    true;
in
assert lib.assertMsg (
  lib.sort builtins.lessThan inventory.spokes == builtins.attrNames hosts
) "every owned machine must appear in the Manifold spoke inventory";
assert lib.all (name: builtins.elem "manifold-node" hosts.${name}.capabilities) inventory.spokes;
assert lib.all lib.id (
  lib.mapAttrsToList (contract ((pkgs.manifold-agent.terminalHostProtocol or 0) == 1)) homeConfigs
);
assert lib.all lib.id (lib.mapAttrsToList (contract true) splitHomeConfigs);
assert lib.all custody spokesHere;
pkgs.runCommand "check-manifold-node-${system}" { } ''
  ${lib.optionalString supported ''
    ${lib.getExe pkgs.bun} ${./manifold-agent-smoke.ts} ${lib.getExe pkgs.manifold-agent} ${
      toString (pkgs.manifold-agent.terminalHostProtocol or 0)
    }
  ''}
  mkdir "$out"
''
