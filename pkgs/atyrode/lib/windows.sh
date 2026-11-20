# shellcheck shell=bash
#
# Native Windows package and reserved Tern tunnel reconciliation from NixOS-WSL.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

windows_environment() {
  [[ "$test_hooks" != 1 || -z "${ATYRODE_WINGET:-}" ]] || return 0
  if [[ -n "${WSLPATH:-}" ]] && command -v cmd.exe >/dev/null 2>&1; then return 0; fi
  local windows_path
  windows_path="$("$lib_dir/../../atyrode-wsl-path")" ||
    die "$EX_UNAVAILABLE" "could not restore this service-launched shell's Windows PATH; check Windows mounts and WSL interop before retrying"
  export WSLPATH="$windows_path"
  export PATH="$PATH:$windows_path"
}

windows_winget() {
  local candidate=winget.exe resolved
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_WINGET:-}" ]]; then
    candidate="$ATYRODE_WINGET"
  else
    command -v cmd.exe >/dev/null 2>&1 ||
      die "$EX_UNAVAILABLE" "Windows PATH context is unavailable in this shell; the managed WSL shell environment has not discovered Windows executables (not evidence that App Installer is missing)"
    cmd.exe /d /c exit 0 </dev/null >/dev/null 2>&1 ||
      die "$EX_UNAVAILABLE" "Windows executables are discoverable but WSL interop execution failed; check the WSL runtime and this shell's WSL_INTEROP context"
  fi
  resolved="$(command -v "$candidate" 2>/dev/null)" ||
    die "$EX_UNAVAILABLE" "Windows interop works, but winget.exe is not on Windows PATH; repair Windows App Installer or its App Execution Alias"
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

windows_tunnel_unknown() {
  jq -nc --arg detail "$1" '{status:"unknown",publicKey:null,enrolled:false,detail:$detail}'
}

windows_tunnel() { # Plan|Apply
  local mode="$1" output status=0
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_TERN_TUNNEL:-}" ]]; then
    [[ "$mode" != Apply ]] || show_command "$windows_tunnel_exe" "$mode"
    output="$("$ATYRODE_TERN_TUNNEL" "$windows_tunnel_exe" "$mode" </dev/null)" || status=$?
  else
    if [[ ! -x "$windows_tunnel_exe" ]]; then
      windows_tunnel_unknown 'this atyrode package has no executable native Tern tunnel helper'
      return
    fi
    local binfmt=/proc/sys/fs/binfmt_misc interpreter
    # NixOS registers its /run/binfmt/WSLInterop symlink; WSL itself may
    # register /init directly. Compare the interpreter, not its spelling.
    interpreter="$(awk '$1 == "interpreter" { print $2 }' "$binfmt/WSLInterop" 2>/dev/null)" || interpreter=
    if ! grep -qx enabled "$binfmt/status" 2>/dev/null ||
      ! grep -qx enabled "$binfmt/WSLInterop" 2>/dev/null ||
      [[ ! "$interpreter" -ef /init ]]; then
      windows_tunnel_unknown 'WSLInterop binfmt is not enabled with /init; repair WSL interop before retrying'
      return
    fi
    # WSLInterop launches the immutable PE in place; Windows still controls
    # execution and elevation. Only the fixed operation crosses on argv.
    [[ "$mode" != Apply ]] || show_command "$windows_tunnel_exe" "$mode"
    output="$("$windows_tunnel_exe" "$mode" </dev/null)" || status=$?
  fi
  jq -cse --arg mode "$mode" --argjson exitCode "$status" \
    --slurpfile manifest "${windows_tunnel_exe%.exe}.json" '
    if length == 1 then .[0] else empty end
    | select(type == "object" and keys == ["detail","enrolled","publicKey","status"])
    | select(.status as $status | ["missing","change","configured","inspect","client-missing","blocked"] | index($status) != null)
    | select(.status != "client-missing" or ($mode == "Plan" and .publicKey == null))
    | select(.detail | type == "string" and length > 0)
    | select(.publicKey == null or (.publicKey | type == "string" and length == 44 and test("^[A-Za-z0-9+/]{43}=$")))
    | select((.enrolled | type == "boolean") and (.status != "configured" or .publicKey != null))
    | select(if .publicKey != null and (.status == "configured" or .status == "change") then
        if $manifest[0].expectedPublicKey == null then .enrolled == false
        else .enrolled and .publicKey == $manifest[0].expectedPublicKey end
      else .enrolled == false end)
    | if $exitCode != 0 and .status != "blocked" and ($mode != "Apply" or .status != "inspect") then
        .status = "unknown" | .enrolled = false | .publicKey = null
      else . end
  ' <<<"$output" 2>/dev/null ||
    windows_tunnel_unknown "native Tern tunnel $mode returned no valid public status (exit $status); check WSL interop and Windows App Control"
}

