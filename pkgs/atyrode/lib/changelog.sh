# shellcheck shell=bash
#
# Drift, told rather than acted on (ADR 0008, "The flow", step 5). An update is
# a prompt, never a background switch: what changes on this machine is the
# operator's to time, read and watch. So the machinery here is read-only -- an
# hourly look at main, a receipt, one line in every new shell until the update
# is taken, and `atyrode changelog` to read what it is before `atyrode apply`.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

changelog_receipt_file() {
  printf '%s/atyrode/update.json' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# The head of main, asked for directly. Offline answers nothing rather than
# something stale, and callers say so.
changelog_published_revision() {
  local git_command=git rev
  [[ "$test_hooks" != 1 || -z "${ATYRODE_GIT:-}" ]] || git_command="$ATYRODE_GIT"
  rev="$("$git_command" ls-remote "$flake_remote_url" refs/heads/main 2>/dev/null | head -n 1 | cut -f 1)" || true
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$rev"
}

# GitHub's REST view of the public repository, read anonymously: the fleet's
# repository is public by design, and two reads an hour per machine are far
# under the anonymous allowance. A failed read is an empty answer, and every
# caller treats an empty answer as "unknown", never as "nothing".
changelog_api() { # path
  local fetch
  fetch="$(optional_host_command ATYRODE_FETCH curl)" || return 1
  "$fetch" -fsSL --max-time 20 -H 'accept: application/vnd.github+json' \
    "https://api.github.com/repos/${flake_ref#github:}/$1" 2>/dev/null
}

# The commits main has that this machine does not, oldest first, as data. The
# compare endpoint also says when the running revision is no longer an
# ancestor of main -- a rewritten history -- which is worth a word to the
# operator because "N commits ahead" would then be a lie.
changelog_compare() { # running target
  local response
  response="$(changelog_api "compare/$1...$2")" || return 1
  jq -c '{
    status: .status,
    ahead: .ahead_by,
    commits: [.commits[] | {sha: .sha[0:12], subject: (.commit.message | split("\n")[0])}]
  }' <<<"$response" 2>/dev/null
}

# Whether CI has passed main's head: the `ci-gate` check-run is the one job
# that requires all three systems and every closure, and a green one is what
# publishes closures to the fleet cache. true, false, or null while it runs or
# when GitHub could not be asked.
changelog_green() { # target
  local response
  response="$(changelog_api "commits/$1/check-runs")" || {
    printf 'null\n'
    return 0
  }
  jq -c '[.check_runs[] | select(.name == "ci-gate")] | if length == 0 then null
    elif any(.[]; .conclusion == "success") then true
    elif all(.[]; .status == "completed") then false
    else null end' <<<"$response" 2>/dev/null || printf 'null\n'
}

# One JSON document describing where this machine stands against main. The
# same document is what `--record` writes for the shell to read, so the shell
# never computes anything itself.
changelog_document() {
  local running published compare green
  running="$embedded_revision"
  [[ "$running" =~ ^[0-9a-f]{40}$ ]] ||
    die "$EX_UNAVAILABLE" "this CLI is a development build and names no published revision to compare with main"
  published="$(changelog_published_revision)" ||
    die "$EX_UNAVAILABLE" "cannot reach $flake_remote_url to read main; check the network"
  if [[ "$published" == "$running" ]]; then
    jq -nc --arg running "$running" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{schemaVersion:1,command:"changelog",at:$at,outcome:"current",running:$running,target:$running,
        ahead:0,status:"identical",green:true,commits:[]}'
    return 0
  fi
  compare="$(changelog_compare "$running" "$published")" || compare='null'
  green="$(changelog_green "$published")"
  jq -nc --arg running "$running" --arg target "$published" --argjson compare "$compare" \
    --argjson green "$green" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schemaVersion:1,command:"changelog",at:$at,outcome:"available",running:$running,target:$target,
      ahead:($compare.ahead // null),status:($compare.status // "unknown"),green:$green,
      commits:($compare.commits // [])}'
}

changelog_render() { # document
  local document="$1"
  if [[ "$(jq -r '.outcome' <<<"$document")" == current ]]; then
    printf '%s\n' "this machine runs $(paint 36 "$(jq -r '.running[0:12]' <<<"$document")"), which is main"
    return 0
  fi
  local running target ahead rewritten="" line
  running="$(jq -r '.running[0:12]' <<<"$document")"
  target="$(jq -r '.target[0:12]' <<<"$document")"
  ahead="$(jq -r 'if .ahead == null then "an unknown number of" else (.ahead | tostring) end' <<<"$document")"
  [[ "$(jq -r '.status' <<<"$document")" != diverged ]] ||
    rewritten=" -- and history was rewritten under this machine"
  printf '%s\n' "this machine runs $(paint 36 "$running"); main is $(paint 36 "$target"), $ahead commit(s) ahead$rewritten"
  while IFS= read -r line; do
    printf '  %s\n' "$line"
  done < <(jq -r '.commits[] | "\(.sha)  \(.subject)"' <<<"$document")
  [[ "$(jq -r '.commits | length' <<<"$document")" != 0 ]] ||
    printf '  %s\n' "$(muted 'the commit list could not be read from GitHub')"
  case "$(jq -r '.green' <<<"$document")" in
    true) printf '%s\n' "CI: $(paint '1;32' 'green') -- closures published to the fleet cache" ;;
    false) printf '%s\n' "CI: $(paint '1;31' 'red') -- apply would build locally, and main is not fit to take" ;;
    *) printf '%s\n' "CI: $(paint '1;33' 'not finished') -- apply would build what the cache does not have yet" ;;
  esac
  printf '%s\n' "$(muted 'take it with: atyrode apply')"
}

