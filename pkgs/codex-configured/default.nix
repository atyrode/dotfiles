{
  codex,
  lib,
  writeShellApplication,
}:

writeShellApplication {
  name = "codex";
  text = ''
    for argument in "$@"; do
      case "$argument" in
        --profile|-p|--profile=*)
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
