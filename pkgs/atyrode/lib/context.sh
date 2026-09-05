# shellcheck shell=bash
#
# The agent context: the operator policy with this machine's facts appended,
# rendered into the one file every agent tool on the machine reads.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# Where the generated file lives. The tool files (~/.claude/CLAUDE.md,
# ~/.codex/AGENTS.md, ~/.omp/agent/AGENTS.md) are Home Manager symlinks to
# this path, so a render never has to know which tools are installed.
context_target() {
  printf '%s/agents/AGENTS.md\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# The command that acquires each session, spelled the way the operator types
# it. Repeated in every "not authenticated" line so an agent never has to ask.
readonly context_gh_login='gh auth login'
readonly context_clever_login='clever login'
readonly context_vault_login='atyrode vault login'

# gh's own status report names each account and where its token lives, never
# the token; only the login of a session gh could validate is taken from it,
# so an unverifiable process token counts as no session. Bounded because gh
# consults the API to validate and a machine without network would otherwise
# hang a render that has nothing to do with the network.
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
  elif clever_logged_out; then
    jq -nc --arg acquire "$context_clever_login" \
      '{available:true,authenticated:false,account:null,acquire:$acquire}'
  else
    profile="$(timeout 15s "$program" profile -F json 2>/dev/null || true)"
    account="$(jq -r 'select(type == "object") | .name // .alias // empty' <<<"$profile" 2>/dev/null || true)"
    jq -nc --arg account "$account" --arg acquire "$context_clever_login" \
      '{available:true,authenticated:true,account:(if $account == "" then null else $account end),acquire:$acquire}'
  fi
}

# Bitwarden is state only: the session is device-bound and the vault reports
# whether it is logged in and whether it is unlocked, which is all an agent
# needs to know before it reaches for `atyrode vault get`.
context_bitwarden_json() {
  local state
  state="$(bw_cli status 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)"
  jq -nc --arg state "$state" --arg acquire "$context_vault_login" '{
    available: ($state != ""),
    authenticated: ($state == "locked" or $state == "unlocked"),
    vault: (if $state == "" then null else $state end),
    acquire: $acquire
  }'
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

