{ config, ... }:

let
  orcaHookCommand = "if [ -f '${config.home.homeDirectory}/.orca/agent-hooks/claude-hook.sh' ] && [ -r '${config.home.homeDirectory}/.orca/agent-hooks/claude-hook.sh' ] && [ -x '${config.home.homeDirectory}/.orca/agent-hooks/claude-hook.sh' ]; then /bin/sh '${config.home.homeDirectory}/.orca/agent-hooks/claude-hook.sh'; else cat >/dev/null 2>&1 || :; fi";
  orcaHook = {
    hooks = [
      {
        type = "command";
        command = orcaHookCommand;
        timeout = 10;
      }
    ];
  };
  matchedOrcaHook = orcaHook // {
    matcher = "*";
  };
in
{
  # Nix owns Claude Code's durable operator policy: the standing-authorization
  # instructions loaded by every session and the user-scope permission rules.
  # Sessions keep their mutable state (projects, memory, credentials, and
  # machine-local project settings) outside the store, mirroring the OMP and
  # Codex ownership split.
  home.file.".claude/CLAUDE.md".source = ./claude/CLAUDE.md;

  # Orca installs these hooks when its runtime starts. Declare the pinned
  # contract here instead: settings.json is intentionally Nix-owned, and an
  # application-written replacement would otherwise block the next activation.
  home.file.".claude/settings.json" = {
    force = true;
    text = builtins.toJSON {
      permissions.allow = [ "Bash(gh pr merge:*)" ];
      hooks = {
        UserPromptSubmit = [ orcaHook ];
        Stop = [ orcaHook ];
        StopFailure = [ orcaHook ];
        SubagentStart = [ orcaHook ];
        SubagentStop = [ orcaHook ];
        TeammateIdle = [ orcaHook ];
        PreToolUse = [ matchedOrcaHook ];
        PostToolUse = [ matchedOrcaHook ];
        PostToolUseFailure = [ matchedOrcaHook ];
        PermissionRequest = [ matchedOrcaHook ];
      };
    };
  };
}
