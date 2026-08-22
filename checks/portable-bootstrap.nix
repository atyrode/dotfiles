{
  fixedHomeConfig,
  lib,
  mkPortableHomeConfiguration,
  pkgs,
  profileName,
}:

let
  coder = mkPortableHomeConfiguration {
    inherit profileName;
    username = "coder";
    homeDirectory = "/home/coder";
  };
  developer = mkPortableHomeConfiguration {
    inherit profileName;
    username = "developer";
    homeDirectory = "/srv/developer";
  };
  coderIdentity = builtins.fromJSON coder.config.xdg.configFile."atyrode/host.json".text;
  developerIdentity = builtins.fromJSON developer.config.xdg.configFile."atyrode/host.json".text;
in
assert lib.assertMsg (
  coder.config.home.username == "coder"
) "portable bootstrap must use the supplied username";
assert lib.assertMsg (
  coder.config.home.homeDirectory == "/home/coder"
) "portable bootstrap must use the supplied home";
assert lib.assertMsg
  (builtins.elem "/home/coder/.local/state/nix/profiles/home-manager/home-path/bin" coder.config.home.sessionPath)
  "portable bootstrap must expose its complete managed command environment";
assert lib.assertMsg (lib.all (path: !lib.hasSuffix "/nix/profiles/home-manager/home-path/bin" path)
  fixedHomeConfig.config.home.sessionPath
) "portable command paths must not leak into fixed host configurations";
assert lib.assertMsg (
  coder.config.home.sessionVariables.CODE_FACET_GLYPHS
  == "runtime=@,lane=~,model=#,thinking=?,advisor=&,spark=^,fable=*,main=+,fast=!,relief=%"
) "portable bootstrap must use terminal-portable Code glyphs";
assert lib.assertMsg (
  !(fixedHomeConfig.config.home.sessionVariables ? CODE_FACET_GLYPHS)
) "portable Code glyphs must not leak into fixed host configurations";
assert lib.assertMsg (
  coderIdentity == {
    activation = "home-manager";
    inherit (coderIdentity) capabilities;
    inherit (coderIdentity) description;
    homeDirectory = "/home/coder";
    id = profileName;
    identityMode = "runtime";
    platform = "linux";
    system = pkgs.stdenv.hostPlatform.system;
    username = "coder";
  }
) "portable bootstrap must persist a concrete runtime identity";
assert lib.assertMsg (
  developer.config.home.username == "developer"
) "portable bootstrap must instantiate independently for another user";
assert lib.assertMsg (
  developerIdentity.homeDirectory == "/srv/developer"
) "portable bootstrap must keep identities isolated";
builtins.deepSeq [ coder.activationPackage.drvPath developer.activationPackage.drvPath ] (
  pkgs.runCommand "check-portable-bootstrap-${pkgs.stdenv.hostPlatform.system}" { } ''
    mkdir "$out"
  ''
)
