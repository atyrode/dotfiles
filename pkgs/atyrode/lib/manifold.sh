# shellcheck shell=bash
#
# manifold-agent fleet enrolment, and the runtime dispatch that reaches it.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# --- manifold-agent runtime --------------------------------------------------
# Fleet enrollment for the self-hosted manifold hub (#418). The committed
# fleet/manifold.json owns master discovery; the vault holds only the
# owner key, read once during interactive provisioning. The running agent
# authenticates with a 0600 machine token file and never touches the vault.

manifold_token_path() {
  # Both native units pin this path: the systemd unit uses %h and launchd
  # receives the same literal path from Home Manager.
  printf '%s/.config/manifold/machine.token\n' "$HOME"
}

manifold_machine_name() {
  # Git provisioning has historically used the kernel hostname in its vault
  # item names. Keep that contract independent from Manifold's node identity.
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_HOSTNAME:-}" ]]; then
    printf '%s\n' "$_ATYRODE_TEST_HOSTNAME"
  else
    hostname
  fi
}

manifold_node_name() {
  # Fixed fleet machines present their canonical registry id. A generic server
  # composition has no registry identity and deliberately falls back to the
  # hostname, preserving that reusable fixture's contract.
  local node
  if node="$(resolve_host 2>/dev/null)" && [[ "$(host_json "$node" | jq -r '.identityMode // "fixed"')" == fixed ]]; then
    printf '%s\n' "$node"
  else
    manifold_machine_name
  fi
}

manifold_inventory_field() {
  jq -er --arg key "$1" '.[$key]' "$manifold_inventory" ||
    die "$EX_SOFTWARE" "fleet/manifold.json lacks $1"
}

manifold_system_supported() {
  jq -e --arg system "$(actual_system)" \
    '.supportedSystems | index($system) != null' "$manifold_inventory" >/dev/null
}

manifold_applicable() {
  manifold_system_supported && command -v manifold-agent >/dev/null 2>&1
}

manifold_token_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}
manifold_prepare_token_directory() {
  local directory
  directory="$(dirname "$(manifold_token_path)")"
  if [[ -e "$directory" || -L "$directory" ]]; then
    [[ -d "$directory" && ! -L "$directory" ]] ||
      die "$EX_DATAERR" "$directory is not a safe Manifold credential directory"
  else
    mkdir -p "$directory" || die "$EX_UNAVAILABLE" "could not create $directory"
  fi
  chmod 700 "$directory" || die "$EX_UNAVAILABLE" "could not secure $directory"
}

manifold_enrolled() {
  local token_path directory
  token_path="$(manifold_token_path)"
  directory="$(dirname "$token_path")"
  [[ -d "$directory" && ! -L "$directory" &&
    -f "$token_path" && ! -L "$token_path" && -s "$token_path" &&
    "$(manifold_token_mode "$token_path")" == 600 &&
    "$(manifold_token_mode "$directory")" == 700 ]]
}

manifold_launchd_label() {
  printf 'org.nix-community.home.manifold-agent\n'
}

manifold_launchd_plist() {
  printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$(manifold_launchd_label)"
}

manifold_launchd_target() {
  printf 'gui/%s/%s\n' "$(id -u)" "$(manifold_launchd_label)"
}

manifold_launchd_log() {
  printf '%s/.local/state/manifold/agent.log\n' "$HOME"
}

# present, manager active state, and manager sub-state. The JSON schema keeps
# the historical unit field names even when the native manager is launchd.
manifold_service_snapshot() {
  local system systemctl launchctl output state pid
  system="$(actual_system)"
  case "$system" in
    *-linux)
      if systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)" &&
        "$systemctl" --user cat manifold-agent.service >/dev/null 2>&1; then
        state="$("$systemctl" --user show -P ActiveState manifold-agent.service 2>/dev/null || printf unknown)"
        pid="$("$systemctl" --user show -P SubState manifold-agent.service 2>/dev/null || printf unknown)"
        printf 'true\t%s\t%s\n' "$state" "$pid"
      else
        printf 'false\tunknown\tunknown\n'
      fi
      ;;
    *-darwin)
      if [[ ! -f "$(manifold_launchd_plist)" ]]; then
        printf 'false\tunknown\tunknown\n'
        return
      fi
      launchctl="$(optional_host_command ATYRODE_LAUNCHCTL launchctl)" || {
        printf 'true\tunknown\tunknown\n'
        return
      }
      if ! output="$("$launchctl" print "$(manifold_launchd_target)" 2>/dev/null)"; then
        printf 'true\tinactive\tunloaded\n'
        return
      fi
      state="$(awk -F'= ' '/^[[:space:]]*state = / { gsub(/[[:space:]]/, "", $2); print $2; exit }' <<<"$output")"
      pid="$(awk -F'= ' '/^[[:space:]]*pid = / { gsub(/[[:space:]]/, "", $2); print $2; exit }' <<<"$output")"
      if [[ "$state" == running && "$pid" =~ ^[1-9][0-9]*$ ]]; then
        printf 'true\tactive\trunning\n'
      else
        printf 'true\tinactive\t%s\n' "${state:-loaded}"
      fi
      ;;
    *) printf 'false\tunknown\tunknown\n' ;;
  esac
}

