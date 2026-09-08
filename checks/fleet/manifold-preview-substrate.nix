{
  lib,
  pkgs,
  hostConfig,
}:
let
  registry = import ../../modules/home/ssh/deploy-keys.nix { inherit lib; };
  expectedKeys = registry.forHost "dev-01" (builtins.readFile ../../modules/home/ssh/deploy-keys);
  actualKeys = hostConfig.users.users.alex.openssh.authorizedKeys.keys;
  forcedKeys = lib.filter (key: lib.hasPrefix "command=" key) actualKeys;
in
assert lib.assertMsg (forcedKeys == expectedKeys)
  "dev-01 must install exactly the reviewed role-scoped forced keys";
assert lib.assertMsg (
  hostConfig.services.openssh.authorizedKeysFiles == [ "/etc/ssh/authorized_keys.d/%u" ]
  && !hostConfig.services.openssh.authorizedKeysInHomedir
  && hostConfig.services.openssh.authorizedKeysCommand == "none"
) "mutable home keys and key commands must not bypass the root-owned receiver authority";
assert lib.assertMsg (builtins.elem pkgs.preview-tools hostConfig.environment.systemPackages)
  "dev-01 must install the product receiver in its root-owned system profile";
pkgs.runCommand "check-manifold-preview-substrate" { } ''
  # Inspect the actual system-profile projection, not a second locally wrapped
  # receiver. Product qualification owns receiver behavior and dependency hashes.
  test -x ${hostConfig.system.path}/bin/manifold-preview-receiver
  test "$(readlink -f ${hostConfig.system.path}/bin/manifold-preview-receiver)" = \
    "$(readlink -f ${pkgs.preview-tools}/bin/manifold-preview-receiver)"
  mkdir "$out"
''
