# shellcheck shell=bash
#
# The startup context contains personal policy and generation provenance only.
# Machine inventory is collected solely for explicit diagnostic display.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# The default OMP user file and Claude/Codex adapters are Home Manager symlinks
# to this path, so a render need not discover tools or named profiles.
context_target() {
  printf '%s/agents/AGENTS.md\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Diagnostic remediation names the owning tool's supported login command.
readonly context_gh_login='gh auth login'
readonly context_clever_login='clever login'

# gh's own status report names each account and where its token lives, never
# the token; only the login of a session gh could validate is taken from it,
# so an unverifiable process token counts as no session. Bounded because gh
# consults the API to validate; explicit diagnostics must not hang indefinitely.
context_gh_json() {
  local available=false status="" account=""
  ! command -v gh >/dev/null 2>&1 || available=true
  if [[ "$available" == true ]] &&
    status="$(timeout 10s gh auth status --json hosts 2>/dev/null)" &&
    account="$(jq -er '[.hosts[][]? | select(.state == "success")]
      | (map(select(.active == true)) + .) | first | .login' <<<"$status" 2>/dev/null)"; then
    jq -nc --arg account "$account" --arg acquire "$context_gh_login" \
      '{available:true,authenticated:true,account:(if $account == "" then null else $account end),acquire:$acquire}'
  else
    jq -nc --argjson available "$available" --arg acquire "$context_gh_login" \
      '{available:$available,authenticated:false,account:null,acquire:$acquire}'
  fi
}

# `clever profile` is the same question clever_logged_out asks; its JSON form
# carries the account's display name and no token, so a logged-in machine
# gets a name from one more bounded call.
context_clever_json() {
  local program profile="" account=""
  program="$(clever_program)"
  if ! command -v "$program" >/dev/null 2>&1; then
    jq -nc --arg acquire "$context_clever_login" \
      '{available:false,authenticated:false,account:null,acquire:$acquire}'
  elif ! timeout 15s "$program" profile >/dev/null 2>&1; then
    jq -nc --arg acquire "$context_clever_login" \
      '{available:true,authenticated:false,account:null,acquire:$acquire}'
  else
    profile="$(timeout 15s "$program" profile -F json 2>/dev/null || true)"
    account="$(jq -r 'select(type == "object") | .name // .alias // empty' <<<"$profile" 2>/dev/null || true)"
    jq -nc --arg account "$account" --arg acquire "$context_clever_login" \
      '{available:true,authenticated:true,account:(if $account == "" then null else $account end),acquire:$acquire}'
  fi
}

# The secrets this account can read are the clan vars sops-nix placed for it.
# sops directories can be searchable but not listable (0751 root:keys), so
# probe published var names as well as discoverable placements. Follow sops
# symlinks, but inspect only generator/file paths and never open their contents.
context_secrets_json() {
  local root entry
  root="$(machine_key_system_root)/run/secrets/vars"
  {
    jq -j --arg root "$root" '.[] | $root + "/" + . + "\u0000"' "$clan_var_names"
    if [[ -d "$root" ]]; then
      find -L "$root" -mindepth 2 -maxdepth 2 -type f -print0 2>/dev/null || true
    fi
  } |
    while IFS= read -r -d "" entry; do
      if [[ -f "$entry" && -r "$entry" ]]; then
        printf '%s\0' "$entry"
      fi
    done |
    jq -Rsc --arg root "$root" 'split("\u0000") | map(select(length > 0)) | unique
      | map({name: ltrimstr($root + "/"), path: .})'
}

# The fleet cache is trusted when the daemon lists both its URL and its key,
# read from the same effective configuration doctor's nix-policy probe reads,
# and from the same fixture when a check drives it.
context_fleet_cache_json() {
  local substituter key trusted=false config_json
  substituter="$(jq -r '.nix.fleetCache.substituter' "$system_policy")"
  key="$(jq -r '.nix.fleetCache.trustedPublicKey' "$system_policy")"
  system_fixture="$(load_system_fixture)"
  if has_system_fixture; then
    trusted="$(jq -r '(.nix.substitutersExact // false) and (.nix.trustedKeysExact // false)' <<<"$system_fixture")"
  else
    config_json="$(nix config show --json 2>/dev/null || printf '{}')"
    jq -e --arg substituter "$substituter" --arg key "$key" \
      '(.substituters.value | index($substituter)) != null
        and (.["trusted-public-keys"].value | index($key)) != null' <<<"$config_json" >/dev/null &&
      trusted=true
  fi
  jq -nc --arg substituter "$substituter" --argjson trusted "$trusted" \
    '{substituter:$substituter,trusted:$trusted}'
}

# Explicit diagnostic inventory. The text display and public JSON share this
# document; startup rendering never calls it.
context_machine_json() {
  local host data fleet generated_at
  host="$(resolve_host)"
  data="$(host_json "$host")"
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fleet="$(jq -c --arg host "$host" '
    [to_entries[].value | select(.id != $host)
      | {id, description, activation, platform, portable: ((.identityMode // "fixed") == "runtime")}]
    | sort_by(.portable, .id)' "$registry")"
  # Neither path has a declared owner in the registry. Keep the public fields
  # unknown rather than discovering a checkout from HOME or the working tree.
  jq -nc \
    --arg generatedAt "$generated_at" \
    --arg revision "$embedded_revision" \
    --arg target "$(context_target)" \
    --argjson host "$(jq -c '{id, description, system, platform, activation, capabilities}' <<<"$data")" \
    --argjson fleet "$fleet" \
    --argjson gh "$(context_gh_json)" \
    --argjson clever "$(context_clever_json)" \
    --argjson secrets "$(context_secrets_json)" \
    --argjson fleetCache "$(context_fleet_cache_json)" \
    '{schemaVersion:1,command:"context",generatedAt:$generatedAt,revision:$revision,target:$target,
      host:$host,fleet:$fleet,
      authentication:{gh:$gh,clever:$clever},
      secrets:{readable:$secrets},
      fleetCache:$fleetCache,
      cloneRoot:null,
      dotfilesCheckout:null}'
}

# Human-readable diagnostics retain the policy-first show contract, but are
# never persisted into the startup instruction file.
context_render_section() { # machine-json
  jq -r '
    def auth(name; entry; noun):
      if entry.authenticated then
        "- `\(name)`: authenticated" + (if entry.account then " as `\(entry.account)`" else "" end)
      elif entry.available then
        "- `\(name)`: not authenticated; acquire \(noun) with `\(entry.acquire)`"
      else
        "- `\(name)`: not installed here, so not authenticated; once present, acquire \(noun) with `\(entry.acquire)`"
      end;
    "## This machine",
    "",
    "Generated at \(.generatedAt) from atyrode/dotfiles revision \(.revision) by `atyrode context show`.",
    "",
    "- Host: `\(.host.id)` -- \(.host.description)",
    "- Platform: \(.host.platform) (\(.host.system)); activated by \(.host.activation)",
    "- Capabilities: \(.host.capabilities | join(", "))",
    "",
    "### The fleet",
    "",
    "The other registered hosts, by name and role:",
    "",
    (.fleet[] | "- `\(.id)`: \(.description) (\(if .portable then "portable profile" else .activation end))"),
    "",
    "### Authenticated here",
    "",
    auth("gh"; .authentication.gh; "a GitHub session"),
    auth("clever"; .authentication.clever; "a Clever Cloud session"),
    "",
    "### Secrets readable here",
    "",
    "Clan vars placed by activation, named by generator and file at the readable path; secret values are never displayed.",
    "",
    (if (.secrets.readable | length) == 0 then "- None placed for this account."
     else (.secrets.readable[] | "- `\(.name)`: `\(.path)`") end),
    "",
    "### Nix cache",
    "",
    "- Fleet cache substituter: `\(.fleetCache.substituter)`",
    (if .fleetCache.trusted then "- This machine trusts it: its URL and signing key are in the effective Nix configuration."
     else "- This machine does not trust it yet; `atyrode doctor system` reports the nix-policy drift and names the enrolment line." end),
    "",
    "### Clone root",
    "",
    (if .cloneRoot then "- Canonical clone root: `\(.cloneRoot)`"
     else "- No canonical clone root is declared for this host; do not assume one." end),
    (if .dotfilesCheckout then "- The dotfiles checkout is `\(.dotfilesCheckout)`."
     else "- No dotfiles checkout is declared; repository-authoring commands require an explicit `--repo PATH`." end),
    "",
    "This is an on-demand diagnostic snapshot, not startup policy or authorization."
  ' <<<"$1"
}

context_render_document() { # optional generation timestamp and revision
  local rendered_at="${1:-}"
  [[ -n "$rendered_at" ]] || rendered_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return
  cat "$agents_policy" || return
  printf '\nGenerated at %s from atyrode/dotfiles revision %s by `atyrode context render`.\n' \
    "$rendered_at" "${2:-$embedded_revision}"
}

# Written whole and moved into place, mode 0644: an agent reading the file
# mid-render sees the previous complete one, never a torn one. Shell
# bookkeeping stays silent; the caller names the path it produced.
context_write() (
  local target directory temporary
  target="$(context_target)" || return
  directory="${target%/*}"
  [[ ! -L "$target" ]] || die "$EX_DATAERR" "the agent context must be a regular file, not a symlink: $target"
  [[ ! -e "$target" || -f "$target" ]] || die "$EX_DATAERR" "the agent context must be a regular file: $target"
  mkdir -p "$directory" || return
  temporary="$(mktemp "$directory/.AGENTS.md.XXXXXX")" || return
  # A subshell scopes cleanup to this write without replacing apply's traps.
  # Explicit guards also work when the caller disables errexit with `if`.
  trap 'rm -f -- "$temporary"' EXIT
  context_render_document >"$temporary" || return
  chmod 644 "$temporary" || return
  mv -fT -- "$temporary" "$target" || return
  trap - EXIT
  printf '%s\n' "$target"
)

# Re-enter the inspected generation, not a mutable global profile: a standalone
# Home Manager activation must not borrow a different system CLI. A generation
# without a CLI keeps this invoking copy rather than selecting unrelated code.
activated_atyrode() { # candidate user
  local root="$1" user="$2" candidate
  for candidate in \
    "$root/home-path/bin" \
    "$root/etc/profiles/per-user/$user/bin" \
    "$root/sw/bin"; do
    [[ -x "$candidate/atyrode" ]] || continue
    printf '%s\n' "$candidate/atyrode"
    return 0
  done
  atyrode_self
}

# The apply step: announced by the name the operator types, run through the
# copy activation just installed, and the file it produced named in prose.
apply_render_context() { # candidate user
  local program
  program="$(activated_atyrode "$1" "$2")" || return "$EX_UNAVAILABLE"
  show_command atyrode context render
  log_event "atyrode resolved to $program"
  "$program" context render
}

# The provenance line context_render_document writes, read back: prints
# `<timestamp> <revision>` or nothing when the file does not carry one.
context_stamp() { # file
  sed -nE 's/^Generated at ([^ ]+) from atyrode\/dotfiles revision ([^ ]+) by .*$/\1 \2/p' "$1" | head -n 1
}

# Policy does not expire with age. Compare the full expected document using its
# original timestamp so edits, older policy and retired inventory all need a
# render even when the embedded revision is an unpublished development build.
probe_agent_context() {
  local target stamp rendered_at revision expected actual
  target="$(context_target)"
  if [[ ! -f "$target" ]]; then
    provisioning_unconfigured agent-context \
      "no generated personal policy at $target"
    return 0
  fi
  stamp="$(context_stamp "$target")"
  if [[ -z "$stamp" ]]; then
    provisioning_check_add agent-context degraded context-unreadable \
      "$target carries no generation stamp; it was not written by this CLI" \
      "atyrode context render"
    return 0
  fi
  read -r rendered_at revision <<<"$stamp"
  # An unpublished build cannot establish revision currency; it still verifies
  # all policy bytes below, preserving the recorded generation provenance.
  if [[ "$embedded_revision" =~ ^[0-9a-f]{40}$ && "$revision" != "$embedded_revision" ]]; then
    provisioning_check_add agent-context degraded context-stale \
      "the agent context was rendered from revision ${revision:0:12}, not this CLI's ${embedded_revision:0:12}" \
      "atyrode context render"
    return 0
  fi
  expected="$(context_render_document "$rendered_at" "$revision" | sha256sum)"
  actual="$(sha256sum <"$target")"
  if [[ "$actual" != "$expected" ]]; then
    provisioning_check_add agent-context degraded context-stale \
      "the agent context does not match this CLI's personal policy and provenance" \
      "atyrode context render"
    return 0
  fi
  provisioning_check_add agent-context ok "" \
    "the agent context was rendered at $rendered_at from revision ${revision:0:12}" ""
}

cmd_context() {
  local action="" json=0 machine target
  while [[ $# -gt 0 ]]; do
    case "$1" in
      render | show)
        [[ -z "$action" ]] || die "$EX_USAGE" "context accepts one of render or show"
        action="$1"
        ;;
      --json) json=1 ;;
      *) die "$EX_USAGE" "unknown context option: $1" ;;
    esac
    shift
  done
  [[ "$json" == 0 || "$action" != render ]] ||
    die "$EX_USAGE" "context render writes the file; use context show --json for diagnostics"
  if [[ "$action" == render ]]; then
    target="$(context_write)" || return
    say "wrote $target"
    return 0
  fi
  machine="$(context_machine_json)"
  if [[ "$json" == 1 ]]; then
    printf '%s\n' "$machine"
  else
    cat "$agents_policy"
    printf '\n'
    context_render_section "$machine"
  fi
}
