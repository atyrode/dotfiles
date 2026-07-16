#!/usr/bin/env bash
set -euo pipefail

# Seed curated plain-omp defaults into the writable machine configuration
# with three-way-merge drift semantics. For every leaf path in the seed:
#
#   absent locally, never seeded        -> written (new default)
#   absent locally, seeded before       -> kept absent, reported as drift
#   equal to the seed                   -> in sync
#   changed locally since the last seed -> kept, reported as drift
#   blocked by a local non-mapping      -> kept, reported as drift
#   unchanged since a now-updated seed  -> updated to the new default
#
# Local edits therefore always win; only values the operator never touched
# follow the repository. Unmanaged keys are preserved untouched. The last
# applied seed is recorded so "operator changed it" and "repository changed
# it" stay distinguishable across updates. The writable file is machine
# formatted: omp itself rewrites it without comments, and so does this tool.

seed_file="${OMP_SEED_FILE:?OMP_SEED_FILE must point at the seed YAML}"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/omp-plain-seed"
snapshot_file="$state_root/last-applied.yml"
report_file="$state_root/drift.json"
dry_run="${AGENT_TOOLS_DRY_RUN:-0}"

# Always the default state root: the seed's target and its global drift state
# are a pair. Honoring a caller's PI_CODING_AGENT_DIR (e.g. `atyrode apply` run
# from inside a profile-scoped agent session) would audit — and seed — the
# wrong profile's config against state recorded for the default root.
agent_dir="$HOME/.omp/agent"

transient_files=()
cleanup() {
  local path
  for path in ${transient_files[@]+"${transient_files[@]}"}; do
    rm -f -- "$path" 2>/dev/null || true
  done
}
trap cleanup EXIT

fail() {
  printf 'omp-seed: %s\n' "$1" >&2
  exit 1
}

# Prefer config.yml, accept OMP's legacy config.yaml fallback. If the
# preferred name later starts to exist alongside the legacy one, omp reads
# the .yml and every previously seeded key in the .yaml reports as drift —
# a safe failure mode that surfaces the dual-file state without writes.
resolve_config_path() {
  if [[ -f "$agent_dir/config.yml" ]]; then
    printf '%s\n' "$agent_dir/config.yml"
  elif [[ -f "$agent_dir/config.yaml" ]]; then
    printf '%s\n' "$agent_dir/config.yaml"
  else
    printf '%s\n' "$agent_dir/config.yml"
  fi
}

ensure_state_root() {
  mkdir -p "$state_root"
  chmod 700 "$state_root"
}

acquire_lock() {
  ensure_state_root
  exec 9>"$state_root/.lock"
  flock -w 15 9 || fail "another omp-seed run holds the lock"
}

yaml_to_json() {
  local path="$1"
  if [[ -f "$path" ]]; then
    yq eval -o=json '. // {}' "$path" || fail "invalid YAML in $path"
  else
    printf '{}\n'
  fi
}

file_digest() {
  if [[ -f "$1" ]]; then
    sha256sum <"$1" | cut -d' ' -f1
  else
    printf 'absent\n'
  fi
}

# Classify every seed leaf against the live config and the last-applied
# snapshot. Arrays are atomic leaves; path segments are always object keys
# because the seed never indexes into arrays. A leaf whose intermediate
# path is blocked by a local scalar or array is drift, never a write —
# setpath would otherwise error (or the merge would destroy the local
# value), so blocked leaves must not reach the set list.
classify() {
  local live_json="$1" seed_json="$2" snap_json="$3"
  jq -n \
    --argjson live "$live_json" \
    --argjson seed "$seed_json" \
    --argjson snap "$snap_json" '
    def leafpaths:
      [ paths as $p
        | select((($p | map(type) | any(. == "number")) | not)
                 and ((getpath($p) | type) != "object"))
        | $p ];
    def haspath($p):
      try (reduce ($p[:-1])[] as $k (.; .[$k]) | (type == "object") and has($p[-1]))
      catch false;
    def pathopen($p):
      try (reduce ($p[:-1])[] as $k (.; .[$k]) | (type == "object") or (type == "null"))
      catch false;
    ($seed | leafpaths) as $paths
    | reduce $paths[] as $p (
        {set: [], drift: [], insync: []};
        ($seed | getpath($p)) as $s
        | ($live | pathopen($p)) as $open
        | ($live | haspath($p)) as $lh
        | ($snap | haspath($p)) as $sh
        | (if $lh then ($live | getpath($p)) else null end) as $l
        | (if $sh then ($snap | getpath($p)) else null end) as $v0
        | if ($open | not)
          then .drift += [{path: $p, key: ($p | join(".")), live: null, seed: $s, reason: "blocked-by-local-value"}]
          elif ($lh | not) and ($sh | not)
          then .set += [{path: $p, key: ($p | join(".")), to: $s, reason: "new"}]
          elif ($lh | not)
          then .drift += [{path: $p, key: ($p | join(".")), live: null, seed: $s, reason: "deleted-locally"}]
          elif $l == $s
          then .insync += [{key: ($p | join("."))}]
          elif $sh and ($l == $v0)
          then .set += [{path: $p, key: ($p | join(".")), from: $l, to: $s, reason: "seed-updated"}]
          else .drift += [{path: $p, key: ($p | join(".")), live: $l, seed: $s, reason: "local-edit"}]
          end
      )
    | {set, drift, insync}'
}

