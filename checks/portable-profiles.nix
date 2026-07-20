{
  alternateServerHomeConfig,
  externalFixture,
  lib,
  pkgs,
  selectHomeManagerProfiles,
  serverHomeConfig,
  serverPolicy,
  serverProfileManifest,
  system,
}:

let
  sort = lib.sort builtins.lessThan;
  externalConfig = externalFixture.configuration;
  externalHome = externalConfig.config.home-manager.users.fixture;
  serverConfig = serverHomeConfig.config;
  alternateServerConfig = alternateServerHomeConfig.config;
  packageNames = config: sort (lib.unique (map lib.getName config.home.packages));
  serverPackageNames = packageNames serverConfig;
  alternateServerPackageNames = packageNames alternateServerConfig;
  externalPackageNames = packageNames externalHome;
  integrationPackages = [
    "dummy-fc-dir1"
    "dummy-fc-dir2"
    "home-manager"
  ];
  portableServerPackageNames = lib.subtractLists integrationPackages serverPackageNames;
  portableExternalPackageNames = lib.subtractLists integrationPackages externalPackageNames;
  onlyStandalone = lib.subtractLists portableExternalPackageNames portableServerPackageNames;
  onlyExternal = lib.subtractLists portableServerPackageNames portableExternalPackageNames;
  selectedCapabilities = sort serverConfig.atyrode.capabilities.selected;
  expectedCapabilities = sort serverPolicy.capabilities;
  missingRequired = lib.subtractLists serverPackageNames serverPolicy.requiredTopLevelPackages;
  leakedForbidden = lib.intersectLists serverPackageNames serverPolicy.forbiddenTopLevelPackages;
  externalAtyrode = lib.findFirst (
    package: lib.getName package == "atyrode"
  ) (throw "external server fixture does not install atyrode") externalHome.home.packages;
  fixtureIdentity = builtins.fromJSON externalHome.xdg.configFile."atyrode/host.json".text;
  selectionSucceeds =
    capabilities: selectedSystem:
    (builtins.tryEval (
      builtins.deepSeq (selectHomeManagerProfiles {
        inherit capabilities;
        name = "invalid composition fixture";
        system = selectedSystem;
      }) true
    )).success;
  evaluationPaths = [
    serverHomeConfig.activationPackage.drvPath
    alternateServerHomeConfig.activationPackage.drvPath
    externalHome.home.activationPackage.drvPath
    externalConfig.config.system.build.toplevel.drvPath
  ];
in
assert lib.assertMsg (
  selectedCapabilities == expectedCapabilities
) "portable server selected an unexpected capability set";
assert lib.assertMsg (
  serverPackageNames == alternateServerPackageNames
) "portable server package selection depends on the fixture user or home";
assert lib.assertMsg (portableServerPackageNames == portableExternalPackageNames)
  "standalone and NixOS-imported server profiles differ; standalone-only: ${lib.concatStringsSep ", " onlyStandalone}; NixOS-only: ${lib.concatStringsSep ", " onlyExternal}";
assert lib.assertMsg (
  missingRequired == [ ]
) "portable server is missing required packages: ${lib.concatStringsSep ", " missingRequired}";
assert lib.assertMsg (
  leakedForbidden == [ ]
) "portable server leaked forbidden packages: ${lib.concatStringsSep ", " leakedForbidden}";
assert lib.assertMsg serverConfig.programs.home-manager.enable
  "portable server must enable Home Manager";
assert lib.assertMsg serverConfig.programs.zsh.enable "portable server must enable Zsh";
assert lib.assertMsg serverConfig.programs.git.enable "portable server must enable Git";
assert lib.assertMsg serverConfig.programs.gh.enable "portable server must enable GitHub CLI";
assert lib.assertMsg (
  serverConfig.programs.gh.settings.git_protocol == "ssh"
) "portable server must make gh clones use SSH";
assert lib.assertMsg serverConfig.programs.gh.gitCredentialHelper.enable
  "portable server must declare the gh Git credential helper";
assert lib.assertMsg (builtins.any (lib.hasSuffix "/bin/gh auth git-credential")
  serverConfig.programs.git.settings.credential."https://github.com".helper
) "portable server must render the gh helper into Git configuration";
assert lib.assertMsg (
  serverConfig.programs.git.settings.url."git@github.com:".pushInsteadOf == "https://github.com/"
) "portable server must rewrite GitHub pushes, not anonymous fetches, to SSH";
assert lib.assertMsg (
  serverConfig.programs.git.settings.url."git@gitlab.com:".pushInsteadOf == "https://gitlab.com/"
) "portable server must rewrite GitLab pushes, not anonymous fetches, to SSH";
assert lib.assertMsg (
  serverConfig.xdg.configFile."git/allowed_signers".source == ../home/git-allowed-signers
) "portable server must deploy the reviewed allowed_signers source";
assert lib.assertMsg (
  serverConfig.programs.git.settings.gpg.ssh.allowedSignersFile
  == "${serverConfig.xdg.configHome}/git/allowed_signers"
) "Git must use the Home Manager-owned allowed_signers path";
assert lib.assertMsg serverConfig.programs.fzf.enable "portable server must enable fzf";
assert lib.assertMsg serverConfig.programs.zoxide.enable "portable server must enable zoxide";
assert lib.assertMsg serverConfig.programs.direnv.nix-direnv.enable
  "portable server must enable nix-direnv";
