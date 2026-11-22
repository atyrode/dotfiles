# The push wrapper of the session archive, as a function so the Home Manager
# units (modules/shared/omp-session-archive.nix) and the check that executes it
# build the very same script.
{
  lib,
  pkgs,
  machine,
}:
# What is archived: the OMP session logs and their blobs, Claude Code's
# per-project transcripts, and Codex's dated rollouts with the two
# host-level history files beside them. Only what exists is named,
# because restic refuses a backup with a missing source. Auth files,
# databases and caches under the same homes are deliberately not
# archived.
#
# An unconfigured machine (no placed environment file) is a no-op and
# exits 0 with a note, never an hourly unit failure. The repository is
# never created here, and never pruned. restic's exit status is the
# script's: a failed or incomplete snapshot is loud and records no
# success stamp, which `atyrode doctor` reads for freshness.
pkgs.writeShellApplication {
  name = "omp-session-archive-push";
  runtimeInputs = [
    pkgs.restic
    pkgs.coreutils
  ];
  text = ''
    env_file="''${XDG_CONFIG_HOME:-$HOME/.config}/omp-session-archive/restic.env"
    state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/omp-session-archive"

    if [[ ! -f "$env_file" ]]; then
      echo "omp-session-archive-push: not configured; run 'atyrode apply' to set this machine up" >&2
      exit 0
    fi

    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a

    roots=()
    for root in \
      "$HOME/.omp/agent/sessions" \
      "$HOME/.omp/agent/blobs" \
      "$HOME/.claude/projects" \
      "$HOME/.codex/sessions" \
      "$HOME/.codex/history.jsonl" \
      "$HOME/.codex/session_index.jsonl"; do
      if [[ -e "$root" ]]; then
        roots+=("$root")
      fi
    done

    if (( ''${#roots[@]} == 0 )); then
      echo "omp-session-archive-push: no session history on this host; nothing to archive" >&2
      exit 0
    fi

    restic backup --host ${lib.escapeShellArg machine} --tag omp-sessions --exclude-caches "''${roots[@]}"

    umask 077
    mkdir -p "$state_dir"
    stamp_tmp="$(mktemp "$state_dir/.last-success.XXXXXX")"
    date -u +%FT%TZ >"$stamp_tmp"
    mv -f "$stamp_tmp" "$state_dir/last-success"
  '';
  meta.description = "Hourly restic archive push of this machine's agent session history";
}
