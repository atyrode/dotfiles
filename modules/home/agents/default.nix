{
  config,
  lib,
  pkgs,
  ...
}:

let
  # The one file every agent on this machine starts from: the operator policy
  # in modules/home/agents/AGENTS.md with a generated section describing this machine.
  # It is machine state, not store content -- it names what is authenticated
  # here right now -- so it is rendered into place by the CLI rather than
  # linked from the store, and the tool files below are out-of-store symlinks
  # to it so a re-render never has to touch them.
  generatedContext = "${config.xdg.configHome}/agents/AGENTS.md";
  contextLink = config.lib.file.mkOutOfStoreSymlink generatedContext;
in
{
  home.file = {
    ".claude/CLAUDE.md".source = contextLink;
    ".codex/AGENTS.md".source = contextLink;
    # OMP's native user context file; it shadows the two above in OMP sessions,
    # which is harmless because all three are the same bytes.
    ".omp/agent/AGENTS.md".source = contextLink;
  };

  # Rendered on every activation so the file always describes the machine
  # this generation produced. A render that fails must not fail the
  # activation: the machine is converged either way, and the doctor probe
  # reports the missing file with the command that writes it.
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