windows_with_tunnel() {
  jq -c --argjson tunnel "$2" '
    .tunnel = $tunnel
    | .ready = (all(.packages[]; .status != "blocked") and ($tunnel.status != "blocked" and $tunnel.status != "unknown"))
    | .canApply = (.ready and ($tunnel.status as $status | ["missing","change","configured"] | index($status) != null))
    | .nativeConverged = (all(.packages[]; .status == "installed") and $tunnel.status == "configured")
    | .enrollmentPending = ($tunnel.publicKey != null and
        ($tunnel.status == "configured" or $tunnel.status == "change") and ($tunnel.enrolled | not))
    | .converged = (.nativeConverged and $tunnel.enrolled)
  ' <<<"$1"
}

windows_plan() {
  local host="$1"
  doctor_host "$host" 1 >/dev/null ||
    die "$EX_DATAERR" "host identity does not match the registered NixOS-WSL host $host"
  windows_inventory_plan "$host"
}

windows_inventory_plan() { # host, after caller identity check
  local host="$1" data winget winget_version package id name installed status remediation
  local rows='[]' conflicts conflict_id packages tunnel
  data="$(host_json "$host")"
  [[ "$(jq -r '.activation' <<<"$data")" == nixos-wsl ]] ||
    die "$EX_USAGE" "Windows reconciliation is owned only by a registered nixos-wsl host"
  is_wsl ||
    die "$EX_UNAVAILABLE" "Windows reconciliation requires a live WSL session"
  windows_environment
  jq -e '
    .schemaVersion == 2
    and (.packages | type == "array" and length > 0)
    and all(.packages[];
      (.id | type == "string" and length > 0)
      and (.name | type == "string" and length > 0)
      and (.versionPolicy | type == "string" and length > 0)
      and (.mutableStateOwner | type == "string" and length > 0)
      and (.installVersion == null or (.installVersion | type == "string" and length > 0))
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
  packages="$(jq -nc --arg host "$host" --arg backend "$winget" --arg wingetVersion "$winget_version" --argjson packages "$rows" '{
    schemaVersion: 2, command: "windows plan", host: $host, backend: $backend,
    wingetVersion: $wingetVersion,
    changes: [$packages[] | select(.status != "installed")] | length, packages: $packages,
    transactional: false,
    mutationBoundary: "Native Windows package and tunnel state are outside Nix generations and rollback"
  }')"
  tunnel="$(windows_tunnel Plan)"
  windows_with_tunnel "$packages" "$tunnel"
}

windows_render_plan() {
  jq -r '
    "windows backend: \(.backend) (\(.wingetVersion))",
    (.packages[] | "  \(.status): \(.name) [\(.id)]"
      + (if (.detectedConflicts | length) > 0 then "\n    conflicts: \(.detectedConflicts | join(", "))\n    remediation: \(.remediation)" else "" end)),
    "  Tern tunnel: \(.tunnel.status) — \(.tunnel.detail)",
    (if .tunnel.publicKey != null then "  Tern public key: \(.tunnel.publicKey)" else empty end),
    (if .enrollmentPending then "  Tern enrollment: pending; add the public key to the reviewed Windows peer inventory"
     elif .tunnel.enrolled then "  Tern enrollment: registered" else "  Tern enrollment: not verified" end),
    "windows package changes: \(.changes)", "transactional: no -- \(.mutationBoundary)"' <<<"$1"
}

windows_emit() {
  if [[ "$2" == 1 ]]; then printf '%s\n' "$1"; else windows_render_plan "$1"; fi
}

# Unlike context rendering, native readiness cannot be inferred using the
# launcher's inventory or its pinned tunnel manifest.
windows_candidate_cli() { # candidate user
  local program
  if ! program="$(activated_atyrode "$1" "$2")" || [[ "$program" != "$1/"* ]]; then
    die "$EX_UNAVAILABLE" "candidate $1 has no atyrode executable to preflight native Windows"
  fi
  printf '%s\n' "$program"
}

