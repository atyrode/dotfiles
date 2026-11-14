# shellcheck shell=bash
# The dev-only system boundary declares applicability. No fleet capability,
# optional provisioning offer, product admission rule or Docker reconfiguration.

manifold_isolates_applicable() {
  local host
  host="$(resolve_host)"
  jq -e --arg host "$host" '.hostChecks[$host] // [] | index("manifold-dev-isolates") != null' \
    "$system_policy" >/dev/null
}

manifold_isolates_status_json() {
  local systemctl helper active control_group inspection reason
  reason="the declared holder or its user manager is unavailable; apply the dev machine configuration"
  if systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)" &&
    helper="$(command -v manifold-dev-isolates)"; then
    active="$("$systemctl" --user show --value --property=ActiveState manifold-dev-isolates.service 2>/dev/null || true)"
    control_group="$("$systemctl" --user show --value --property=ControlGroup manifold-dev-isolates.service 2>/dev/null || true)"
    if [[ "$active" == active && -n "$control_group" ]]; then
      if inspection="$("$helper" status --control-group "$control_group")"; then
        printf '%s\n' "$inspection"
        return 0
      fi
      if jq -e '.ready == false and (.reason | type == "string")' <<<"$inspection" >/dev/null 2>&1; then
        printf '%s\n' "$inspection"
        return 0
      fi
      reason="the delegated slice could not be inspected"
    else
      reason="the retained holder is not active; inspect its user journal before provisioning"
    fi
  fi
  jq -nc --arg reason "$reason" '{ready:false,reason:$reason}'
}

cmd_runtime_manifold_isolates() {
  local verb="$1" systemctl status
  shift
  manifold_isolates_applicable ||
    die "$EX_UNAVAILABLE" "manifold-dev-isolates is owned only by the declared dev machine"
  case "$verb" in
    status)
      [[ $# == 0 || ( $# == 1 && "$1" == --json ) ]] || die "$EX_USAGE" "status accepts only --json"
      status="$(manifold_isolates_status_json)"
      if [[ "${1:-}" == --json ]]; then
        printf '%s\n' "$status"
      else
        jq -r 'if .ready then "manifold-dev-isolates: ready at " + .path else "manifold-dev-isolates: " + .reason end' <<<"$status"
      fi
      ;;
    provision | start)
      [[ $# == 0 ]] || die "$EX_USAGE" "manifold-dev-isolates provision accepts no options"
      guard_production_mutation "runtime $verb manifold-dev-isolates"
      activation_lock
      systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)" ||
        die "$EX_UNAVAILABLE" "systemctl is unavailable; this runtime requires the declared user manager"
      [[ -x /run/current-system/sw/bin/manifold-dev-isolates-provision ]] ||
        die "$EX_UNAVAILABLE" "the scoped provisioner is not installed; apply the dev machine configuration"
      run_visible "$systemctl" --user start manifold-dev-isolates.service ||
        die "$EX_UNAVAILABLE" "holder start failed; inspect journalctl --user -u manifold-dev-isolates.service"
      # sudo is the existing operator elevation boundary, not a new passwordless
      # broker. The root-owned command takes no caller-selected path or identity.
      run_visible sudo /run/current-system/sw/bin/manifold-dev-isolates-provision ||
        die "$EX_UNAVAILABLE" "scoped delegation did not converge; clear the provisioner's reported boundary before retrying"
      status="$(manifold_isolates_status_json)"
      jq -e '.ready == true' <<<"$status" >/dev/null ||
        die "$EX_UNAVAILABLE" "delegation remains incomplete: $(jq -r '.reason' <<<"$status")"
      ;;
    stop | restart)
      [[ $# == 0 ]] || die "$EX_USAGE" "owner service control accepts no options"
      guard_production_mutation "runtime $verb manifold-dev-isolates"
      activation_lock
      # The same owning policy as apply, not a sampled count or a hidden force.
      disruption_mutation_guard user:manifold-dev-isolates.service "$verb" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/manifold-dev-isolates.service"
      systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)" ||
        die "$EX_UNAVAILABLE" "systemctl is unavailable"
      run_visible "$systemctl" --user "$verb" manifold-dev-isolates.service
      ;;
    *) die "$EX_USAGE" "manifold-dev-isolates expects status, provision, or start; owner stop/restart is protected" ;;
  esac
}

probe_manifold_isolates() {
  local inspection status=incomplete code=delegation-incomplete
  if has_system_fixture; then
    inspection="$(jq -c '.manifoldIsolates // {ready:false,reason:"delegation inspection unavailable"}' <<<"$system_fixture")"
  else
    inspection="$(manifold_isolates_status_json)"
  fi
  if [[ "$(jq -r '.ready' <<<"$inspection")" == true ]]; then
    status=ok
    code=""
  fi
  system_check_add manifold-dev-isolates atyrode true "$status" "$code" \
    "$(jq -r 'if .ready then "the retained dev slice and scoped UID grant are ready" else .reason end' <<<"$inspection")" \
    "atyrode runtime provision manifold-dev-isolates (does not restart the holder or any container)" \
    '{"controllers":["cpu","memory","pids"],"containerUid":1000,"containerGid":1000}' "$inspection"
}
