{ lib, pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    nixfmt.enable = true;
    gofmt.enable = true;

    shfmt = {
      enable = true;
      indent_size = 2;
      simplify = false;
    };

    shellcheck.enable = true;
    deadnix.enable = true;
    statix.enable = true;

    # These treefmt modules are marked broken on Darwin. CI runs the
    # repository-wide gate on x86_64-linux, where both are supported.
    actionlint.enable = pkgs.stdenv.hostPlatform.isLinux;
    zizmor.enable = pkgs.stdenv.hostPlatform.isLinux;
  };

  # Apply semantic Nix rewrites before the canonical formatter. Running these
  # tools at separate priorities also prevents concurrent writes to one file.
  settings.formatter = {
    deadnix.priority = 1;
    statix.priority = 2;
    nixfmt.priority = 3;

    shfmt = {
      priority = 1;
      # The repository's existing two-space style indents case branches.
      options = lib.mkAfter [ "-ci" ];
    };
    shellcheck = {
      priority = 2;
      # The atyrode CLI is a first-class operational program without an .sh
      # extension; its `# shellcheck shell=bash` directive supplies the dialect
      # that its @shell@ substitution shebang cannot.
      includes = [ "pkgs/atyrode/atyrode" ];
    };
  };
}
