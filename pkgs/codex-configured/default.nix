{
  codex,
  lib,
  writeShellApplication,
}:

writeShellApplication {
  name = "codex";
  text = ''
    # Codex accepts --profile only on runtime commands (and `codex mcp`);
    # every other subcommand — notably `codex app-server`, which the Codex
    # desktop app bootstraps over SSH — hard-fails on the flag. Classify the
    # invocation by its first recognized subcommand token and inject the
    # managed profile only where it is valid. Both token lists mirror the
    # release pinned in pkgs/codex-bin; revisit them when bumping it.
    for argument in "$@"; do
      case "$argument" in
        --profile|-p|--profile=*)
          exec ${lib.getExe codex} "$@"
          ;;
      esac
    done
    for argument in "$@"; do
      case "$argument" in
        exec|e|review|resume|archive|delete|unarchive|fork|mcp|sandbox)
          break
          ;;
        login|logout|plugin|mcp-server|app-server|remote-control|completion|update|doctor|debug|apply|a|cloud|exec-server|features|help)
          exec ${lib.getExe codex} "$@"
          ;;
      esac
    done
    exec ${lib.getExe codex} --profile atyrode "$@"
  '';
  meta = codex.meta // {
    description = "Codex with the convergent atyrode configuration profile";
  };
}
