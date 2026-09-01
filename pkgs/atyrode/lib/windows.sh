# shellcheck shell=bash
#
# Native Windows package reconciliation from NixOS-WSL.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

windows_winget() {
  local candidate=winget.exe resolved
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_WINGET:-}" ]]; then
    candidate="$ATYRODE_WINGET"
  fi
  resolved="$(command -v "$candidate" 2>/dev/null)" ||
    die "$EX_UNAVAILABLE" "winget.exe is unavailable through WSL interop; repair Windows App Installer and WSL PATH interop"
  printf '%s\n' "$resolved"
}

windows_package_present() {
  local winget="$1" id="$2" status
  if "$winget" list --id "$id" --exact --accept-source-agreements --disable-interactivity \
    </dev/null >/dev/null 2>&1; then
    return 0
  else
    status=$?
  fi
  # WinGet reports APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND as
  # 0x8A150014. WSL exposes the low byte through the POSIX exit status.
  [[ "$status" == 20 ]] && return 1
  die "$EX_UNAVAILABLE" "winget.exe could not query installed package $id (exit $status); repair App Installer or its sources"
}

windows_plan() {
  local host="$1" data winget winget_version package id name installed status remediation
  local rows='[]' conflicts conflict_id
  doctor_host "$host" 1 >/dev/null ||
    die "$EX_DATAERR" "host identity does not match the registered NixOS-WSL host $host"
  data="$(host_json "$host")"
  [[ "$(jq -r '.activation' <<<"$data")" == nixos-wsl ]] ||
    die "$EX_USAGE" "Windows reconciliation is owned only by a registered nixos-wsl host"
  is_wsl ||
    die "$EX_UNAVAILABLE" "Windows reconciliation requires a live WSL session"
  jq -e '
    .schemaVersion == 2
    and (.packages | type == "array" and length > 0)
    and all(.packages[];
      (.id | type == "string" and length > 0)
      and (.name | type == "string" and length > 0)
      and (.versionPolicy | type == "string" and length > 0)
      and (.mutableStateOwner | type == "string" and length > 0)
      and (.source == "winget")
      and (.conflicts | type == "array"))
  ' "$windows_package_inventory" >/dev/null ||
    die "$EX_SOFTWARE" "embedded Windows package inventory is invalid"
  winget="$(windows_winget)"
  winget_version="$("$winget" --version 2>/dev/null | awk 'NR == 1 { gsub(/\r/, ""); print; exit }')" ||
    die "$EX_UNAVAILABLE" "winget.exe could not report its version through WSL interop"
  [[ -n "$winget_version" ]] ||
    die "$EX_UNAVAILABLE" "winget.exe returned an empty version through WSL interop"
  while IFS= read -r package; do
    id="$(jq -r '.id' <<<"$package")"
    name="$(jq -r '.name' <<<"$package")"
    installed=false
    windows_package_present "$winget" "$id" && installed=true
    conflicts='[]'
    while IFS= read -r conflict_id; do
      [[ -n "$conflict_id" ]] || continue
      if windows_package_present "$winget" "$conflict_id"; then
        conflicts="$(jq -nc --argjson current "$conflicts" --arg id "$conflict_id" '$current + [$id]')"
      fi
    done < <(jq -r '.conflicts[]?' <<<"$package")
    remediation=""
    if [[ "$(jq -r 'length' <<<"$conflicts")" -gt 0 ]]; then
      status=blocked
      remediation="fully close Zen, back up its profile, then explicitly uninstall the stable Zen package before applying Twilight"
    elif [[ "$installed" == true ]]; then status=installed; else status=missing; fi
    rows="$(jq -nc --argjson rows "$rows" --argjson package "$package" --argjson installed "$installed" --argjson conflicts "$conflicts" --arg status "$status" --arg remediation "$remediation" '$rows + [$package + {installed:$installed,status:$status,detectedConflicts:$conflicts,remediation:$remediation}]')"
  done < <(jq -c '.packages[]' "$windows_package_inventory")
  jq -nc --arg host "$host" --arg backend "$winget" --arg wingetVersion "$winget_version" --argjson packages "$rows" '{
    schemaVersion: 2, command: "windows plan", host: $host, backend: $backend,
    wingetVersion: $wingetVersion, ready: all($packages[]; .status != "blocked"),
    converged: all($packages[]; .status == "installed"),
    changes: [$packages[] | select(.status != "installed")] | length, packages: $packages,
    transactional: false,
    mutationBoundary: "WinGet package state is native Windows state; Nix generations and rollback do not cover it"
  }'
}

windows_render_plan() {
  jq -r '
    "windows backend: \(.backend) (\(.wingetVersion))",
    (.packages[] | "  \(.status): \(.name) [\(.id)]"
      + (if (.detectedConflicts | length) > 0 then "\n    conflicts: \(.detectedConflicts | join(", "))\n    remediation: \(.remediation)" else "" end)),
    "windows changes: \(.changes)", "transactional: no -- \(.mutationBoundary)"' <<<"$1"
}

windows_reconcile() {
  local action="$1" host="$2" json="$3" plan winget package id source status final
  plan="$(windows_plan "$host")"
  if [[ "$action" == plan ]]; then
    if [[ "$json" == 1 ]]; then printf '%s\n' "$plan"; else windows_render_plan "$plan"; fi
    jq -e '.ready' <<<"$plan" >/dev/null || return "$EX_UNAVAILABLE"
    return 0
  fi
  if ! jq -e '.ready' <<<"$plan" >/dev/null; then
    if [[ "$json" == 1 ]]; then printf '%s\n' "$plan"; else windows_render_plan "$plan"; fi
    return "$EX_UNAVAILABLE"
  fi
  if jq -e '.converged' <<<"$plan" >/dev/null; then
    if [[ "$json" == 1 ]]; then printf '%s\n' "$plan"; else windows_render_plan "$plan"; fi
    return 0
  fi
  winget="$(windows_winget)"
  printf 'atyrode: reconciling native Windows packages through WSL interop (non-transactional)\n' >&2
  while IFS= read -r package; do
    source="$(jq -r '.source' <<<"$package")"
    status="$(jq -r '.status' <<<"$package")"
    if [[ "$source" == winget && "$status" == missing ]]; then
      id="$(jq -r '.id' <<<"$package")"
      # Native Windows state, fetched over the network and outside every Nix
      # generation, so the argv that changes it is the operator's to see.
      show_command "$winget" install --id "$id" --exact --source winget \
        --accept-package-agreements --accept-source-agreements --disable-interactivity
      "$winget" install --id "$id" --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity </dev/null >&2 ||
        return "$EX_SOFTWARE"
    fi
  done < <(jq -c '.packages[] | select(.status != "installed")' <<<"$plan")
  final="$(windows_plan "$host")"
  jq -e '.ready and .converged' <<<"$final" >/dev/null || return "$EX_SOFTWARE"
  if [[ "$json" == 1 ]]; then printf '%s\n' "$final"; else windows_render_plan "$final"; fi
}

cmd_windows() {
  local action="${1:-}" requested="" json=0 host
  case "$action" in
    plan | apply) shift ;;
    *) die "$EX_USAGE" "windows expects plan or apply" ;;
  esac
  if [[ $# -gt 0 && "$1" != --* ]]; then
    requested="$1"
    shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;
      *) die "$EX_USAGE" "unknown windows option: $1" ;;
    esac
    shift
  done
  [[ "$action" != apply ]] || guard_production_mutation "windows apply"
  host="$(resolve_host "$requested")"
  windows_reconcile "$action" "$host" "$json"
}
