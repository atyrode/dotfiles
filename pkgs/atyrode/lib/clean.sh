# shellcheck shell=bash
#
# Generations, garbage collection, and the residue dropped packages leave.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# On macOS, home-manager links GUI apps into ~/Applications/Home Manager Apps as
# symlinks into the store. When a package is dropped it sometimes leaves the link
# behind pointing at a garbage-collected target (a broken symlink) — the stale
# "Visual Studio Code.app" kind of leftover. Removing a link is safe and
# reversible (the next apply recreates the valid ones); app *data* is app-owned
# and Nix never managed it, so we only point at it.
clean_macos_residue() {
  local dry="$1" assume_yes="$2"
  local hm_apps="$HOME/Applications/Home Manager Apps"
  [[ -d "$hm_apps" ]] || return 0
  local -a stale=()
  local f
  while IFS= read -r f; do
    [[ -e "$f" ]] || stale+=("$f") # a link whose store target is gone
  done < <(find "$hm_apps" -mindepth 1 -maxdepth 1 -type l)
  if [[ "${#stale[@]}" -eq 0 ]]; then
    printf 'atyrode: no stale Home Manager Apps aliases.\n' >&2
  else
    printf 'atyrode: %s stale app alias(es) left by removed packages:\n' "${#stale[@]}" >&2
    for f in "${stale[@]}"; do printf '  %s\n' "$(basename "$f")" >&2; done
    for f in "${stale[@]}"; do
      [[ -L "$f" && "$f" == "$hm_apps/"* ]] || continue # never touch anything but a link under this dir
      if [[ "$dry" == 1 ]]; then
        printf '  would remove: %s\n' "$(basename "$f")" >&2
      elif [[ "$assume_yes" == 1 ]] || confirm "remove stale alias $(basename "$f")?"; then
        rm -f "$f" && printf '  removed %s\n' "$(basename "$f")" >&2
      fi
    done
  fi
  printf 'atyrode: note — app data (e.g. ~/Library/Application Support/<App>) is\n' >&2
  printf '  app-owned, not Nix-managed, so a dropped app leaves it behind; remove by hand.\n' >&2
}

# collect_garbage runs the store GC that `nh clean --no-gc` deliberately skips.
# nh runs it silently, so the last step of a clean looks frozen for however long
# the daemon takes (often minutes). Here we own that phase: a spinner on a
# terminal shows it is alive, and non-interactively the collector's native output
# streams through. In test builds it is a no-op unless ATYRODE_NIX_STORE provides
# a stand-in, so the suite never touches the real store.
collect_garbage() {
  local -a gc=(nix-store --gc)
  if [[ "$test_hooks" == 1 ]]; then
    [[ -n "${ATYRODE_NIX_STORE:-}" ]] || return 0
    gc=("$ATYRODE_NIX_STORE" --gc)
  fi

  # Announced once for both paths below: the spinner carries no command text and
  # the collector's own output names nothing, so nothing else on screen says what
  # is deleting store paths.
  show_command "${gc[@]}"

  if ! stderr_is_tty; then # non-interactive: stream the collector's own output
    printf 'atyrode: collecting garbage…\n' >&2
    "${gc[@]}" >&2 || printf 'atyrode: garbage collection reported an error\n' >&2
    return 0
  fi

  local out pid rc=0 i=0 deleted=0 frame=""
  local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  out="$(mktemp)"
  "${gc[@]}" >"$out" 2>&1 &
  pid=$!
  # nix-store --gc first scans the whole store for unreachable paths (the deleted
  # count sits at 0 for a while) and only then removes them. Reflect both phases on
  # a single \r-rewritten line so the long opaque middle shows real motion. The
  # line is kept short and carries no store path on purpose: a line that wraps past
  # the terminal width defeats the carriage-return redraw and stacks up stale
  # copies instead of updating in place (and "0 paths freed" mid-scan reads as
  # stuck, so that phase says "scanning" instead).
  while kill -0 "$pid" 2>/dev/null; do
    # grep -c already prints "0" on no match (and exits 1); `|| true` keeps that
    # single "0" instead of appending a second one — a "0\n0" value embeds a
    # newline that splits the progress line and breaks the \r redraw.
    deleted="$(grep -c "^deleting '" "$out" 2>/dev/null || true)"
    # Advance the spinner in the parent shell: doing i++ inside the $(paint …)
    # command substitution would increment a throwaway subshell copy, freezing the
    # frame (SC2030/SC2031).
    frame="${frames[$((i++ % ${#frames[@]}))]}"
    if [[ "${deleted:-0}" -eq 0 ]]; then
      printf '\r\033[K  %s %s' "$(paint 36 "$frame")" \
        "$(paint 2 'collecting garbage — scanning the store…')" >&2
    else
      printf '\r\033[K  %s collecting garbage — %s paths freed' \
        "$(paint 36 "$frame")" "$(paint '1' "$deleted")" >&2
    fi
    sleep 0.12
  done
  wait "$pid" || rc=$?
  printf '\r\033[K' >&2
  if [[ "$rc" == 0 ]]; then
    # Expose the reclaimed size (e.g. "210.5 MiB") to the clean footer; empty if
    # the collector reported no figure. _gc_freed is a global by design.
    _gc_freed="$(grep -oiE '[0-9.]+ [kmgtp]?i?b freed' "$out" | tail -n1 || true)"
    _gc_freed="${_gc_freed% freed}"
    printf 'atyrode: %s %s\n' "$(paint '1;32' '✓')" \
      "$(grep -iE 'freed|deleted' "$out" | tail -n1 || echo 'store collected')" >&2
  else
    cat "$out" >&2
    printf 'atyrode: %s\n' "$(paint '1;31' 'garbage collection failed')" >&2
  fi
  rm -f "$out"
}