manifold_last_log_event() {
  local journalctl log output=""
  case "$(actual_system)" in
    *-linux)
      if journalctl="$(optional_host_command ATYRODE_JOURNALCTL journalctl)"; then
        output="$("$journalctl" --user -u manifold-agent -n 80 --no-pager -o cat 2>/dev/null || true)"
      fi
      ;;
    *-darwin)
      log="$(manifold_launchd_log)"
      [[ ! -r "$log" ]] || output="$(tail -n 80 "$log")"
      ;;
  esac
  # A previous welcome cannot establish a current connection after a restart
  # or disconnect. Only inspect structured agent events, never terminal text.
  jq -Rnr '
    reduce inputs as $line ("none";
      (try ($line | fromjson) catch {}) as $event |
      if $event.evt == "welcome" then "welcome"
      elif $event.evt == "protocol_version_rejected" then "rejected"
      elif $event.evt == "disconnected" then
        if ([4401, 4403, 4409] | index($event.code)) != null then "rejected" else "disconnected" end
      elif $event.evt == "liveness_timeout" then "disconnected"
      elif $event.evt == "starting" or $event.evt == "signal" then "none"
      else . end)
  ' <<<"$output"
}

manifold_status_json() {
  local applicable=false reason="" enrolled=false phase=unsupported
  local active_state=unknown sub_state=unknown unit_present=false last_event=none snapshot
  local master_url machine_name token_path system
  master_url="$(manifold_inventory_field masterUrl)"
  machine_name="$(manifold_node_name)"
  token_path="$(manifold_token_path)"
  system="$(actual_system)"
  if manifold_system_supported; then
    if command -v manifold-agent >/dev/null 2>&1; then
      applicable=true
      phase=available
    else
      reason="the manifold-node capability is not installed on this machine"
    fi
  else
    reason="manifold-agent has no declared release for $system"
  fi
  if manifold_enrolled; then
    enrolled=true
    [[ "$applicable" != true ]] || phase=enrolled
  fi
  snapshot="$(manifold_service_snapshot)"
  IFS=$'\t' read -r unit_present active_state sub_state <<<"$snapshot"
  last_event="$(manifold_last_log_event)"
  if [[ "$applicable" == true && "$enrolled" == true &&
    "$active_state" == active && "$sub_state" == running ]]; then
    phase=running
    [[ "$last_event" != welcome ]] || phase=connected
  fi
  if [[ "$applicable" == true && "$enrolled" == true && "$last_event" == rejected ]]; then
    phase=rejected
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
    "  unit: \(if .unit.present then "\(.unit.activeState) (\(.unit.subState))" else "not installed" end)",
    "  connection: \(.lastLogEvent)"'
}

