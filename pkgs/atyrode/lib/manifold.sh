# shellcheck shell=bash
#
# manifold-agent fleet enrolment, and the runtime dispatch that reaches it.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# --- manifold-agent runtime --------------------------------------------------
# Fleet enrollment for the self-hosted manifold hub (#418). The committed
# inventory/manifold.json owns master discovery; the vault holds only the
# owner key, read once during interactive provisioning. The running agent
# authenticates with a 0600 machine token file and never touches the vault.

manifold_token_path() {
  # The systemd unit hardcodes %h/.config/manifold/machine.token (unit
  # specifiers cannot see XDG overrides), so provisioning pins the same
  # literal path instead of honoring XDG_CONFIG_HOME.
  printf '%s/.config/manifold/machine.token\n' "$HOME"
}

manifold_machine_name() {
  # Full kernel hostname, matching the unit's %H specifier so the enrolled
  # row and the presented MANIFOLD_MACHINE_NAME can never diverge.
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_HOSTNAME:-}" ]]; then
    printf '%s\n' "$_ATYRODE_TEST_HOSTNAME"
  else
    hostname
  fi
}

manifold_inventory_field() {
  jq -er --arg key "$1" '.[$key]' "$manifold_inventory" ||
    die "$EX_SOFTWARE" "inventory/manifold.json lacks $1"
}

manifold_applicable() {
  [[ "$(uname -s)" == Linux ]] && command -v manifold-agent >/dev/null 2>&1
}

manifold_enrolled() {
  local token_path
  token_path="$(manifold_token_path)"
  [[ -f "$token_path" && "$(stat -c %a "$token_path" 2>/dev/null)" == 600 ]]
}

manifold_status_json() {
  local applicable=false reason="" enrolled=false phase=unsupported
  local active_state=unknown sub_state=unknown unit_present=false last_event=none
  local systemctl journalctl master_url machine_name token_path
  master_url="$(manifold_inventory_field masterUrl)"
  machine_name="$(manifold_machine_name)"
  token_path="$(manifold_token_path)"
  if manifold_applicable; then
    applicable=true
    phase=available
  else
    reason="requires a Linux host with the manifold-node capability installed"
  fi
  if manifold_enrolled; then
    enrolled=true
    [[ "$applicable" != true ]] || phase=enrolled
  fi
  if systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)"; then
    if "$systemctl" --user cat manifold-agent.service >/dev/null 2>&1; then
      unit_present=true
      active_state="$("$systemctl" --user show -P ActiveState manifold-agent.service 2>/dev/null || printf unknown)"
      sub_state="$("$systemctl" --user show -P SubState manifold-agent.service 2>/dev/null || printf unknown)"
      if [[ "$applicable" == true && "$enrolled" == true && "$active_state" == active ]]; then
        phase=running
      fi
    fi
  fi
  if journalctl="$(optional_host_command ATYRODE_JOURNALCTL journalctl)"; then
    # Value-free connection probe: the agent logs `welcome` after the hub
    # accepts it and names rejections explicitly; neither line carries the
    # token. Report only which event was seen last.
    last_event="$("$journalctl" --user -u manifold-agent -n 80 --no-pager -o cat 2>/dev/null |
      awk '/welcome/ { seen = "welcome" } /rejected/ { seen = "rejected" } END { print (seen == "" ? "none" : seen) }')"
    if [[ "$phase" == running && "$last_event" == welcome ]]; then
      phase=connected
    fi
  fi
  jq -nc \
    --arg name manifold-agent --arg label "Manifold fleet agent" \
    --arg phase "$phase" --arg reason "$reason" \
    --arg masterUrl "$master_url" --arg machineName "$machine_name" \
    --arg tokenPath "$token_path" --arg activeState "$active_state" \
    --arg subState "$sub_state" --arg lastLogEvent "$last_event" \
    --argjson applicable "$applicable" --argjson enrolled "$enrolled" \
    --argjson unitPresent "$unit_present" \
    '{schemaVersion:1,name:$name,label:$label,phase:$phase,reason:$reason,
      applicable:$applicable,enrolled:$enrolled,masterUrl:$masterUrl,
      machineName:$machineName,tokenPath:$tokenPath,
      unit:{present:$unitPresent,activeState:$activeState,subState:$subState},
      lastLogEvent:$lastLogEvent}'
}

manifold_render_status() {
  manifold_status_json | jq -r '
    "manifold-agent: \(.phase)",
    "  master: \(.masterUrl)",
    "  machine: \(.machineName)",
    "  enrolled: \(.enrolled)",
    "  unit: \(if .unit.present then "\(.unit.activeState) (\(.unit.subState))" else "not installed" end)"'
}