# fold_nh_clean_noise tames `nh clean`'s output down to what matters. nh 4.4.1
# prints a full evaluation plan on every run — a legend plus one "- OK/RE/DEL"
# line per GC root (well over 100 lines) — and one "> Removing …/gcroots/auto/…"
# plus paired "! Failed … PermissionDenied" per daemon-owned root a user-scope
# clean cannot unlink. atyrode already reports the outcome in its own footer, so
# by default we drop the plan and the auto-gcroot chatter, keeping only genuine
# (non-permission) errors and anything unexpected. Two tallies are written to the
# file named by the first argument: skipped (permission failures) and reaped
# (auto-root removals that succeeded = removals − failures; counted by totals, as
# nh emits the removals and failures in separate batches, not adjacent pairs). The
# second argument, when 1 (--verbose), passes nh's full output through untouched
# while still counting. ANSI colour is stripped only for matching; kept lines
# print with their original colouring.
fold_nh_clean_noise() {
  local count_file="${1:-/dev/null}" verbose="${2:-0}"
  awk -v countfile="$count_file" -v verbose="$verbose" '
    { s = $0; gsub(/\033\[[0-9;]*m/, "", s) }
    s ~ /^> Removing .*\/gcroots\/auto\// { removing++; if (!verbose) next }
    s ~ /Failed to remove path.*\/gcroots\/auto\/.*PermissionDenied/ { failed++; if (!verbose) next }
    !verbose && s ~ /^(Welcome to nh clean|Keeping |legend:|RE:|OK:|DEL:)/ { next }
    !verbose && s ~ /^(orphaned gcroots|gcroots)$/ { next }
    !verbose && s ~ /^- (OK|RE|DEL)/ { next }
    !verbose && s ~ /\/nix\/profiles\/[A-Za-z0-9._-]+$/ { next }
    !verbose && s ~ /Profiles directory not found/ { next }
    !verbose && s ~ /^[[:space:]]*$/ { next }
    { print }
    END {
      reaped = removing - failed; if (reaped < 0) reaped = 0
      printf "%d %d\n", failed + 0, reaped + 0 > countfile
    }
  '
}

# warn_stray_result_roots flags `result*` symlinks left by `nix build` without
# --no-link: each is an indirect GC root pinning a whole closure, so they quietly
# defeat a clean. We look only in the current directory and the enclosing git
# worktree (cheap, and where they accumulate during development) and never touch
# them — removing a build result is the developer's call, not clean's.
warn_stray_result_roots() {
  local git_command=git
  [[ "$test_hooks" != 1 || -z "${ATYRODE_GIT:-}" ]] || git_command="$ATYRODE_GIT"
  local -a scan=("$PWD") roots=()
  local base top f
  top="$("$git_command" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" && "$top" != "$PWD" ]] && scan+=("$top")
  for base in "${scan[@]}"; do
    while IFS= read -r f; do
      [[ "$(readlink "$f" 2>/dev/null)" == /nix/store/* ]] && roots+=("$f")
    done < <(find "$base" -maxdepth 1 -type l \( -name result -o -name 'result-*' \) 2>/dev/null)
  done
  [[ "${#roots[@]}" -gt 0 ]] || return 0
  printf 'atyrode: %s %s stray result symlink(s) still pin closures (nix build without --no-link):\n' \
    "$(paint 33 '⚠')" "${#roots[@]}" >&2
  for f in "${roots[@]}"; do printf '  %s %s %s\n' "$(paint 1 "$f")" "$(paint 2 '->')" "$(paint 2 "$(readlink "$f")")" >&2; done
  printf '  %s\n' "$(paint 2 'remove them (rm result*) so the store can reclaim those closures.')" >&2
}

# count_generations reports how many generations the tracked profile has (0 when
# it cannot be read) so the clean footer can show kept/removed counts.
count_generations() {
  local profile
  profile="$(gen_profile)"
  [[ -e "$profile" ]] || {
    printf 0
    return
  }
  nix_env -p "$profile" --list-generations 2>/dev/null | grep -c . || true
}

# clean_footer resolves the wall of nh/gc output into one human-readable result
# line: what was reclaimed, kept, and removed, plus the fate of the daemon-owned
# auto GC roots — reaped when the clean ran with enough privilege, otherwise
# skipped with the exact command to reap them (atyrode never self-elevates, so a
# non-root clean cannot unlink root-owned roots; see #148).
clean_footer() {
  local dry="$1" before="$2" after="$3" skipped="$4" freed="$5" reaped="${6:-0}" euid="${7:-1000}"
  local removed=0
  [[ "$before" -gt "$after" ]] && removed=$((before - after))
  # Colour by meaning so the outcome scans at a glance: reclaimed/reaped green,
  # skipped amber with the reap command in cyan, everything neutral. Each segment
  # is painted whole (never mid-phrase), so with colour off the plain text is
  # byte-for-byte what a pipe or the check harness reads.
  local -a parts=()
  if [[ "$dry" == 1 ]]; then
    parts+=("$(paint 33 'dry-run — no changes made')" "$before generation(s) present")
  else
    [[ -z "$freed" ]] || parts+=("$(paint '1;32' "reclaimed $freed")")
    parts+=("kept $after generation(s)" "removed $removed generation(s)")
  fi
  [[ "${reaped:-0}" -gt 0 ]] && parts+=("$(paint 32 "reaped $reaped root-owned GC root(s)")")
  if [[ "${skipped:-0}" -gt 0 ]]; then
    if [[ "$euid" == 0 ]]; then
      parts+=("$(paint 33 "skipped $skipped root-owned GC root(s) (unremovable)")")
    else
      # Name an absolute nix-store path: under elevation a bare command is not on
      # root's secure_path (see nix_store_path). `nix-store --gc` prunes these
      # daemon-owned roots once this clean has dropped the generations they pin.
      parts+=("$(paint 33 "skipped $skipped root-owned GC root(s)"); reap them via \`$(paint '1;36' "sudo $(nix_store_path) --gc")\`")
    fi
  fi
  local out="" p sep
  sep="$(paint 2 '·')"
  for p in "${parts[@]}"; do
    [[ -z "$out" ]] && out="$p" || out="$out $sep $p"
  done
  printf 'atyrode: %s\n' "$out" >&2
}

# keepsince_cutoff resolves --keep-since (nh's compact form: 30d, 1h, 4w, 45m, …)
# to an epoch-second cutoff; anything newer is always kept. Prints nothing when the
# duration can't be parsed, so callers fall back to a keep-only estimate.
keepsince_cutoff() {
  local dur="$1" num
  [[ "$dur" =~ ^([0-9]+)[[:space:]]*([A-Za-z]+)$ ]] || return 0
  num="${BASH_REMATCH[1]}"
  local unit
  case "${BASH_REMATCH[2]}" in
    s | sec | secs | second | seconds) unit=seconds ;;
    m | min | mins | minute | minutes) unit=minutes ;;
    h | hr | hrs | hour | hours) unit=hours ;;
    d | day | days) unit=days ;;
    w | week | weeks) unit=weeks ;;
    *) return 0 ;;
  esac
  date -d "$num $unit ago" +%s 2>/dev/null || true
}

# clean_preview describes what a clean is about to do — its keep window, exactly
# how many generations fall outside it (honouring BOTH --keep and --keep-since, so
# it never over-promises a removal that keep-since will spare), and that the
# current generation and rollback window are never touched — so an accidental
# `atyrode clean` can be read and declined before anything is removed. Store
# reclaim is not estimated: closure sizes overlap heavily, so the honest figure is
# the one the GC reports afterwards.
clean_preview() {
  local scope="$1" keep="$2" keep_since="$3"
  local profile
  profile="$(gen_profile)"
  local -a gens=() dates=()
  local line gen d t rest current="" total=0 removable=0 i rank
  if [[ -e "$profile" ]]; then
    while IFS= read -r line; do
      read -r gen d t rest <<<"$line"
      gens+=("$gen")
      dates+=("$d $t")
      [[ "$line" == *"(current)"* ]] && current="$gen"
    done < <(nix_env -p "$profile" --list-generations 2>/dev/null)
  fi
  total=${#gens[@]}
  local cutoff
  cutoff="$(keepsince_cutoff "$keep_since")"
  for ((i = 0; i < total; i++)); do
    rank=$((total - 1 - i))
    [[ "$rank" -ge "$keep" && "${gens[$i]}" != "$current" ]] || continue
    if [[ -n "$cutoff" ]]; then
      # Removable only if also older than the keep-since window.
      local ge
      ge="$(date -d "${dates[$i]}" +%s 2>/dev/null || echo 0)"
      [[ "$ge" -gt 0 && "$ge" -lt "$cutoff" ]] && removable=$((removable + 1))
    else
      removable=$((removable + 1)) # duration unparseable → keep-only upper bound
    fi
  done
  local bullet
  bullet="$(paint 36 '•')"
  printf 'atyrode: %s\n' "$(paint 1 "clean ($scope) is about to:")" >&2
  printf '  %s keep the newest %s generation(s), anything newer than %s, and the current one\n' \
    "$bullet" "$(paint 1 "$keep")" "$(paint 1 "$keep_since")" >&2
  printf '  %s remove %s of %s generation(s) that fall outside that window\n' \
    "$bullet" "$(paint 33 "$removable")" "$(paint 1 "$total")" >&2
  printf '  %s garbage-collect unreferenced store paths %s\n' \
    "$bullet" "$(paint 2 '(reclaimed space reported after)')" >&2
}

# clean — reclaim disk from generations the config no longer references, always
# keeping the current generation and a rollback window (never an auto-wipe of the
# safety net). Also sweeps stale macOS app aliases (see clean_macos_residue).
cmd_clean() {
  local dry=0 keep=5 keep_since=30d scope=user assume_yes=0 json=0 verbose=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n | --dry-run) dry=1 ;;
      --keep)
        shift
        keep="${1:-}"
        ;;
      --keep-since)
        shift
        keep_since="${1:-}"
        ;;
      --all) scope=all ;; # also the system profile (nix-darwin); needs elevation
      -y | --yes) assume_yes=1 ;;
      -v | --verbose) verbose=1 ;; # pass nh clean's full evaluation plan through
      --json) json=1 ;;            # machine-readable reclaim summary on stdout (cockpit)
      *) die "$EX_USAGE" "unknown clean option: $1" ;;
    esac
    shift || true
  done
  [[ "$keep" =~ ^[0-9]+$ ]] || die "$EX_USAGE" "--keep expects a number"
  command -v nh >/dev/null || die "$EX_UNAVAILABLE" "nh is unavailable"
  local nh_command=nh
  [[ "$test_hooks" != 1 || -z "${ATYRODE_NH:-}" ]] || nh_command="$ATYRODE_NH"

  # Guard an accidental interactive run: show the plan and require confirmation.
  # --dry-run previews without touching anything, --yes/--json are the explicit
  # non-interactive paths (scripts, cockpit), so none of them prompt.
  if [[ "$dry" == 0 && "$assume_yes" == 0 && "$json" == 0 ]] && interactive; then
    clean_preview "$scope" "$keep" "$keep_since"
    confirm "proceed and reclaim now?" ||
      {
        printf 'atyrode: %s\n' "$(paint 33 'clean declined — nothing changed.')" >&2
        return 0
      }
  fi

  printf 'atyrode: %s (keeping %s generation(s) + everything newer than %s)\n' \
    "$(paint 1 'reclaiming the Nix store')" "$(paint 36 "$keep")" "$(paint 36 "$keep_since")" >&2
  # Let nh remove the stale generations and gcroots, but skip its garbage
  # collection (--no-gc) — nh runs it silently. We collect below instead, with a
  # progress indicator, so the slow final step isn't an unexplained freeze. nh's
  # own chatter (its plan and the folded gcroots summary) goes to stderr so that
  # under --json stdout carries only the machine-readable summary; pipefail
  # propagates nh's exit status through the filter. --verbose passes nh's full
  # evaluation plan through instead of folding it.
  local gens_before
  gens_before="$(count_generations)"
  local nh_args=("$nh_command" clean "$scope" --keep "$keep" --keep-since "$keep_since" --no-gc)
  [[ "$dry" == 0 ]] || nh_args+=(--dry)
  local skipped_file
  skipped_file="$(mktemp)"
  # fold_nh_clean_noise drops nh's own plan, so without this the removal of
  # generations and gcroots scrolls past with nothing naming the command that
  # did it.
  show_command "${nh_args[@]}"
  "${nh_args[@]}" 2>&1 | fold_nh_clean_noise "$skipped_file" "$verbose" >&2 || die "$EX_SOFTWARE" "nh clean failed"
  # fold_nh_clean_noise writes "<skipped> <reaped>"; default both to 0 if unread.
  local skipped=0 reaped=0
  read -r skipped reaped <"$skipped_file" 2>/dev/null || true
  skipped="${skipped:-0}"
  reaped="${reaped:-0}"
  rm -f "$skipped_file"

  _gc_freed=""
  [[ "$dry" == 1 ]] || collect_garbage

  if [[ "$(uname -s)" == Darwin ]]; then
    clean_macos_residue "$dry" "$assume_yes"
  fi

  local gens_after
  gens_after="$(count_generations)"
  clean_footer "$dry" "$gens_before" "$gens_after" "$skipped" "$_gc_freed" "$reaped" "$(effective_uid)"
  warn_stray_result_roots || true

  [[ "$json" == 0 ]] || clean_summary_json "$scope" "$keep" "$keep_since" "$dry"
}

# clean_summary_json prints a machine-readable reclaim summary for the cockpit:
# the parameters and the generations that are reclaim CANDIDATES — every
# generation beyond the newest <keep>, excluding the current one (nh additionally
# keeps any newer than --keep-since, so this is an upper bound on what it prunes).
# closureSize per candidate is the generation's own closure; those overlap
# heavily, so the real freed space is what the store GC reports, not their sum —
# hence the note. A store read, so sizes only when nix-env resolves them.
clean_summary_json() {
  local scope="$1" keep="$2" keep_since="$3" dry="$4"
  local profile
  profile="$(gen_profile)"
  local gens=() line gen rest current="" total=0
  if [[ -e "$profile" ]]; then
    while IFS= read -r line; do
      read -r gen rest <<<"$line"
      gens+=("$gen")
      [[ "$line" == *"(current)"* ]] && current="$gen"
    done < <(nix_env -p "$profile" --list-generations 2>/dev/null)
  fi
  total=${#gens[@]}
  # Candidates: those whose rank from the newest is >= keep and not current.
  local candidates='[]' i rank g size date
  for ((i = 0; i < total; i++)); do
    g="${gens[$i]}"
    rank=$((total - 1 - i))
    [[ "$rank" -ge "$keep" && "$g" != "$current" ]] || continue
    date="$(nix_env -p "$profile" --list-generations 2>/dev/null | awk -v n="$g" '$1==n{print $2" "$3}')"
    size="$(gen_size "$profile" "$g")"
    candidates="$(jq -c --argjson c "$candidates" --argjson gen "$g" --arg date "$date" --arg size "$size" \
      '$c + [({generation:$gen,date:$date} + (if $size=="" then {} else {closureSize:$size} end))]' <<<'null')"
  done
  jq -nc \
    --arg scope "$scope" --argjson keep "$keep" --arg keepSince "$keep_since" \
    --argjson dry "$([[ "$dry" == 1 ]] && echo true || echo false)" \
    --arg platform "$(gen_platform)" --arg profile "$profile" \
    --argjson total "$total" --argjson candidates "$candidates" \
    '{scope:$scope,platform:$platform,profile:$profile,keep:$keep,keepSince:$keepSince,dryRun:$dry,
      generations:{total:$total,candidates:($candidates|length)},
      reclaimCandidates:$candidates,
      note:"candidates are generations beyond the newest keep, excluding current; nh additionally keeps any newer than keepSince. closureSize values overlap — actual freed space is what the store GC reports."}'
}

# The activation profile whose generations `apply` switches. NixOS-WSL and
# nix-darwin own system profiles; standalone Linux owns Home Manager's profile.
gen_platform() {
  if [[ "$(uname -s)" == Darwin ]]; then
    printf 'nix-darwin'
  elif is_wsl; then
    printf 'nixos'
  else
    printf 'home-manager'
  fi
}

gen_profile() {
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_GEN_PROFILE:-}" ]]; then
    printf '%s' "$ATYRODE_GEN_PROFILE" # pin the profile path in tests (platform-agnostic)
    return
  fi
  case "$(gen_platform)" in
    nix-darwin | nixos) printf '/nix/var/nix/profiles/system' ;;
    home-manager) printf '%s/nix/profiles/home-manager' "${XDG_STATE_HOME:-$HOME/.local/state}" ;;
  esac
}

# Human closure size of a profile generation's store path, or empty when it
# can't be resolved. A store query, so it stays behind --sizes (not the default).
gen_size() {
  local p
  [[ -e "$1-$2-link" ]] || return 0 # no such generation link → no size (not an error)
  p="$(readlink -f "$1-$2-link" 2>/dev/null)" || return 0
  [[ -n "$p" ]] || return 0
  # Best-effort: a failed store query yields an empty size, never an abort (the
  # caller runs under `set -e`).
  nix path-info -Sh "$p" 2>/dev/null | awk -F'\t' 'NR==1 { s = $2; gsub(/^ +| +$/, "", s); print s }' || return 0
}

# generations — list the activation profile's generations (read-only). nh only
# exposes this for NixOS, so we read the profile natively (a tested gap per #21).
cmd_generations() {
  local json=0 sizes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;
      --sizes) sizes=1 ;; # closure size per generation (a store query, slower)
      *) die "$EX_USAGE" "unknown generations option: $1" ;;
    esac
    shift
  done
  command -v nix-env >/dev/null || die "$EX_UNAVAILABLE" "nix-env is unavailable"
  local profile
  profile="$(gen_profile)"
  [[ -e "$profile" ]] || die "$EX_NOINPUT" "no $(gen_platform) generations profile at $profile"

  local line gen d t rest cur size
  if [[ "$json" == 1 ]]; then
    local first=1
    printf '['
    while IFS= read -r line; do
      read -r gen d t rest <<<"$line"
      cur=false
      [[ "$line" == *"(current)"* ]] && cur=true
      [[ "$first" == 1 ]] || printf ','
      first=0
      printf '{"generation":%d,"date":"%s %s","current":%s' "$gen" "$d" "$t" "$cur"
      if [[ "$sizes" == 1 ]]; then
        size="$(gen_size "$profile" "$gen")"
        [[ -n "$size" ]] && printf ',"closureSize":"%s"' "$size"
      fi
      printf '}'
    done < <(nix_env -p "$profile" --list-generations 2>/dev/null)
    printf ']\n'
  else
    printf 'atyrode: %s generations (%s)\n' "$(gen_platform)" "$profile" >&2
    while IFS= read -r line; do
      if [[ "$sizes" == 1 ]]; then
        read -r gen _ <<<"$line"
        size="$(gen_size "$profile" "$gen")"
        printf '%s%s\n' "$line" "${size:+   [${size}]}"
      else
        printf '%s\n' "$line"
      fi
    done < <(nix_env -p "$profile" --list-generations 2>/dev/null)
  fi
}

# rollback — activate an earlier generation (previous by default, or --to N).
# A mutation, so it confirms first and --dry-run only previews; roll-forward is
# always possible, and it refuses to "roll back" to the current generation.
# An earlier generation is a candidate like any other: what its activation
# does to services is analysed against the generation running now and refused
# on the same terms as apply, because the agent that owns every terminal does
# not care which direction the generation that stops it came from.
cmd_rollback() {
  local to="" dry=0 assume_yes=0 expected_disruption="" requested=""
  local -a scopes=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        shift
        to="${1:-}"
        ;;
      --expected-disruption)
        shift
        expected_disruption="${1:-}"
        [[ "$expected_disruption" =~ ^[0-9a-f]{64}$ ]] ||
          die "$EX_USAGE" "--expected-disruption expects the 64-hex fingerprint printed by rollback --dry-run"
        ;;
      --scope)
        shift
        [[ -n "${1:-}" ]] || die "$EX_USAGE" "--scope requires scope:service"
        validate_scope "$1"
        scopes+=("$1")
        ;;
      -n | --dry-run) dry=1 ;;
      -y | --yes) assume_yes=1 ;;
      --*) die "$EX_USAGE" "unknown rollback option: $1" ;;
      *)
        [[ -z "$requested" ]] || die "$EX_USAGE" "rollback accepts at most one host"
        requested="$1"
        ;;
    esac
    shift || true
  done
  command -v nix-env >/dev/null || die "$EX_UNAVAILABLE" "nix-env is unavailable"
  local profile platform activation
  profile="$(gen_profile)"
  platform="$(gen_platform)"
  [[ -e "$profile" ]] || die "$EX_NOINPUT" "no $platform generations profile at $profile"
  case "$platform" in
    nix-darwin) activation=nix-darwin ;;
    nixos) activation=nixos ;;
    *) activation=home-manager ;;
  esac

  local listing current target
  # A failed read must not exit 1 with no diagnostic under `set -e`; the
  # refusals below are the useful output, so surface an unreadable profile.
  listing="$(nix_env -p "$profile" --list-generations 2>/dev/null)" ||
    die "$EX_UNAVAILABLE" "cannot read the $platform generations profile at $profile"
  current="$(awk '/\(current\)/{print $1}' <<<"$listing")"
  [[ -n "$current" ]] || die "$EX_SOFTWARE" "cannot determine the current generation"
  if [[ -n "$to" ]]; then
    [[ "$to" =~ ^[0-9]+$ ]] || die "$EX_USAGE" "--to expects a generation number"
    target="$to"
    awk '{print $1}' <<<"$listing" | grep -qx "$target" || die "$EX_DATAERR" "generation $target does not exist"
  else
    target="$(awk -v c="$current" '$1+0 < c+0 {g=$1} END{print g}' <<<"$listing")"
    [[ -n "$target" ]] || die "$EX_UNAVAILABLE" "no earlier generation to roll back to"
  fi
  [[ "$target" != "$current" ]] || die "$EX_USAGE" "generation $target is already current"

  local genpath
  genpath="$(readlink -f "$profile-$target-link" 2>/dev/null)" ||
    die "$EX_DATAERR" "cannot resolve generation $target"
  printf 'atyrode: roll %s back from generation %s to %s\n' "$platform" "$current" "$target" >&2

  # The lock is held from here through the activation, so the generation the
  # report describes is the one still running when the switch begins; a dry
  # run holds nothing, since it changes nothing. A NixOS rollback runs under
  # sudo, which drops the receipt and the environment apply resolves the host
  # from, so the host may be named on the command line; the operator whose
  # Home Manager units the report labels is the account that invoked sudo.
  [[ "$dry" == 1 ]] || activation_lock
  local running report host operator
  host="$(resolve_host "$requested")"
  operator="${SUDO_USER:-$(actual_user)}"
  running="$(current_generation "$activation" "$operator")" ||
    die "$EX_UNAVAILABLE" "the generation running now cannot be named, so generation $target cannot be shown safe against it"
  report="$(disruption_analyze "$host" "$activation" "$running" "$genpath" "$operator" "${scopes[@]+"${scopes[@]}"}")" ||
    die "$EX_UNAVAILABLE" "the disruption analyzer did not produce a report, and a rollback without one cannot be shown safe"
  disruption_render "$report"
  if [[ "$dry" == 1 ]]; then
    printf '  dry run — nothing activated\n' >&2
    return 0
  fi
  disruption_enforce "$report" "$expected_disruption" "$genpath"
  [[ "$assume_yes" == 1 ]] || confirm "activate generation $target now?" || return 0

  # Activating a generation is the same class of change `apply` makes, and apply
  # shows its argv: the confirm above answered "may I", the commands below answer
  # "with what".
  if [[ "$platform" == nix-darwin ]]; then
    command -v darwin-rebuild >/dev/null || die "$EX_UNAVAILABLE" "darwin-rebuild is unavailable"
    # darwin-rebuild owns its own privilege elevation (as nh does for apply);
    # atyrode never self-elevates. Run `sudo atyrode rollback` if a setup needs it.
    run_visible darwin-rebuild --switch-generation "$target" || die "$EX_SOFTWARE" "rollback failed"
  elif [[ "$platform" == nixos ]]; then
    [[ "$(effective_uid)" == 0 ]] ||
      die "$EX_UNAVAILABLE" "NixOS rollback requires root; rerun this exact command with sudo"
    [[ -x "$genpath/bin/switch-to-configuration" ]] ||
      die "$EX_DATAERR" "generation $target has no NixOS switch-to-configuration program"
    # Resolved rather than run through core's nix_env wrapper: an announced
    # command has to be one an operator can paste back, and a shell function name
    # is not a program.
    local nix_env_command=nix-env
    [[ "$test_hooks" != 1 || -z "${ATYRODE_NIX_ENV:-}" ]] || nix_env_command="$ATYRODE_NIX_ENV"
    run_visible "$nix_env_command" -p "$profile" --switch-generation "$target" ||
      die "$EX_SOFTWARE" "could not select NixOS generation $target"
    run_visible "$profile/bin/switch-to-configuration" switch ||
      die "$EX_SOFTWARE" "NixOS rollback activation failed"
  else
    [[ -x "$genpath/activate" ]] || die "$EX_DATAERR" "generation $target has no activate script"
    run_visible "$genpath/activate" || die "$EX_SOFTWARE" "rollback activation failed"
  fi
  printf 'atyrode: now on generation %s\n' "$target" >&2
}
