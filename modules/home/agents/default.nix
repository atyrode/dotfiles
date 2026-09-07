{
  config,
  lib,
  pkgs,
  ...
}:

let
  # The CLI renders static personal policy from modules/home/agents/AGENTS.md
  # with minimal generation provenance, not machine or authentication facts.
  # Keep its existing writable target and out-of-store tool adapters so an
  # atomic re-render does not require relinking them.
  generatedContext = "${config.xdg.configHome}/agents/AGENTS.md";
  contextLink = config.lib.file.mkOutOfStoreSymlink generatedContext;
in
{
  xdg.configFile."agents/templates/repo-AGENTS.md".source = ./templates/repo-AGENTS.md;

  home.file = {
    # Cross-tool adapters; their presence does not require using either tool.
    ".claude/CLAUDE.md".source = contextLink;
    ".codex/AGENTS.md".source = contextLink;
    # Native user context for OMP's default agent directory. Custom profiles
    # and discovery overrides may use different files.
    ".omp/agent/AGENTS.md".source = contextLink;
  };

  # Refresh policy and provenance on activation without probing machine/auth
  # state. Failure remains best-effort: the doctor probe reports missing or
  # mismatched policy and the command that writes it.
  home.activation.renderAgentContext =
    lib.hm.dag.entryAfter
      [
        "installPackages"
        "linkGeneration"
      ]
      ''
        if [[ -v DRY_RUN ]]; then
          echo "Would render the agent context to ${generatedContext} with atyrode context render"
        elif ! ${lib.getExe pkgs.atyrode} context render; then
          echo "warning: the agent context was not rendered; run atyrode context render" >&2
        fi
      '';
}