# Atomically replace the target with the rendered JSON document. Refuses
# non-mapping documents so a failed upstream merge can never blank the
# operator's configuration, follows symlinks so a linked config is updated
# in place, and aborts when the target changed since it was read (the
# caller passes the digest captured at load time).
write_yaml_atomically() {
  local json="$1" target="$2" expected_digest="$3" mode temp real
  jq -e 'type == "object"' <<<"$json" >/dev/null 2>&1 ||
    fail "refusing to write a non-mapping document to $target"
  real="$(realpath -m -- "$target")"
  mode=600
  if [[ -f "$real" ]]; then
    mode="$(stat -c '%a' "$real")"
  fi
  mkdir -p "$(dirname "$real")"
  temp="$(mktemp "$(dirname "$real")/.omp-seed.XXXXXX")"
  transient_files+=("$temp")
  printf '%s\n' "$json" | yq eval -P '.' - >"$temp" || fail "could not render YAML for $target"
  yq eval '.' "$temp" >/dev/null || fail "rendered YAML for $target failed validation"
  chmod "$mode" "$temp"
  if [[ "$(file_digest "$target")" != "$expected_digest" ]]; then
    fail "$target changed while omp-seed was running; rerun to pick up the new state"
  fi
  mv -f -- "$temp" "$real"
}

write_report() {
  local classification="$1" config_path="$2" temp
  ensure_state_root
  temp="$(mktemp "$state_root/.drift.json.XXXXXX")"
  transient_files+=("$temp")
  jq -n \
    --argjson result "$classification" \
    --arg config "$config_path" \
    --arg seed "$seed_file" \
    --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{generatedAt: $generatedAt, config: $config, seed: $seed,
      applied: [$result.set[] | {key, reason, to}],
      drift: [$result.drift[] | {key, reason, live, seed}],
      inSyncCount: ($result.insync | length)}' >"$temp"
  chmod 600 "$temp"
  mv -f -- "$temp" "$report_file"
}

print_summary() {
  local classification="$1" verb="$2"
  local set_count drift_count sync_count
  set_count="$(jq -r '.set | length' <<<"$classification")"
  drift_count="$(jq -r '.drift | length' <<<"$classification")"
  sync_count="$(jq -r '.insync | length' <<<"$classification")"
  printf 'omp seed: %s %s, %s drifted (kept), %s in sync\n' \
    "$set_count" "$verb" "$drift_count" "$sync_count"
  if [[ "$set_count" != 0 ]]; then
    jq -r '.set[] | "  + \(.key) = \(.to | tojson)\(if .reason == "seed-updated" then " (was \(.from | tojson))" else "" end)"' \
      <<<"$classification"
  fi
  if [[ "$drift_count" != 0 ]]; then
    jq -r '.drift[] | "  ~ \(.key): local \(.live | tojson) / default \(.seed | tojson) [\(.reason)]"' \
      <<<"$classification"
    printf '  review with: atyrode-omp-seed resolve\n'
  fi
}

load_documents() {
  config_path="$(resolve_config_path)"
  live_digest="$(file_digest "$config_path")"
  live_json="$(yaml_to_json "$config_path")"
  seed_json="$(yaml_to_json "$seed_file")"
  snap_json="$(yaml_to_json "$snapshot_file")"
  jq -e 'type == "object"' <<<"$live_json" >/dev/null || fail "$config_path is not a YAML mapping"
  jq -e 'type == "object"' <<<"$seed_json" >/dev/null || fail "seed $seed_file is not a YAML mapping"
}

apply_sets() {
  local classification="$1"
  jq -n \
    --argjson live "$live_json" \
    --argjson result "$classification" \
    'reduce $result.set[] as $s ($live; setpath($s.path; $s.to))'
}

