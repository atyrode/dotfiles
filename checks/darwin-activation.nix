# nix-darwin shellchecks the composed activation script inside the derivation
# that builds the system, so a warning in our own postActivation shell is a
# build failure rather than an evaluation failure. Nothing in CI builds a
# Darwin system closure -- the darwin-evaluation check forces drvPath, which
# instantiates without building -- so that gate first fired on the Mac being
# bootstrapped, after it had already downloaded the world. Rendering the same
# script and running the same shellcheck costs one evaluation, needs no Darwin
# builder, and moves the failure back to `nix flake check`.
{
  darwinConfigs,
  lib,
  pkgs,
}:

let
  # The exclusions nix-darwin passes (modules/system/default.nix); linting
  # stricter than upstream would fail scripts the Mac accepts, which is the
  # same false signal in the other direction.
  exclusions = "SC2016,SC1112";

  lintHost =
    name: darwinConfig:
    let
      # The script names the Darwin bash that will run it and the Darwin
      # binaries it calls. Keeping the string context would make this lint
      # depend on building those, which no Linux runner can do -- and the
      # point is to read the text, not execute it.
      text = builtins.unsafeDiscardStringContext darwinConfig.config.system.activationScripts.script.text;
      rendered = pkgs.writeText "activate-${name}" text;
    in
    ''
      echo "linting the ${name} activation script" >&2
      # nix-darwin substitutes the system path in before it lints, so an
      # unsubstituted placeholder is not the text the Mac checks.
      substitute ${rendered} "$TMPDIR/activate-${name}" \
        --subst-var-by out /nix/store/00000000000000000000000000000000-darwin-system
      shellcheck --exclude=${exclusions} "$TMPDIR/activate-${name}"
    '';
in
pkgs.runCommand "check-darwin-activation"
  {
    nativeBuildInputs = [ pkgs.shellcheck ];
  }
  ''
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList lintHost darwinConfigs)}
    mkdir "$out"
  ''
