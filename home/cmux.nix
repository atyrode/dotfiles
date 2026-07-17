{ lib, pkgs, ... }:

lib.mkIf pkgs.stdenv.isDarwin {
  # cmux (the macOS terminal, installed by darwin/casks.nix from the pinned
  # manaflow-ai tap) reads ~/.config/cmux/cmux.json. Nix owns this file the
  # same way it owns Claude's settings.json: durable operator policy lives in
  # the store, mutable app state stays outside it. Known trade-off: the app's
  # own "Save Workspace as Layout" flow writes to this path and will fail on
  # the read-only link — layouts are edited here instead.
  #
  # Schema verified against the pinned app release (cask 0.64.17,
  # Sources/CmuxConfig.swift + CmuxWorkspaceDefinition.swift at v0.64.17):
  # `newWorkspaceCommand` must name a `commands[]` entry that defines a
  # `workspace`; layouts accept a bare pane root; workspace definitions have
  # no native-ssh field, and `cmux ssh` can neither run a command nor reuse
  # the invoking tab. Plain ssh in the surface command is therefore the only
  # expressible "plus button opens code on tyrode.dev". The cost: plus-button
  # tabs have no cmuxd session persistence — a dropped connection ends that
  # tab's session (omp sessions stay resumable on the host). Long-lived agent
  # runs belong in native cmux-ssh tabs; the second palette command below
  # spawns those from any already-connected tyrode.dev tab.
  xdg.configFile."cmux/cmux.json".text = builtins.toJSON {
    newWorkspaceCommand = "code @ tyrode.dev";
    commands = [
      {
        name = "code @ tyrode.dev";
        description = "New tab: ssh to tyrode.dev and launch the code profile generator";
        keywords = [
          "code"
          "ssh"
          "tyrode"
        ];
        workspace = {
          name = "code";
          layout = {
            pane.surfaces = [
              {
                type = "terminal";
                name = "code";
                # Interactive login zsh on the remote so the nix-profile PATH
                # is loaded before `code` resolves; quitting code drops to a
                # remote shell instead of a dead tab.
                command = "ssh -t alex@tyrode.dev 'zsh -ilc \"code; exec zsh -il\"'";
                focus = true;
              }
            ];
          };
        };
      }
      {
        name = "code @ tyrode.dev (native tab)";
        description = "Run from a tyrode.dev tab: native cmux-ssh workspace already running code (survives sleeps and drops)";
        keywords = [
          "code"
          "native"
          "workspace"
        ];
        command = "cmux new-workspace --name code --command code";
      }
    ];
  };
}