# Everything the generated section says, as one document. The Markdown is
# rendered from this rather than alongside it, so `--json` and the file can
# never disagree about a fact.
context_machine_json() {
  local host data fleet generated_at checkout="" clone_root=null
  host="$(resolve_host)"
  data="$(host_json "$host")"
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fleet="$(jq -c --arg host "$host" '
    [to_entries[].value | select(.id != $host)
      | {id, description, activation, platform, portable: ((.identityMode // "fixed") == "runtime")}]
    | sort_by(.portable, .id)' "$registry")"
  # No registry field or inventory declares a clone root yet, and guessing one
  # is exactly what this file exists to end; the dotfiles checkout is the one
  # path this repository already treats as conventional (lifecycle probes it).
  [[ ! -d "$HOME/nix-dotfiles/.git" ]] || checkout="$HOME/nix-dotfiles"
  jq -nc \
    --arg generatedAt "$generated_at" \
    --arg revision "$embedded_revision" \
    --arg target "$(context_target)" \
    --argjson host "$(jq -c '{id, description, system, platform, activation, capabilities}' <<<"$data")" \
    --argjson fleet "$fleet" \
    --argjson gh "$(context_gh_json)" \
    --argjson clever "$(context_clever_json)" \
    --argjson bitwarden "$(context_bitwarden_json)" \
    --argjson fleetCache "$(context_fleet_cache_json)" \
    --argjson cloneRoot "$clone_root" \
    --arg checkout "$checkout" \
    '{schemaVersion:1,command:"context",generatedAt:$generatedAt,revision:$revision,target:$target,
      host:$host,fleet:$fleet,
      authentication:{gh:$gh,clever:$clever,bitwarden:$bitwarden},
      secrets:{readable:[],note:"none yet; secrets arrive with ADR 0008 step 3 (clan vars over sops-nix)"},
      fleetCache:$fleetCache,
      cloneRoot:$cloneRoot,
      dotfilesCheckout:(if $checkout == "" then null else $checkout end)}'
}

# The generated section. The first line is the one doctor parses back, so its
# shape is a contract: `Generated at <timestamp> from atyrode/dotfiles
# revision <revision> by ...`.
context_render_section() { # machine-json
  jq -r '
    def auth(name; entry; noun):
      if entry.authenticated then
        "- `\(name)`: authenticated" +
          (if entry.account then " as `\(entry.account)`" else "" end) +
          (if entry.vault then ", vault \(entry.vault)" +
            (if entry.vault == "locked" then " (unlock with `\(entry.acquire)`)" else "" end)
           else "" end)
      elif entry.available then
        "- `\(name)`: not authenticated; acquire \(noun) with `\(entry.acquire)`"
      else
        "- `\(name)`: not installed here, so not authenticated; once present, acquire \(noun) with `\(entry.acquire)`"
      end;
    "## This machine",
    "",
    "Generated at \(.generatedAt) from atyrode/dotfiles revision \(.revision) by `atyrode context render`.",
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
    auth("bw"; .authentication.bitwarden; "a Bitwarden session"),
    "",
    "### Secrets readable here",
    "",
    (if (.secrets.readable | length) == 0 then "None yet; secrets arrive with ADR 0008 step 3 (clan vars over sops-nix). Until then the vault is the only secret store and `atyrode vault get NAME` is the explicit secret-output boundary."
     else (.secrets.readable[] | "- `\(.name)`: \(.path)") end),
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
     else "- There is no dotfiles checkout at `~/nix-dotfiles`; this machine consumes the published flake through `atyrode apply`." end),
    "",
    "This section is generated by `atyrode context`; if it is wrong, `atyrode doctor` is wrong. Never edit by hand."
  ' <<<"$1"
}

context_render_document() { # machine-json
  cat "$agents_policy"
  printf '\n'
  context_render_section "$1"
}

# Written whole and moved into place, mode 0644: an agent reading the file
# mid-render sees the previous complete one, never a torn one. Shell
# bookkeeping stays silent; the caller names the path it produced.
context_write() { # machine-json
  local target directory temporary
  target="$(context_target)"
  directory="${target%/*}"
  [[ ! -L "$target" ]] || die "$EX_DATAERR" "the agent context must be a regular file, not a symlink: $target"
  mkdir -p "$directory"
  temporary="$(mktemp "$directory/.AGENTS.md.XXXXXX")"
  context_render_document "$1" >"$temporary"
  chmod 644 "$temporary"
  mv -f "$temporary" "$target"
  printf '%s\n' "$target"
}

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

# The header line context_render_section writes, read back: prints
# `<timestamp> <revision>` or nothing when the file does not carry one.
context_stamp() { # file
  sed -nE 's/^Generated at ([^ ]+) from atyrode\/dotfiles revision ([^ ]+) by .*$/\1 \2/p' "$1" | head -n 1
}

# A missing file is a to-do apply settles on its own; a present one is stale
# when it came from another published revision than this CLI or is older than
# a week, since what it says about sessions decays even when nothing shipped.
# Development builds carry no revision to compare, so only the age applies.
probe_agent_context() {
  local target stamp rendered_at revision rendered_epoch now
  target="$(context_target)"
  if [[ ! -f "$target" ]]; then
    provisioning_unconfigured agent-context \
      "no generated context at $target, so agents here start without this machine's facts"
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
  if [[ "$embedded_revision" =~ ^[0-9a-f]{40}$ && "$revision" != "$embedded_revision" ]]; then
    provisioning_check_add agent-context degraded context-stale \
      "the agent context was rendered from revision ${revision:0:12}, not this CLI's ${embedded_revision:0:12}" \
      "atyrode context render"
    return 0
  fi
  if rendered_epoch="$(date -u -d "$rendered_at" +%s 2>/dev/null)"; then
    now="$(date -u +%s)"
    if ((now - rendered_epoch > 7 * 24 * 3600)); then
      provisioning_check_add agent-context degraded context-stale \
        "the agent context was rendered at $rendered_at, more than a week ago" \
        "atyrode context render"
      return 0
    fi
  fi
  provisioning_check_add agent-context ok "" \
    "the agent context was rendered at $rendered_at from revision ${revision:0:12}" ""
}

cmd_context() {
  local action="" json=0 machine
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
    die "$EX_USAGE" "context render writes the file; use context show --json for the machine section"
  machine="$(context_machine_json)"
  if [[ "$json" == 1 ]]; then
    printf '%s\n' "$machine"
  elif [[ "$action" == render ]]; then
    say "wrote $(context_write "$machine")"
  else
    context_render_document "$machine"
  fi
}
