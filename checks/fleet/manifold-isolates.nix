{
  lib,
  pkgs,
  nixosConfigs,
}:
let
  home = nixosConfigs.dev-01.config.home-manager.users.alex;
  unit = home.systemd.user.services.manifold-dev-isolates;
  slice = home.systemd.user.slices.manifold-dev-isolates;
  one = lib.toList;
  otherHosts = lib.filterAttrs (name: _: name != "dev-01") nixosConfigs;
in
assert lib.assertMsg (
  one unit.Service.Delegate == [ "cpu memory pids" ]
  && one unit.Service.Slice == [ "manifold-dev-isolates.slice" ]
  && one unit.Service.KillMode == [ "process" ]
  && one unit.Service.SendSIGKILL == [ false ]
  && one unit.Service.Restart == [ "no" ]
  && one unit.Service.RuntimeDirectoryMode == [ "0700" ]
  && one unit.Service.RuntimeDirectoryPreserve == [ "yes" ]
) "the dedicated holder must delegate only required controllers and never kill descendant workloads";
assert lib.assertMsg (
  one unit.Unit."X-SwitchMethod" == [ "keep-old" ]
  && one unit.Unit.RefuseManualStop == [ true ]
  && one slice.Unit."X-SwitchMethod" == [ "keep-old" ]
  && one slice.Unit.RefuseManualStop == [ true ]
  && (unit.Unit.PartOf or [ ]) == [ ]
  && (unit.Unit.BindsTo or [ ]) == [ ]
) "ordinary receiver and Docker updates must not replace the retained owner or its slice";
assert lib.assertMsg (
  lib.all (
    machine:
    lib.all (
      user: !(user.systemd.user.services ? manifold-dev-isolates)
    ) (builtins.attrValues machine.config.home-manager.users)
  ) (builtins.attrValues otherHosts)
) "dedicated sandbox delegation must remain dev-01-only";
pkgs.runCommand "check-manifold-isolates" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${../atyrode/manifold-isolates-test.py} \
    ${../../modules/home/manifold-dev-isolates/holder.py} \
    ${../../modules/home/manifold-dev-isolates/provision.py} \
    ${pkgs.atyrode}/libexec/atyrode-disruption \
    ${home.xdg.configFile."systemd/user/manifold-dev-isolates.service".source} \
    ${home.xdg.configFile."systemd/user/manifold-dev-isolates.slice".source}
  touch "$out"
''
