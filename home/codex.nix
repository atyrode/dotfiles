{ lib, pkgs, ... }:

{
  # Converge only the portable profile layer and global guidance. codex-use
  # deliberately leaves config.toml, authentication, sessions, history,
  # plugins, and caches as mutable profile-owned state.
  home.activation.convergeCodexPortableConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${lib.getExe pkgs.codex-use} converge
  '';
}
