_:

{
  # Nix owns Claude Code's durable operator policy: the standing-authorization
  # instructions loaded by every session and the user-scope permission rules.
  # Sessions keep their mutable state (projects, memory, credentials, and
  # machine-local project settings) outside the store, mirroring the OMP and
  # Codex ownership split.
  home.file.".claude/CLAUDE.md".source = ./claude/CLAUDE.md;

  home.file.".claude/settings.json".text = builtins.toJSON {
    permissions.allow = [ "Bash(gh pr merge:*)" ];
  };
}