# `atyrode changelog` reads; `--record` also leaves the document where every new
# shell finds it. The hourly timer runs the latter, an operator the former.
cmd_changelog() {
  local json=0 record=0 document file directory temporary
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;
      --record) record=1 ;;
      *) die "$EX_USAGE" "unknown changelog option: $1" ;;
    esac
    shift
  done
  document="$(changelog_document)"
  if [[ "$record" == 1 ]]; then
    file="$(changelog_receipt_file)"
    directory="$(dirname "$file")"
    mkdir -p "$directory"
    temporary="$(mktemp "$directory/.update.XXXXXX")"
    printf '%s\n' "$document" >"$temporary"
    mv -f "$temporary" "$file"
  fi
  if [[ "$json" == 1 ]]; then
    printf '%s\n' "$document"
  else
    changelog_render "$document"
  fi
}

# The doctor's view: which revision runs against which main has. Drift is a
# finding whose remedy is the same two commands the shell names.
probe_convergence() {
  local published
  if [[ ! "$embedded_revision" =~ ^[0-9a-f]{40}$ ]]; then
    provisioning_check_add convergence not-applicable development-build \
      "this CLI is a development build and names no published revision to compare" ""
    return 0
  fi
  if ! published="$(changelog_published_revision)"; then
    provisioning_check_add convergence degraded main-unreachable \
      "main is unreachable, so drift is unknown; this machine runs ${embedded_revision:0:12}" ""
    return 0
  fi
  if [[ "$published" == "$embedded_revision" ]]; then
    provisioning_check_add convergence ok "" \
      "this machine runs ${embedded_revision:0:12}, which is main" ""
    return 0
  fi
  provisioning_check_add convergence degraded behind \
    "main is ${published:0:12} and this machine runs ${embedded_revision:0:12}" \
    "atyrode changelog to read what changed, then atyrode apply"
}

# One muted line in every new interactive shell while an update is waiting,
# read from the receipt alone -- a prompt never waits on the network. It keeps
# nagging until the machine actually runs what the receipt names: a shell an
# agent opened and closed must not be the one that dismissed it. Silent once
# applied, even before the next hourly look refreshes the receipt.
changelog_shell_notice() {
  local receipt target ahead green count
  receipt="$(changelog_receipt_file)"
  [[ -f "$receipt" ]] || return 0
  [[ "$(jq -r '.outcome // empty' "$receipt" 2>/dev/null)" == available ]] || return 0
  target="$(jq -r '.target // empty' "$receipt" 2>/dev/null || true)"
  [[ -n "$target" && "$target" != "$embedded_revision" ]] || return 0
  ahead="$(jq -r '.ahead // empty' "$receipt" 2>/dev/null || true)"
  green="$(jq -r '.green' "$receipt" 2>/dev/null || true)"
  count="an update"
  [[ -z "$ahead" ]] || count="$ahead commit(s)"
  case "$green" in
    true) green='CI green' ;;
    false) green='CI red' ;;
    *) green='CI not finished' ;;
  esac
  printf '%s\n' "$(muted "atyrode: $count waiting on main (${target:0:12}, $green) -- read: atyrode changelog; take: atyrode apply")"
}