manifold_provision() {
  local rotate=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rotate-token) rotate=1 ;;
      *) die "$EX_USAGE" "unknown manifold-agent provision option: $1" ;;
    esac
    shift
  done
  [[ "$(uname -s)" == Linux ]] ||
    die "$EX_UNAVAILABLE" "manifold-agent provisioning currently supports Linux hosts only"
  local token_path master_url item_name machine_name
  token_path="$(manifold_token_path)"
  if [[ "$rotate" == 0 && -f "$token_path" ]]; then
    chmod 600 "$token_path"
    printf 'atyrode: %s is already enrolled (token at %s)\n' \
      "$(manifold_machine_name)" "$token_path" >&2
    manifold_render_status
    return 0
  fi
  master_url="$(manifold_inventory_field masterUrl)"
  item_name="$(manifold_inventory_field vaultItemName)"
  machine_name="$(manifold_machine_name)"

  local scratch
  scratch="$(vault_secure_temp_dir atyrode-manifold)"
  manifold_provision_cleanup() {
    rm -rf -- "${scratch:-}"
    vault_close_session
  }
  trap manifold_provision_cleanup EXIT HUP INT TERM

  # The owner key must never enter argv (world-readable in /proc); it flows
  # from the vault note into a 0600 curl config inside the secure temp dir.
  vault_item_notes "$item_name" "$scratch" >"$scratch/owner.key"
  [[ -s "$scratch/owner.key" ]] ||
    die "$EX_DATAERR" "Bitwarden Secure Note '$item_name' is empty"
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$scratch/owner.key")" \
    >"$scratch/curl.cfg"

  local fetch payload response token
  fetch="$(optional_host_command ATYRODE_FETCH curl)" ||
    die "$EX_UNAVAILABLE" "curl is required to enroll with the manifold master"
  payload="$(jq -nc --arg name "$machine_name" --argjson rotate "$([[ "$rotate" == 1 ]] && printf true || printf false)" \
    '{name:$name} + (if $rotate then {rotateToken:true} else {} end)')"
  response="$scratch/response.json"
  # Safe to print verbatim: the owner key stays in the 0600 curl config written
  # above and the minted token lands in $response, so this argv carries a path,
  # this machine's name, and the committed master URL.
  run_visible "$fetch" -fsSL --config "$scratch/curl.cfg" -X POST \
    -H 'content-type: application/json' -d "$payload" \
    -o "$response" "$master_url/api/machines" ||
    die "$EX_UNAVAILABLE" "could not enroll with the manifold master at $master_url"
  token="$(jq -r '.machineToken // empty' "$response")"
  # The secret window ends here: shred the scratch material (owner key, curl
  # config, response) and lock the vault before any further work — the token
  # write and the status probes below must not run with a session open.
  trap - EXIT HUP INT TERM
  manifold_provision_cleanup
  if [[ -z "$token" ]]; then
    die "$EX_DATAERR" "machine '$machine_name' is already enrolled and the master mints no token on re-enrollment; recover a lost token with --rotate-token (this fences any agent still using the old token)"
  fi
  mkdir -p "$(dirname "$token_path")"
  chmod 700 "$(dirname "$token_path")"
  (umask 077 && printf '%s\n' "$token" >"$token_path.tmp")
  mv -f "$token_path.tmp" "$token_path"
  # The unit gates on the token file existing, so its path is the fact worth
  # printing; the umask-and-rename that installed it is not.
  printf 'atyrode: enrolled %s with %s (token at %s)\n' \
    "$machine_name" "$master_url" "$token_path" >&2
  printf 'atyrode: start the agent with: systemctl --user start manifold-agent\n' >&2
  manifold_render_status
}

manifold_service() {
  local verb="$1" systemctl
  systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)" ||
    die "$EX_UNAVAILABLE" "systemctl is unavailable; manifold-agent service control requires systemd"
  run_visible "$systemctl" --user "$verb" manifold-agent.service
}

cmd_runtime_manifold() {
  local verb="$1"
  shift
  case "$verb" in
    provision)
      guard_production_mutation "runtime provision manifold-agent"
      manifold_provision "$@"
      ;;
    status)
      if [[ "${1:-}" == --json ]]; then manifold_status_json; else manifold_render_status; fi
      ;;
    start | stop | restart)
      guard_production_mutation "runtime $verb manifold-agent"
      manifold_service "$verb"
      ;;
    *) die "$EX_USAGE" "manifold-agent expects provision, status, start, stop, or restart" ;;
  esac
}

cmd_runtime() {
  # `runtime list` enumerates *launchable model runtimes* only: it is what
  # `code` renders in its runtime dial (CODE_RUNTIME_BROKER=atyrode). The
  # manifold capability is a PTY service daemon that hosts no model, so it
  # routes here for provision/status/start/stop/restart but MUST NOT appear
  # in that list — see checks/atyrode-runtime.nix, which asserts it.
  if [[ "${2:-}" == manifold-agent ]]; then
    local verb="${1:-}"
    shift 2
    cmd_runtime_manifold "$verb" "$@"
  else
    exec "$atyrode_runtime" "$@"
  fi
}