manifold_start() {
  local system systemctl launchctl target plist snapshot present active sub attempt
  manifold_enrolled ||
    die "$EX_DATAERR" "manifold-agent has no secure non-empty token at $(manifold_token_path); enroll it with: atyrode runtime provision manifold-agent"
  system="$(actual_system)"
  case "$system" in
    *-linux)
      systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)" ||
        die "$EX_UNAVAILABLE" "systemctl is unavailable; retry after it is available with: atyrode runtime start manifold-agent"
      "$systemctl" --user cat manifold-agent.service >/dev/null 2>&1 ||
        die "$EX_UNAVAILABLE" "manifold-agent.service is not installed; repair the manifold-node capability, then run: atyrode runtime start manifold-agent"
      active="$("$systemctl" --user show -P ActiveState manifold-agent.service 2>/dev/null || printf unknown)"
      sub="$("$systemctl" --user show -P SubState manifold-agent.service 2>/dev/null || printf unknown)"
      [[ "$active" != active || "$sub" != running ]] || return 0
      if ! run_visible "$systemctl" --user start manifold-agent.service; then
        printf 'atyrode: manifold-agent did not start; retry with: atyrode runtime start manifold-agent\n' >&2
        return "$EX_UNAVAILABLE"
      fi
      ;;
    *-darwin)
      launchctl="$(optional_host_command ATYRODE_LAUNCHCTL launchctl)" ||
        die "$EX_UNAVAILABLE" "launchctl is unavailable; retry after it is available with: atyrode runtime start manifold-agent"
      target="$(manifold_launchd_target)"
      plist="$(manifold_launchd_plist)"
      [[ -f "$plist" ]] ||
        die "$EX_UNAVAILABLE" "the declared Manifold launchd plist is missing at $plist; apply the configuration, then run: atyrode runtime start manifold-agent"
      snapshot="$(manifold_service_snapshot)"
      IFS=$'\t' read -r present active sub <<<"$snapshot"
      [[ "$active" != active || "$sub" != running ]] || return 0
      if [[ "$sub" == unloaded ]]; then
        if ! run_visible "$launchctl" bootstrap "gui/$(id -u)" "$plist"; then
          printf 'atyrode: launchd could not load Manifold; retry with: atyrode runtime start manifold-agent\n' >&2
          return "$EX_UNAVAILABLE"
        fi
        snapshot="$(manifold_service_snapshot)"
        IFS=$'\t' read -r present active sub <<<"$snapshot"
        [[ "$active" != active || "$sub" != running ]] || return 0
      fi
      if ! run_visible "$launchctl" kickstart "$target"; then
        printf 'atyrode: launchd could not start Manifold; retry with: atyrode runtime start manifold-agent\n' >&2
        return "$EX_UNAVAILABLE"
      fi
      ;;
    *) die "$EX_UNAVAILABLE" "manifold-agent is unsupported on $system" ;;
  esac
  # Native managers may acknowledge a start before they have spawned the
  # process. Observe that transition without issuing another start/restart.
  for ((attempt = 0; attempt < 50; attempt++)); do
    snapshot="$(manifold_service_snapshot)"
    IFS=$'\t' read -r present active sub <<<"$snapshot"
    [[ "$active" != active || "$sub" != running ]] || return 0
    sleep 0.1
  done
  printf 'atyrode: manifold-agent is still not running; inspect with: atyrode runtime status manifold-agent\n' >&2
  return "$EX_UNAVAILABLE"
}

manifold_fail_if_rejected() {
  local status phase
  status="$(manifold_status_json)"
  phase="$(jq -r '.phase' <<<"$status")"
  if [[ "$phase" == rejected ]]; then
    printf 'atyrode: the Manifold hub rejected this connection; inspect the agent log and hub protocol with: atyrode runtime status manifold-agent\n' >&2
    printf 'atyrode: a protocol mismatch needs a compatible agent/hub, not token rotation\n' >&2
    return "$EX_UNAVAILABLE"
  fi
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
  manifold_system_supported ||
    die "$EX_UNAVAILABLE" "manifold-agent has no declared release for $(actual_system)"
  command -v manifold-agent >/dev/null 2>&1 ||
    die "$EX_UNAVAILABLE" "the manifold-node capability is not installed on this machine"
  local token_path token_directory token_tmp master_url item_name machine_name
  token_path="$(manifold_token_path)"
  token_directory="$(dirname "$token_path")"
  [[ ! -L "$token_path" ]] ||
    die "$EX_DATAERR" "$token_path must not be a symbolic link"
  manifold_prepare_token_directory
  if [[ "$rotate" == 0 && -e "$token_path" ]]; then
    [[ -f "$token_path" && -s "$token_path" ]] ||
      die "$EX_DATAERR" "$token_path is not a usable machine token; remove the invalid file, then rerun enrollment"
    chmod 600 "$token_path" || die "$EX_UNAVAILABLE" "could not secure $token_path"
    manifold_start || return $?
    manifold_fail_if_rejected || return $?
    printf 'atyrode: %s is already enrolled and its agent is running (token at %s)\n' \
      "$(manifold_node_name)" "$token_path" >&2
    manifold_render_status
    return 0
  fi
  master_url="$(manifold_inventory_field masterUrl)"
  item_name="$(manifold_inventory_field vaultItemName)"
  machine_name="$(manifold_node_name)"
  # Rotation revokes the credential the running process holds, so the agent
  # that follows a rotation is a restarted agent: whether that may happen is
  # decided here, before the master is asked to revoke anything, because a
  # revoked token with a refused restart is an agent fenced off its own hub.
  if [[ "$rotate" == 1 && "$(manifold_service_snapshot)" == $'true\tactive\trunning' ]]; then
    manifold_service_guard restart
  fi

  local scratch
  scratch="$(vault_secure_temp_dir atyrode-manifold)"
  manifold_provision_cleanup() {
    rm -rf -- "${scratch:-}"
    vault_close_session
  }
  trap manifold_provision_cleanup EXIT HUP INT TERM

  # The owner key must never enter argv (world-readable in /proc); it flows
  # from the vault note into a 0600 curl config inside the secure temp dir.
  vault_item_notes "$item_name" "$scratch" >"$scratch/owner.key" ||
    die "$EX_UNAVAILABLE" "could not read the Manifold owner key"
  [[ -s "$scratch/owner.key" ]] ||
    die "$EX_DATAERR" "Bitwarden Secure Note '$item_name' is empty"
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$scratch/owner.key")" \
    >"$scratch/curl.cfg" || die "$EX_UNAVAILABLE" "could not prepare the protected enrollment request"

  local fetch payload response token
  fetch="$(optional_host_command ATYRODE_FETCH curl)" ||
    die "$EX_UNAVAILABLE" "curl is required to enroll with the manifold master"
  payload="$(jq -nc --arg name "$machine_name" --argjson rotate "$([[ "$rotate" == 1 ]] && printf true || printf false)" \
    '{name:$name} + (if $rotate then {rotateToken:true} else {} end)')"
  response="$scratch/response.json"
  run_visible "$fetch" -fsSL --config "$scratch/curl.cfg" -X POST \
    -H 'content-type: application/json' -d "$payload" \
    -o "$response" "$master_url/api/machines" ||
    die "$EX_UNAVAILABLE" "could not enroll with the manifold master at $master_url"
  token="$(jq -r '.machineToken // empty' "$response")"
  trap - EXIT HUP INT TERM
  manifold_provision_cleanup
  if [[ -z "$token" ]]; then
    die "$EX_DATAERR" "machine '$machine_name' is already enrolled and the master mints no token on re-enrollment; recover a lost token with --rotate-token (this fences any agent still using the old token)"
  fi
  token_tmp="$(mktemp "$token_directory/.machine.token.XXXXXX")" ||
    die "$EX_UNAVAILABLE" "could not stage the Manifold machine token"
  if ! printf '%s\n' "$token" >"$token_tmp"; then
    rm -f -- "$token_tmp"
    die "$EX_UNAVAILABLE" "could not write the Manifold machine token"
  fi
  if ! chmod 600 "$token_tmp" || ! mv -f "$token_tmp" "$token_path"; then
    rm -f -- "$token_tmp"
    die "$EX_UNAVAILABLE" "could not install the Manifold machine token"
  fi
  printf 'atyrode: enrolled %s with %s (token at %s)\n' \
    "$machine_name" "$master_url" "$token_path" >&2
  # Explicit rotation revokes the credential held in the running process.
  # Only that explicit request may restart an otherwise healthy agent.
  if [[ "$rotate" == 1 && "$(manifold_service_snapshot)" == $'true\tactive\trunning' ]]; then
    manifold_service restart || return $?
  fi
  manifold_start || return $?
  manifold_fail_if_rejected || return $?
  manifold_render_status
}

