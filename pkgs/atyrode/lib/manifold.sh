# shellcheck shell=bash
#
# manifold-agent fleet enrolment, and the runtime dispatch that reaches it.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# --- manifold-agent runtime --------------------------------------------------
# Fleet enrollment for the self-hosted manifold hub (#418). The committed
# fleet/manifold.json owns master discovery. The hub's owner key is a shared
# clan var no machine receives, and each machine's token is a clan var placed
# at activation behind ~/.config/manifold/machine.token: enrolling is done on
# an operator device (`runtime enroll`), and a machine only ever starts the
# agent that reads what was placed for it (`runtime provision`). No machine
# holds the owner key and nothing here opens a vault.

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
  stat -L -c %a "$1" 2>/dev/null || stat -L -f %Lp "$1" 2>/dev/null
}
# The token is what activation placed, read through the link Home Manager
# keeps at the path the units name. Only the file at the end of the link is
# judged, because the link and its directory are Home Manager's; a dangling
# link is the unenrolled state and a placed file is 0600 by declaration.
manifold_enrolled() {
  local token_path
  token_path="$(manifold_token_path)"
  [[ -f "$token_path" && -s "$token_path" && "$(manifold_token_mode "$token_path")" == 600 ]]
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

# On the machine, provisioning is starting the agent for a token activation
# has placed. It never mints: the owner key that could is not on this machine
# by design, so a missing token names the operator-device ceremony instead.
manifold_provision() {
  [[ $# -eq 0 ]] || die "$EX_USAGE" "unknown manifold-agent provision option: $1"
  manifold_system_supported ||
    die "$EX_UNAVAILABLE" "manifold-agent has no declared release for $(actual_system)"
  command -v manifold-agent >/dev/null 2>&1 ||
    die "$EX_UNAVAILABLE" "the manifold-node capability is not installed on this machine"
  local host
  host="$(manifold_node_name)"
  manifold_enrolled ||
    die "$EX_NOINPUT" "no machine token is placed at $(manifold_token_path); on an operator device run: atyrode runtime enroll manifold-agent $host, then atyrode apply here"
  manifold_start || return $?
  manifold_fail_if_rejected || return $?
  printf 'atyrode: %s is enrolled and its agent is running\n' "$host" >&2
  manifold_render_status
}

# On an operator device, enrolling asks the hub for a machine's token and
# stores it as that machine's clan var, so the next apply on the machine
# places it. The owner key is read from clan's shared custody, decrypted with
# this device's operator key, and travels only through a 0600 curl config in a
# secure temp dir -- never argv, never a machine. A token this device already
# holds as a plain file, from before the token was a clan var, is adopted
# rather than re-minted, so the cutover rotates nothing.
manifold_enroll() { # host [--rotate-token]
  local host="" rotate=0 arg
  for arg in "$@"; do
    case "$arg" in
      --rotate-token) rotate=1 ;;
      -*) die "$EX_USAGE" "unknown manifold-agent enroll option: $arg" ;;
      *)
        [[ -z "$host" ]] || die "$EX_USAGE" "manifold-agent enroll takes one host"
        host="$arg"
        ;;
    esac
  done
  [[ -n "$host" ]] || die "$EX_USAGE" "manifold-agent enroll needs the host to enroll: atyrode runtime enroll manifold-agent <host>"
  host="$(resolve_host "$host")"
  jq -e --arg host "$host" '.spokes | index($host) != null' "$manifold_inventory" >/dev/null ||
    die "$EX_USAGE" "$host is not a Manifold spoke in fleet/manifold.json"
  local clan checkout master_url
  local -a clan_write
  clan="$(clan_program)"
  checkout="$(fleet_repository "")"
  mapfile -t clan_write < <(clan_write_command "$checkout")
  master_url="$(manifold_inventory_field masterUrl)"

  local legacy
  legacy="$(manifold_token_path)"
  if [[ "$rotate" == 0 && "$host" == "$(resolve_host)" && -f "$legacy" && ! -L "$legacy" && -s "$legacy" ]]; then
    say "$host already holds a token from before it was a clan var; adopting it, so nothing is rotated"
    show_rendered "$(render_argv "${clan_write[@]}" vars set "$host" manifold-agent/machine-token --flake "$checkout") < $(printf '%q' "$legacy")"
    "${clan_write[@]}" vars set "$host" manifold-agent/machine-token --flake "$checkout" <"$legacy" ||
      die "$EX_SOFTWARE" "clan did not store $host's machine token"
    say "review the commit clan made in $checkout, then push it; apply on $host places the token behind the file it already reads"
    return 0
  fi

  # Rotation revokes the token the running agent holds, and that agent is on
  # another machine, or is this one: either way the operator is told what the
  # revocation ends before the hub is asked for it.
  [[ "$rotate" == 0 ]] ||
    say "rotating revokes $host's current token: an agent still using it is fenced off the hub until the new token is placed and the agent restarted"

  local scratch
  scratch="$(vault_secure_temp_dir atyrode-manifold)"
  manifold_enroll_cleanup() { rm -rf -- "${scratch:-}"; }
  trap manifold_enroll_cleanup EXIT HUP INT TERM

  show_command "$clan" vars get "$host" manifold-custody/owner-key --flake "$checkout"
  "$clan" vars get "$host" manifold-custody/owner-key --flake "$checkout" >"$scratch/owner.key" 2>"$scratch/owner.err" ||
    die "$EX_NOINPUT" "clan holds no Manifold owner key yet; on an operator device run: clan vars generate $host --generator manifold-custody (it prompts for the hub's owner key once, and no machine receives it)"
  [[ -s "$scratch/owner.key" ]] ||
    die "$EX_DATAERR" "manifold-custody/owner-key is empty"
  printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '[:space:]' <"$scratch/owner.key")" \
    >"$scratch/curl.cfg" || die "$EX_UNAVAILABLE" "could not prepare the protected enrollment request"

  local fetch payload response token denial
  fetch="$(optional_host_command ATYRODE_FETCH curl)" ||
    die "$EX_UNAVAILABLE" "curl is required to enroll with the manifold master"
  payload="$(jq -nc --arg name "$host" --argjson rotate "$([[ "$rotate" == 1 ]] && printf true || printf false)" \
    '{name:$name} + (if $rotate then {rotateToken:true} else {} end)')"
  response="$scratch/response.json"
  run_visible "$fetch" -fsSL --config "$scratch/curl.cfg" -X POST \
    -H 'content-type: application/json' -d "$payload" \
    -o "$response" "$master_url/api/actions/core.machines.enroll" ||
    die "$EX_UNAVAILABLE" "could not enroll with the manifold master at $master_url"
  # Enrollment is an action: the answer is HTTP 200 either way, and a refusal
  # is `ok: false` carrying the rule that refused, which is what the operator
  # needs to read.
  if ! jq -e '.ok == true and (.result | type == "object")' "$response" >/dev/null; then
    denial="$(jq -r '.denial | select(type == "object") | "\(.rule): \(.message)"' "$response" 2>/dev/null || true)"
    die "$EX_UNAVAILABLE" "the manifold master refused to enroll $host${denial:+ ($denial)}; no token was stored"
  fi
  token="$(jq -er '.result.machineToken // "" | strings' "$response")" ||
    die "$EX_DATAERR" "Manifold enrollment returned an invalid machine token"
  if [[ -z "$token" ]]; then
    die "$EX_DATAERR" "machine '$host' is already enrolled and the master mints no token on re-enrollment; recover a lost token with --rotate-token (this fences any agent still using the old token)"
  fi
  # The token reaches clan on stdin: the announced line says where it goes,
  # and the value never appears in it.
  show_rendered "$(render_argv "${clan_write[@]}" vars set "$host" manifold-agent/machine-token --flake "$checkout") < (the minted token)"
  printf '%s\n' "$token" | "${clan_write[@]}" vars set "$host" manifold-agent/machine-token --flake "$checkout" ||
    die "$EX_SOFTWARE" "the master minted a token for $host but clan did not store it; it is lost, so rerun with --rotate-token"
  token=""
  manifold_enroll_cleanup
  trap - EXIT HUP INT TERM
  say "enrolled $host with $master_url; review the commit clan made in $checkout, then push it"
  if [[ "$rotate" == 1 ]]; then
    say "on $host: atyrode apply places the new token, then atyrode runtime restart manifold-agent loads it"
  else
    say "on $host: atyrode apply places the token and starts the agent"
  fi
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
      activation_lock
      manifold_provision "$@" || return $?
      provisioning_clear_decline manifold-agent
      ;;
    enroll)
      guard_production_mutation "runtime enroll manifold-agent"
      manifold_enroll "$@"
      ;;
    status)
      if [[ "${1:-}" == --json ]]; then manifold_status_json; else manifold_render_status; fi
      ;;
    start | stop | restart)
      guard_production_mutation "runtime $verb manifold-agent"
      activation_lock
      manifold_service "$verb"
      ;;
    *) die "$EX_USAGE" "manifold-agent expects provision, enroll, status, start, stop, or restart" ;;
  esac
}

cmd_runtime() {
  # `runtime list` enumerates *launchable model runtimes* only: it is what
  # `code` renders in its runtime dial (CODE_RUNTIME_BROKER=atyrode). The
  # manifold capability is a PTY service daemon that hosts no model, so it
  # routes here for provision/enroll/status/start/stop/restart but MUST NOT appear
  # in that list — see checks/atyrode/atyrode-runtime.nix, which asserts it.
  if [[ "${2:-}" == manifold-agent ]]; then
    local verb="${1:-}"
    shift 2
    cmd_runtime_manifold "$verb" "$@"
  else
    exec "$atyrode_runtime" "$@"
  fi
}