cmd_apply() {
  if [[ "$dry_run" == 1 ]]; then
    load_documents
    printf 'omp seed: dry run, no files were written\n'
    print_summary "$(classify "$live_json" "$seed_json" "$snap_json")" "to apply"
    return 0
  fi

  acquire_lock
  load_documents
  local classification merged
  classification="$(classify "$live_json" "$seed_json" "$snap_json")"

  if [[ "$(jq -r '.set | length' <<<"$classification")" != 0 ]]; then
    merged="$(apply_sets "$classification")" ||
      fail "could not merge seed values into $config_path"
    write_yaml_atomically "$merged" "$config_path" "$live_digest"
  fi
  install -m 600 "$seed_file" "$snapshot_file"
  write_report "$classification" "$config_path"
  print_summary "$classification" "applied"
}

cmd_status() {
  local json=0
  [[ "${1:-}" != --json ]] || json=1
  load_documents
  local classification
  classification="$(classify "$live_json" "$seed_json" "$snap_json")"
  if [[ "$json" == 1 ]]; then
    jq -n --argjson result "$classification" --arg config "$config_path" --arg seed "$seed_file" \
      '{config: $config, seed: $seed,
        pending: [$result.set[] | {key, reason, to}],
        drift: [$result.drift[] | {key, reason, live, seed}],
        inSyncCount: ($result.insync | length)}'
  else
    print_summary "$classification" "pending"
  fi
}

cmd_resolve() {
  local reset_all=0
  [[ "${1:-}" != --reset-all ]] || reset_all=1
  acquire_lock
  load_documents
  local classification drift_count
  classification="$(classify "$live_json" "$seed_json" "$snap_json")"
  drift_count="$(jq -r '.drift | length' <<<"$classification")"
  if [[ "$drift_count" == 0 ]]; then
    printf 'omp seed: no drift to resolve\n'
    return 0
  fi

  # Answers come from the TTY when interactive, otherwise from stdin (so
  # tests and scripts can pipe them). fd 4 keeps a single read position for
  # file-backed stdin; fd 3 carries the drift list.
  if [[ "$reset_all" == 0 && -t 0 ]]; then
    exec 4</dev/tty
  else
    exec 4<&0
  fi

  local updated="$live_json" answer key live_value seed_value keep_all=0
  while IFS=$'\t' read -r -u 3 key live_value seed_value; do
    if [[ "$reset_all" == 1 ]]; then
      answer=r
    elif [[ "$keep_all" == 1 ]]; then
      answer=k
    else
      printf '%s\n  local:   %s\n  default: %s\n' "$key" "$live_value" "$seed_value"
      printf '  [k]eep local / [r]eset to default / keep [a]ll / [q]uit: '
      read -r -u 4 answer || answer=q
      printf '\n'
    fi
    case "$answer" in
      r | R)
        # Resetting may need to displace a local non-mapping that blocks the
        # path; the operator explicitly chose the default here.
        updated="$(jq --arg key "$key" --argjson result "$classification" '
          first($result.drift[] | select(.key == $key)) as $d
          | reduce range(1; $d.path | length) as $i (
              .;
              if (try (getpath($d.path[:$i]) | (type == "object") or (type == "null")) catch false)
              then .
              else delpaths([$d.path[:$i]])
              end
            )
          | setpath($d.path; $d.seed)' <<<"$updated")" ||
          fail "could not reset $key"
        printf '  reset %s\n' "$key"
        ;;
      a | A) keep_all=1 ;;
      q | Q) break ;;
      *) printf '  kept %s\n' "$key" ;;
    esac
  done 3< <(jq -r '.drift[] | [.key, (.live | tojson), (.seed | tojson)] | @tsv' <<<"$classification")

  if [[ "$updated" != "$live_json" ]]; then
    write_yaml_atomically "$updated" "$config_path" "$live_digest"
    live_json="$updated"
    live_digest="$(file_digest "$config_path")"
  fi
  classification="$(classify "$live_json" "$seed_json" "$snap_json")"
  write_report "$classification" "$config_path"
  print_summary "$classification" "pending"
}

usage() {
  cat <<'EOF'
atyrode-omp-seed <command>

  apply                Seed missing defaults and follow repository updates for
                       values the operator never changed. Local edits win and
                       are reported as drift. Honors AGENT_TOOLS_DRY_RUN=1.
  status [--json]      Report pending seeds and drift without writing.
  resolve [--reset-all]
                       Interactively keep or reset each drifted value.
EOF
}

case "${1:-}" in
  apply)
    shift
    cmd_apply "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  resolve)
    shift
    cmd_resolve "$@"
    ;;
  -h | --help | help | '') usage ;;
  *)
    usage >&2
    exit 64
    ;;
esac