# What a stop or restart of the agent would end is judged by the same reading
# every activation gets, before the manager is asked for anything: the agent
# that owns the machine's terminals is refused while it is loaded, and a
# transport that declares it owns nothing restarts freely.
manifold_service_guard() { # verb
  case "$(actual_system)" in
    *-linux)
      disruption_mutation_guard user:manifold-agent.service "$1" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/manifold-agent.service"
      ;;
    *-darwin)
      disruption_mutation_guard "launchd:$(manifold_launchd_label)" "$1" "$(manifold_launchd_plist)"
      ;;
  esac
}

manifold_service() {
  local verb="$1" system systemctl launchctl target
  system="$(actual_system)"
  case "$verb:$system" in
    start:*)
      manifold_start && manifold_fail_if_rejected
      ;;
    stop:*-linux | restart:*-linux)
      systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)" ||
        die "$EX_UNAVAILABLE" "systemctl is unavailable; manifold-agent service control requires systemd"
      manifold_service_guard "$verb"
      run_visible "$systemctl" --user "$verb" manifold-agent.service
      ;;
    stop:*-darwin)
      launchctl="$(optional_host_command ATYRODE_LAUNCHCTL launchctl)" ||
        die "$EX_UNAVAILABLE" "launchctl is unavailable; manifold-agent service control requires launchd"
      manifold_service_guard stop
      target="$(manifold_launchd_target)"
      run_visible "$launchctl" bootout "$target"
      ;;
    restart:*-darwin)
      launchctl="$(optional_host_command ATYRODE_LAUNCHCTL launchctl)" ||
        die "$EX_UNAVAILABLE" "launchctl is unavailable; manifold-agent service control requires launchd"
      manifold_service_guard restart
      run_visible "$launchctl" kickstart -k "$(manifold_launchd_target)"
      ;;
    *) die "$EX_UNAVAILABLE" "manifold-agent is unsupported on $system" ;;
  esac
}

cmd_runtime_manifold() {
  local verb="$1"
  shift
  case "$verb" in
    provision)
      guard_production_mutation "runtime provision manifold-agent"
      manifold_provision "$@" || return $?
      provisioning_clear_decline manifold-agent
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
  # in that list — see checks/atyrode/atyrode-runtime.nix, which asserts it.
  if [[ "${2:-}" == manifold-agent ]]; then
    local verb="${1:-}"
    shift 2
    cmd_runtime_manifold "$verb" "$@"
  else
    exec "$atyrode_runtime" "$@"
  fi
}
