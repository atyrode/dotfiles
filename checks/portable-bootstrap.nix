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
  coderHttps = mkPortableHomeConfiguration {
    inherit profileName;
    username = "coder";
    homeDirectory = "/home/coder";
    gitAuthMode = "https-gh";
  };
  developer = mkPortableHomeConfiguration {
    inherit profileName;
    username = "developer";
    homeDirectory = "/srv/developer";
  };
  coderIdentity = builtins.fromJSON coder.config.xdg.configFile."atyrode/host.json".text;
  developerIdentity = builtins.fromJSON developer.config.xdg.configFile."atyrode/host.json".text;
  coderHttpsIdentity = builtins.fromJSON coderHttps.config.xdg.configFile."atyrode/host.json".text;
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
  coder.config.home.sessionVariables.ATYRODE_GIT_AUTH_MODE == "ssh"
) "portable bootstrap must expose its selected Git auth mode";
assert lib.assertMsg (
  coderHttps.config.home.sessionVariables.ATYRODE_GIT_AUTH_MODE == "https-gh"
) "portable HTTPS bootstrap must persist its Git auth mode in the session";
assert lib.assertMsg (
  coderHttps.config.programs.gh.settings.git_protocol == "https"
) "portable HTTPS bootstrap must keep gh clones on HTTPS";
assert lib.assertMsg coderHttps.config.programs.gh.gitCredentialHelper.enable
  "portable HTTPS bootstrap must declare the gh credential helper";
assert lib.assertMsg (
  lib.attrByPath
    [
      "url"
      "git@github.com:"
      "pushInsteadOf"
    ]
    null
    coderHttps.config.programs.git.settings
  == null
) "portable HTTPS bootstrap must not rewrite GitHub pushes to SSH";
assert lib.assertMsg (
  !(fixedHomeConfig.config.home.sessionVariables ? CODE_FACET_GLYPHS)
) "portable Code glyphs must not leak into fixed host configurations";
assert lib.assertMsg (
  coderIdentity == {
    activation = "home-manager";
    inherit (coderIdentity) capabilities;
    inherit (coderIdentity) description;
    homeDirectory = "/home/coder";
    gitAuthMode = "ssh";
    id = profileName;
    identityMode = "runtime";
    platform = "linux";
    system = pkgs.stdenv.hostPlatform.system;
    username = "coder";
  }
) "portable bootstrap must persist a concrete runtime identity";
assert lib.assertMsg (
  coderHttpsIdentity.gitAuthMode == "https-gh"
) "portable HTTPS bootstrap identity must record its Git auth mode";
assert lib.assertMsg (
  developer.config.home.username == "developer"
) "portable bootstrap must instantiate independently for another user";
assert lib.assertMsg (
  developerIdentity.homeDirectory == "/srv/developer"
) "portable bootstrap must keep identities isolated";
builtins.deepSeq [
  coder.activationPackage.drvPath
  coderHttps.activationPackage.drvPath
  developer.activationPackage.drvPath
] (
  pkgs.runCommand "check-portable-bootstrap-${pkgs.stdenv.hostPlatform.system}" { } ''
    mkdir "$out"
  ''
)