assert lib.assertMsg serverConfig.programs.nix-index.enable "portable server must enable nix-index";
assert lib.assertMsg serverConfig.programs.nix-index-database.comma.enable
  "portable server must enable comma";
assert lib.assertMsg serverConfig.atyrode.agentTools.enable
  "portable server must enable managed agent tools";
assert lib.assertMsg (lib.hasInfix "Bash(gh pr merge:*)"
  serverConfig.home.file.".local/share/atyrode/claude-settings.json".text
) "portable server must carry the Claude Code standing merge authorization";
assert lib.assertMsg (builtins.hasAttr ".claude/CLAUDE.md" serverConfig.home.file)
  "portable server must deploy the managed Claude Code operator policy";
assert lib.assertMsg (
  !(serverConfig.home.sessionVariables ? ATYRODE_HOST)
) "portable profiles must not invent a host identity";
assert lib.assertMsg (
  !(builtins.hasAttr "atyrode/host.json" serverConfig.xdg.configFile)
) "portable profiles must not invent a host registry entry";
assert lib.assertMsg (
  !(alternateServerConfig.home.sessionVariables ? ATYRODE_HOST)
) "portable profiles must remain identity-free for another user";
assert lib.assertMsg (
  !(builtins.hasAttr "atyrode/host.json" alternateServerConfig.xdg.configFile)
) "portable profiles must remain registry-free for another user";
assert lib.assertMsg (
  fixtureIdentity.id == externalFixture.hostId
) "NixOS consumer did not supply its own host identity";
assert lib.assertMsg (
  fixtureIdentity.username == "fixture"
) "NixOS consumer identity did not retain its fixture user";
assert lib.assertMsg externalConfig.config.programs.zsh.enable
  "NixOS consumer must own system Zsh enablement";
assert lib.assertMsg (
  lib.getName externalConfig.config.users.users.fixture.shell == "zsh"
) "NixOS consumer must own the account login shell";
assert lib.assertMsg (
  !(selectionSucceeds [ "server" ] system)
) "a portable composition without base unexpectedly validated";
assert lib.assertMsg (
  !(selectionSucceeds [
    "base"
    "server"
    "desktop"
  ] system)
) "server and desktop unexpectedly composed";
assert lib.assertMsg (
  !(selectionSucceeds [
    "base"
    "server"
    "development"
  ] system)
) "server and development unexpectedly composed";
assert lib.assertMsg (
  !(selectionSucceeds [
    "base"
    "server"
  ] "aarch64-darwin")
) "server unexpectedly composed on Darwin";
assert lib.assertMsg (
  !(selectionSucceeds [
    "base"
    "base"
  ] system)
) "duplicate capabilities unexpectedly validated";
assert lib.assertMsg (
  serverPolicy.productionFacts == [ ]
) "portable server policy must not contain production facts";
builtins.deepSeq evaluationPaths (
  pkgs.runCommand "check-portable-profiles-${system}"
    {
      nativeBuildInputs = [
        externalAtyrode
        pkgs.jq
      ];
    }
    ''
      atyrode capabilities show ${externalFixture.hostId} --json | jq -e '
        .host == "${externalFixture.hostId}"
        and (.capabilities | map(.name)) == ["agent-tools", "base", "server"]
        and all(.capabilities[]; .description | length > 0)
      ' >/dev/null

      jq -e '
        .schemaVersion == 1
        and .profile == "server"
        and .system == "${system}"
        and .productionFacts == []
        and (.packages | index("nixd") | not)
        and (.packages | index("docker") | not)
        and (.packages | index("clamav") | not)
        and (.closure.actualNarBytes <= .closure.maxNarBytes)
        and (.closure.actualStorePaths <= .closure.maxStorePaths)
        and (.topLevelPackageCount.actual == (.packages | length))
        and (.topLevelPackageCount.actual <= .topLevelPackageCount.max)
        and (has("username") | not)
        and (has("homeDirectory") | not)
        and (has("hostname") | not)
      ' ${serverProfileManifest}/manifest.json >/dev/null

      mkdir "$out"
    ''
)
