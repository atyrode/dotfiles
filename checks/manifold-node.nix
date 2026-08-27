# The manifold-node capability contract (#418/#419), asserted on the portable
# server composition that tyrode-dev-01 consumes: the pinned agent is
# installed, the user service runs the immutable store binary with a bounded
# restart policy, enrollment gates the unit through the token-file condition,
# and no token material can enter the unit text. Systems outside the pin's
# supported set must stay clean: they keep evaluating without referencing the
# unbuildable package.
{
  lib,
  pkgs,
  serverConfig,
  system,
}:

let
  inventory = builtins.fromJSON (builtins.readFile ../inventory/manifold.json);
  supported = builtins.elem system inventory.supportedSystems;
  unit = serverConfig.systemd.user.services.manifold-agent or null;
  packageNames = map lib.getName serverConfig.home.packages;
  environment = lib.toList (unit.Service.Environment or [ ]);
  hasEnvironment = entry: builtins.elem entry environment;
  # The unit type merges repeatable INI keys into lists, so a single
  # definition reads back as a singleton; compare through toList.
  one = value: lib.toList value;
in
if supported then
  assert lib.assertMsg (builtins.elem "manifold-agent" packageNames)
    "the server profile must install the pinned manifold-agent";
  assert lib.assertMsg (unit != null) "the server profile must declare the manifold-agent unit";
  assert lib.assertMsg (
    one unit.Service.ExecStart == [ (lib.getExe pkgs.manifold-agent) ]
  ) "manifold-agent must execute the immutable pinned store binary";
  assert lib.assertMsg (
    one unit.Service.Restart == [ "always" ]
    && one unit.Service.RestartSec == [ 3 ]
    && one unit.Unit.StartLimitIntervalSec == [ 0 ]
  ) "manifold-agent must restart always, with a bounded delay and no start rate limit";
  assert lib.assertMsg (
    one unit.Unit.ConditionPathExists == [ "%h/.config/manifold/machine.token" ]
  ) "an unenrolled machine must skip the unit, not fail it";
  assert lib.assertMsg (hasEnvironment "MANIFOLD_SERVER_URL=${inventory.masterUrl}")
    "the unit must dial the committed master declaration";
  assert lib.assertMsg (hasEnvironment "MANIFOLD_MACHINE_NAME=%H")
    "the machine name must be the hostname, matching what provisioning enrolls";
  assert lib.assertMsg
    (hasEnvironment "MANIFOLD_MACHINE_TOKEN_FILE=%h/.config/manifold/machine.token")
    "the agent must read the token from the 0600 file";
  assert lib.assertMsg (
    !(lib.any (lib.hasPrefix "MANIFOLD_MACHINE_TOKEN=") environment)
  ) "the machine token must never enter the unit text";
  assert lib.assertMsg (
    lib.toList unit.Install.WantedBy == [ "default.target" ]
  ) "manifold-agent must start with the user manager";
  pkgs.runCommand "check-manifold-node-${system}" { } ''
    mkdir "$out"
  ''
else
  assert lib.assertMsg (
    !(builtins.elem "manifold-agent" packageNames)
  ) "systems without a filled upstream deps hash must not reference manifold-agent";
  assert lib.assertMsg (
    unit == null
  ) "systems outside the supported set must not declare the manifold-agent unit";
  pkgs.runCommand "check-manifold-node-${system}" { } ''
    mkdir "$out"
  ''