windows_candidate_plan() { # candidate-cli host
  local report status=0
  report="$("$1" windows plan "$2" --json)" || status=$?
  # A blocked probe can still explain the refusal. Older CLI releases did
  # not prove elevation for a fresh tunnel and lack the canApply field.
  jq -cse --arg host "$2" --argjson status "$status" '
    select(length == 1) | .[0]
    | select(.schemaVersion == 2 and .command == "windows plan" and .host == $host
      and .ready == ($status == 0) and (.canApply | type == "boolean")
      and (.ready or (.canApply | not)))
  ' <<<"$report" ||
    die "$EX_UNAVAILABLE" "candidate Windows preflight did not report native mutation readiness; nothing was activated"
}

windows_install_package() { # winget package
  local winget="$1" package="$2" id version
  local -a install_args
  id="$(jq -r '.id' <<<"$package")"
  version="$(jq -r '.installVersion // empty' <<<"$package")"
  install_args=(
    install --id "$id" --exact --source winget
    --accept-package-agreements --accept-source-agreements --disable-interactivity
  )
  [[ -z "$version" ]] || install_args+=(--version "$version")
  show_command "$winget" "${install_args[@]}"
  "$winget" "${install_args[@]}" </dev/null >&2
}

windows_reconcile() {
  local action="$1" host="$2" json="$3" plan winget package tunnel final repair_package
  plan="$(windows_plan "$host")"
  if [[ "$action" == plan ]]; then
    windows_emit "$plan" "$json"
    jq -e '.ready' <<<"$plan" >/dev/null || return "$EX_UNAVAILABLE"
    return 0
  fi
  # A retained profile with an unavailable client is not safe to activate
  # against. Standalone reconciliation can restore the declared client only,
  # then repeat the protected identity and conflict checks before continuing.
  if repair_package="$(jq -ce '
    select(.ready and .tunnel.status == "client-missing")
    | [.packages[] | select(.id == "WireGuard.WireGuard" and .source == "winget" and .status == "missing")]
    | select(length == 1) | .[0]
  ' <<<"$plan")"; then
    winget="$(windows_winget)"
    printf 'atyrode: restoring the native WireGuard client before verifying the retained Tern identity\n' >&2
    windows_install_package "$winget" "$repair_package" || return "$EX_SOFTWARE"
    plan="$(windows_plan "$host")"
    if ! jq -e '.canApply and (.tunnel.publicKey != null)
      and (.tunnel.status == "configured" or .tunnel.status == "change")
      and any(.packages[]; .id == "WireGuard.WireGuard" and .status == "installed")' <<<"$plan" >/dev/null; then
      windows_emit "$plan" "$json"
      return "$EX_UNAVAILABLE"
    fi
  fi
  if ! jq -e '.canApply' <<<"$plan" >/dev/null; then
    windows_emit "$plan" "$json"
    return "$EX_UNAVAILABLE"
  fi
  if jq -e '.changes > 0' <<<"$plan" >/dev/null; then
    winget="$(windows_winget)"
    printf 'atyrode: reconciling native Windows packages through WSL interop (non-transactional)\n' >&2
    while IFS= read -r package; do
      windows_install_package "$winget" "$package" || return "$EX_SOFTWARE"
    done < <(jq -c '.packages[] | select(.source == "winget" and .status == "missing")' <<<"$plan")
    plan="$(windows_plan "$host")"
    if ! jq -e '.canApply and .changes == 0' <<<"$plan" >/dev/null; then
      windows_emit "$plan" "$json"
      return "$EX_UNAVAILABLE"
    fi
  fi
  # Do not replace Apply's proof with a Plan that lacks permission to read
  # protected state. In particular, "inspect" never proves convergence.
  tunnel="$(windows_tunnel Apply)"
  final="$(windows_with_tunnel "$plan" "$tunnel")"
  windows_emit "$final" "$json"
  jq -e '.ready' <<<"$final" >/dev/null || return "$EX_UNAVAILABLE"
  jq -e '.nativeConverged' <<<"$final" >/dev/null || return "$EX_SOFTWARE"
}

cmd_windows() {
  local action="${1:-}" requested="" json=0 host
  # The verified stock guest does not have the managed Linux user or hostname
  # yet. Its root can inspect native state, never reconcile it via this path.
  if [[ "$action" == bootstrap-preflight ]]; then
    [[ $# == 2 && "$2" == --json ]] ||
      die "$EX_USAGE" "windows bootstrap-preflight requires --json and accepts no host"
    [[ "$EUID" == 0 ]] || die "$EX_DATAERR" "Windows bootstrap preflight requires guest root"
    local plan
    plan="$(windows_inventory_plan wsl)" || return $?
    printf '%s\n' "$plan"
    jq -e '.ready' <<<"$plan" >/dev/null || return "$EX_UNAVAILABLE"
    return 0
  fi
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
