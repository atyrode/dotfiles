# shellcheck shell=bash
#
# Diagnostics. Every family here observes and none of them mutate; that
# rule is asserted structurally in checks/atyrode-apply.nix.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

doctor_host() {
  local requested="${1:-}" json="${2:-0}" host data system user home hostname identity_mode ok=true
  host="$(resolve_host "$requested")"
  data="$(host_json "$host")"
  system="$(actual_system)"
  user="$(actual_user)"
  home="$(actual_home)"
  hostname="$(actual_hostname)"
  identity_mode="$(jq -r '.identityMode // "fixed"' <<<"$data")"
  [[ "$(jq -r '.system' <<<"$data")" == "$system" ]] || ok=false
  [[ "$(jq -r '.username' <<<"$data")" == "$user" ]] || ok=false
  [[ "$identity_mode" != runtime || "$(jq -r '.homeDirectory' <<<"$data")" == "$home" ]] || ok=false
  local expected_hostname
  expected_hostname="$(jq -r '.hostname // empty' <<<"$data")"
  [[ -z "$expected_hostname" || "$expected_hostname" == "$hostname" ]] || ok=false

  if [[ "$json" == 1 ]]; then
    jq -nc --arg host "$host" --arg system "$system" --arg user "$user" --arg home "$home" \
      --arg hostname "$hostname" --argjson registered "$data" --argjson ok "$ok" \
      '{ok:$ok,host:$host,actual:{system:$system,username:$user,homeDirectory:$home,hostname:$hostname},registered:$registered}'
  else
    printf 'host: %s\nsystem: %s\nuser: %s\nhostname: %s\nstatus: %s\n' \
      "$host" "$system" "$user" "$hostname" "$([[ "$ok" == true ]] && echo ok || echo mismatch)"
  fi
  [[ "$ok" == true ]] || return "$EX_DATAERR"
}

doctor_git() {
  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;
      *) die "$EX_USAGE" "unknown doctor git option: $1" ;;
    esac
    shift
  done

  git_checks='[]'
  local config_readable=true helper_rows="" helper_status=0
  local store_helpers=0 global_secure=false github_secure=false gitlab_secure=false
  local github_helper=false line name value

  if ! git config --list --show-origin >/dev/null 2>&1; then
    config_readable=false
  fi
  helper_rows="$(git config --show-origin --get-regexp '^credential(\..*)?\.helper$' 2>/dev/null)" ||
    helper_status=$?
  if ((helper_status > 1)); then
    config_readable=false
    helper_rows=""
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\t ' read -r _ name value <<<"$line"
    if git_helper_is_store "$value"; then
      store_helpers=$((store_helpers + 1))
    fi
    case "$name" in
      credential.helper)
        if [[ -z "$value" ]]; then
          global_secure=false
        elif git_helper_is_secure "$value"; then
          global_secure=true
        fi
        ;;
      credential.https://github.com.helper | credential.https://gist.github.com.helper)
        if [[ -z "$value" ]]; then
          github_secure=false
        elif git_helper_is_secure "$value"; then
          github_secure=true
        fi
        git_helper_is_gh "$value" && github_helper=true
        ;;
      credential.https://gitlab.com.helper)
        if [[ -z "$value" ]]; then
          gitlab_secure=false
        elif git_helper_is_secure "$value"; then
          gitlab_secure=true
        fi
        ;;
    esac
  done <<<"$helper_rows"
  [[ "$global_secure" == false ]] || {
    github_secure=true
    gitlab_secure=true
  }

  local expected actual status code summary remediation
  expected='{"readable":true}'
  actual="$(jq -nc --argjson readable "$config_readable" '{readable:$readable}')"
  if [[ "$config_readable" == true ]]; then
    status=ok
    code=""
    summary="Git configuration is readable"
    remediation=""
  else
    status=failed
    code=configuration-unreadable
    summary="Git configuration could not be read safely"
    remediation="repair the Git configuration before relying on authentication or signing"
  fi
  git_check_add git-configuration home-manager true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"

  local agent_socket=false agent_available=false agent_key_count=0 agent_status=0 agent_output=""
  [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK:-}" ]] && agent_socket=true
  if command -v ssh-add >/dev/null 2>&1 && [[ "$agent_socket" == true ]]; then
    agent_output="$(ssh-add -l 2>/dev/null)" || agent_status=$?
    case "$agent_status" in
      0)
        agent_available=true
        agent_key_count="$(jq -Rsc 'split("\n") | map(select(length > 0)) | length' <<<"$agent_output")"
        ;;
      1) agent_available=true ;;
    esac
  else
    agent_status=2
  fi
  expected='{"available":true}'
  actual="$(jq -nc --argjson socketPresent "$agent_socket" --argjson available "$agent_available" \
    '{socketPresent:$socketPresent,available:$available}')"
  if [[ "$agent_available" == true ]]; then
    status=ok
    code=""
    summary="SSH agent is reachable"
    remediation=""
  else
    status=failed
    code=agent-unavailable
    summary="SSH agent is unavailable"
    remediation="start the platform SSH agent and export its socket (apply enables services.ssh-agent on Linux), then run 'atyrode provision git'; do not fall back to a plaintext HTTPS helper"
  fi
  git_check_add ssh-agent operator true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"

  expected='{"minimumKeyCount":1}'
  actual="$(jq -nc --argjson keyCount "$agent_key_count" '{keyCount:$keyCount}')"
  if [[ "$agent_available" == true && "$agent_key_count" -gt 0 ]]; then
    status=ok
    code=""
    summary="SSH agent has at least one key loaded"
    remediation=""
  else
    status=failed
    code=no-agent-keys
    summary="SSH agent has no usable keys"
    remediation="run 'atyrode provision git' to load this machine's vault-backed authentication and signing keys into the agent"
  fi
  git_check_add ssh-agent-keys operator true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"

  local signing_config="" signing_path="" signing_mode="" signing_readable=false
  local signing_permissions=false signing_public=false signing_valid=false key_type="" key_blob=""
  signing_config="$(git config --global --get user.signingKey 2>/dev/null || true)"
  if [[ -n "$signing_config" ]]; then
    signing_path="$(expand_home_path "$signing_config")"
  fi
  if [[ -n "$signing_path" && -f "$signing_path" && -r "$signing_path" ]]; then
    signing_readable=true
    signing_mode="$(stat -c '%a' -- "$signing_path" 2>/dev/null || true)"
    if [[ "$signing_mode" =~ ^[0-7]{3,4}$ ]] &&
      (((8#$signing_mode & 8#022) == 0)); then
      signing_permissions=true
    fi
    IFS=' ' read -r key_type key_blob _ <"$signing_path" || true
    case "$key_type" in
      ssh-* | ecdsa-* | sk-*) signing_public=true ;;
    esac
    if [[ "$signing_public" == true ]] && ssh-keygen -lf "$signing_path" >/dev/null 2>&1; then
      signing_valid=true
    fi
  fi
  expected='{"configured":true,"readable":true,"publicKey":true,"valid":true,"permissionsSafe":true}'
  actual="$(jq -nc \
    --argjson configured "$([[ -n "$signing_config" ]] && echo true || echo false)" \
    --argjson readable "$signing_readable" \
    --argjson publicKey "$signing_public" \
    --argjson valid "$signing_valid" \
    --argjson permissionsSafe "$signing_permissions" \
    --arg mode "$signing_mode" \
    '{configured:$configured,readable:$readable,publicKey:$publicKey,valid:$valid,
      permissionsSafe:$permissionsSafe,mode:(if $mode == "" then null else $mode end)}')"
  if [[ "$signing_readable" == true && "$signing_public" == true &&
    "$signing_valid" == true && "$signing_permissions" == true ]]; then
    status=ok
    code=""
    summary="Configured SSH signing public key is readable, valid, and not writable by group or others"
    remediation=""
  else
    status=failed
    code=signing-key-invalid
    summary="Configured SSH signing public key is missing, unreadable, invalid, or writable by group or others"
    remediation="run 'atyrode provision git' to materialize the public signing key at user.signingKey with mode 0644 or stricter"
  fi
  git_check_add signing-key operator true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"

  local signers_config="" signers_path="" signers_readable=false signers_match=false
  local signers_authorize=false
  signers_config="$(git config --global --get gpg.ssh.allowedSignersFile 2>/dev/null || true)"
  if [[ -n "$signers_config" ]]; then
    signers_path="$(expand_home_path "$signers_config")"
  fi
  if [[ -n "$signers_path" && -f "$signers_path" && -r "$signers_path" ]]; then
    signers_readable=true
    cmp -s -- "$signers_path" "$managed_git_allowed_signers" && signers_match=true
    if [[ "$signing_valid" == true ]] &&
      awk -v type="$key_type" -v blob="$key_blob" \
        '$2 == type && $3 == blob { found = 1 } END { exit !found }' "$signers_path"; then
      signers_authorize=true
    fi
  fi
  expected='{"configured":true,"readable":true,"managedContent":true,"signingKeyAuthorized":true}'
  actual="$(jq -nc \
    --argjson configured "$([[ -n "$signers_config" ]] && echo true || echo false)" \
    --argjson readable "$signers_readable" \
    --argjson managedContent "$signers_match" \
    --argjson signingKeyAuthorized "$signers_authorize" \
    '{configured:$configured,readable:$readable,managedContent:$managedContent,
      signingKeyAuthorized:$signingKeyAuthorized}')"
  if [[ "$signers_readable" == true && "$signers_match" == true && "$signers_authorize" == true ]]; then
    status=ok
    code=""
    summary="allowed_signers matches managed content and authorizes the configured signing key"
    remediation=""
  else
    status=failed
    code=allowed-signers-drift
    summary="allowed_signers is missing, unreadable, drifting from managed content, or does not authorize the signing key"
    remediation="apply the current Home Manager configuration; do not edit allowed_signers manually"
  fi
  git_check_add allowed-signers home-manager true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"

  local inside_work_tree=false forge_remotes=0 ssh_fetch=0 https_fetch=0
  local ssh_push=0 https_push=0 insecure_urls=0 unsafe_https_push=0
  local remote remote_is_forge kind url
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    inside_work_tree=true
    while IFS= read -r remote; do
      [[ -n "$remote" ]] || continue
      remote_is_forge=false
      while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        kind="$(git_forge_url_kind "$url")"
        case "$kind" in
          github-ssh | gitlab-ssh)
            ssh_fetch=$((ssh_fetch + 1))
            remote_is_forge=true
            ;;
          github-https | gitlab-https)
            https_fetch=$((https_fetch + 1))
            remote_is_forge=true
            ;;
          github-insecure | gitlab-insecure)
            insecure_urls=$((insecure_urls + 1))
            remote_is_forge=true
            ;;
        esac
      done < <(git remote get-url --all "$remote" 2>/dev/null || true)
      while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        kind="$(git_forge_url_kind "$url")"
        case "$kind" in
          github-ssh | gitlab-ssh)
            ssh_push=$((ssh_push + 1))
            remote_is_forge=true
            ;;
          github-https)
            https_push=$((https_push + 1))
            remote_is_forge=true
            [[ "$github_secure" == true ]] || unsafe_https_push=$((unsafe_https_push + 1))
            ;;
          gitlab-https)
            https_push=$((https_push + 1))
            remote_is_forge=true
            [[ "$gitlab_secure" == true ]] || unsafe_https_push=$((unsafe_https_push + 1))
            ;;
          github-insecure | gitlab-insecure)
            insecure_urls=$((insecure_urls + 1))
            remote_is_forge=true
            ;;
        esac
      done < <(git remote get-url --push --all "$remote" 2>/dev/null || true)
      [[ "$remote_is_forge" == false ]] || forge_remotes=$((forge_remotes + 1))
    done < <(git remote 2>/dev/null || true)
  fi
  expected='{"sshForAuthentication":true,"plaintextHelperRequired":false}'
  actual="$(jq -nc \
    --argjson insideWorkTree "$inside_work_tree" \
    --argjson forgeRemotes "$forge_remotes" \
    --argjson sshFetchUrls "$ssh_fetch" \
    --argjson httpsFetchUrls "$https_fetch" \
    --argjson sshPushUrls "$ssh_push" \
    --argjson httpsPushUrls "$https_push" \
    --argjson insecureUrls "$insecure_urls" \
    --argjson httpsPushWithoutSecureHelper "$unsafe_https_push" \
    '{insideWorkTree:$insideWorkTree,forgeRemotes:$forgeRemotes,sshFetchUrls:$sshFetchUrls,
      httpsFetchUrls:$httpsFetchUrls,sshPushUrls:$sshPushUrls,httpsPushUrls:$httpsPushUrls,
      insecureUrls:$insecureUrls,httpsPushWithoutSecureHelper:$httpsPushWithoutSecureHelper}')"
  if [[ "$inside_work_tree" == false || "$forge_remotes" -eq 0 ]]; then
    status=not-applicable
    code=no-forge-remote
    summary="Current directory has no GitHub or GitLab remote to classify"
    remediation=""
  elif [[ "$unsafe_https_push" -gt 0 || "$insecure_urls" -gt 0 ]]; then
    status=warning
    code=https-without-secure-helper
    summary="A forge remote can authenticate without SSH or a recognized non-plaintext helper"
    remediation="use an SSH remote, apply the managed pushInsteadOf rules, or configure an explicitly secure helper"
  else
    status=ok
    code=""
    summary="Current forge remotes use SSH for pushes or a recognized non-plaintext helper"
    remediation=""
  fi
  git_check_add remote-protocol git true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"

  expected='{"storeHelperCount":0}'
  actual="$(jq -nc --argjson storeHelperCount "$store_helpers" '{storeHelperCount:$storeHelperCount}')"
  if [[ "$store_helpers" -eq 0 ]]; then
    status=ok
    code=""
    summary="No git-credential-store helper is configured"
    remediation=""
  else
    status=failed
    code=plaintext-helper
    summary="Git configuration contains a plaintext credential store helper"
    remediation="remove every credential.helper=store entry and use SSH or a verified secure helper"
  fi
  git_check_add credential-helper-plaintext git true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"

  local credential_files=0
  [[ ! -e "$HOME/.git-credentials" && ! -L "$HOME/.git-credentials" ]] ||
    credential_files=$((credential_files + 1))
  local xdg_git_credentials="${XDG_CONFIG_HOME:-$HOME/.config}/git/credentials"
  [[ ! -e "$xdg_git_credentials" && ! -L "$xdg_git_credentials" ]] ||
    credential_files=$((credential_files + 1))
  expected='{"plaintextCredentialFileCount":0}'
  actual="$(jq -nc --argjson plaintextCredentialFileCount "$credential_files" \
    '{plaintextCredentialFileCount:$plaintextCredentialFileCount}')"
  if [[ "$credential_files" -eq 0 ]]; then
    status=ok
    code=""
    summary="No default git-credential-store file is present"
    remediation=""
  else
    status=failed
    code=plaintext-credential-file
    summary="A default plaintext Git credential file is present"
    remediation="confirm required credentials exist in SSH or a secure backend, then delete the plaintext file"
  fi
  git_check_add credential-file-plaintext operator true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"

  local gh_available=false
  command -v gh >/dev/null 2>&1 && gh_available=true
  expected='{"declaredGhHelper":true,"ghAvailable":true}'
  actual="$(jq -nc --argjson declaredGhHelper "$github_helper" --argjson ghAvailable "$gh_available" \
    '{declaredGhHelper:$declaredGhHelper,ghAvailable:$ghAvailable}')"
  if [[ "$github_helper" == true && "$gh_available" == true ]]; then
    status=ok
    code=""
    summary="GitHub HTTPS exceptions delegate to the declared gh credential helper"
    remediation=""
  else
    status=failed
    code=gh-helper-unavailable
    summary="The declared GitHub CLI credential helper is missing or gh is unavailable"
    remediation="apply programs.gh.gitCredentialHelper.enable and repair the managed gh installation"
  fi
  git_check_add gh-credential-helper home-manager true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"

  local gh_config_dir="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
  local gh_hosts_file="$gh_config_dir/hosts.yml" gh_hosts_present=false gh_hosts_readable=false
  local gh_plaintext=false env_token=false auth_json="" account_count=0 keyring_count=0
  local env_count=0 plaintext_source_count=0 unknown_source_count=0 auth_classified=false
  [[ ! -e "$gh_hosts_file" && ! -L "$gh_hosts_file" ]] || gh_hosts_present=true
  if [[ "$gh_hosts_present" == true && -r "$gh_hosts_file" ]]; then
    gh_hosts_readable=true
    grep -Eq '^[[:space:]]*oauth_token[[:space:]]*:' "$gh_hosts_file" && gh_plaintext=true
  fi
  [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-}" ]] ||
    env_token=true

  if [[ "$gh_available" == true && "$gh_plaintext" == false &&
    "$gh_hosts_present" == true && "$gh_hosts_readable" == true ]]; then
    if auth_json="$(timeout 10s gh auth status --json hosts 2>/dev/null)" &&
      jq -e '.hosts | type == "object"' >/dev/null 2>&1 <<<"$auth_json"; then
      auth_classified=true
      account_count="$(jq '[.hosts[][]?] | length' <<<"$auth_json")"
      keyring_count="$(jq '[.hosts[][]? | select(.tokenSource == "keyring")] | length' <<<"$auth_json")"
      env_count="$(jq '[.hosts[][]? | select(.tokenSource | endswith("_TOKEN"))] | length' <<<"$auth_json")"
      plaintext_source_count="$(jq \
        '[.hosts[][]? | select(.tokenSource != "" and .tokenSource != "keyring"
          and ((.tokenSource | endswith("_TOKEN")) | not))] | length' <<<"$auth_json")"
      unknown_source_count="$(jq '[.hosts[][]? | select(.tokenSource == "")] | length' <<<"$auth_json")"
    fi
  fi

  expected='{"plaintextTokenFile":false,"durableTokenSource":"keyring"}'
  actual="$(jq -nc \
    --argjson hostsPresent "$gh_hosts_present" \
    --argjson hostsReadable "$gh_hosts_readable" \
    --argjson plaintextTokenFile "$gh_plaintext" \
    --argjson environmentToken "$env_token" \
    --argjson accountCount "$account_count" \
    --argjson keyringAccountCount "$keyring_count" \
    --argjson environmentAccountCount "$env_count" \
    --argjson plaintextSourceCount "$plaintext_source_count" \
    --argjson unknownSourceCount "$unknown_source_count" \
    '{hostsPresent:$hostsPresent,hostsReadable:$hostsReadable,plaintextTokenFile:$plaintextTokenFile,
      environmentToken:$environmentToken,accountCount:$accountCount,
      keyringAccountCount:$keyringAccountCount,environmentAccountCount:$environmentAccountCount,
      plaintextSourceCount:$plaintextSourceCount,unknownSourceCount:$unknownSourceCount}')"
  if [[ "$gh_plaintext" == true || "$plaintext_source_count" -gt 0 ]]; then
    status=failed
    code=gh-plaintext-token
    summary="GitHub CLI authentication is stored in a plaintext configuration file"
    remediation="log out, repair a platform keyring, log in again, and verify gh reports tokenSource=keyring"
  elif [[ "$gh_hosts_present" == true && "$gh_hosts_readable" == false ]]; then
    status=failed
    code=gh-storage-unreadable
    summary="GitHub CLI credential storage exists but cannot be classified"
    remediation="repair permissions, then verify the token source before using gh authentication"
  elif [[ "$gh_hosts_present" == false && "$env_token" == false ]]; then
    status=not-applicable
    code=gh-not-authenticated
    summary="GitHub CLI has no persisted account to classify"
    remediation=""
  elif [[ "$env_token" == true || "$env_count" -gt 0 ]]; then
    status=warning
    code=gh-environment-token
    summary="GitHub CLI is using a process token whose external storage cannot be verified"
    remediation="inject it only from an approved secret manager and never persist it in shell or gh configuration"
  elif [[ "$auth_classified" == true && "$account_count" -eq "$keyring_count" &&
    "$unknown_source_count" -eq 0 ]]; then
    status=ok
    code=""
    summary="GitHub CLI durable authentication is stored in the platform keyring"
    remediation=""
  else
    status=failed
    code=gh-storage-unverified
    summary="GitHub CLI credential storage could not be verified as non-plaintext"
    remediation="repair the platform keyring and require gh auth status to report tokenSource=keyring"
  fi
  git_check_add gh-auth-storage gh true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"

  local ok=false result
  jq -e 'all(.[]; .status != "failed")' <<<"$git_checks" >/dev/null && ok=true
  result="$(jq -nc --argjson ok "$ok" --argjson insideWorkTree "$inside_work_tree" \
    --argjson checks "$git_checks" \
    '{schemaVersion:1,command:"doctor git",ok:$ok,
      repository:{insideWorkTree:$insideWorkTree},checks:$checks,
      mutationBoundary:"read-only probes"}')"
  if [[ "$json" == 1 ]]; then
    printf '%s\n' "$result"
  else
    jq -r '.checks[] | "\(.id): \(.status) — \(.summary)"' <<<"$result"
    jq -r '"status: \(if .ok then "ready" else "problems found" end)"' <<<"$result"
  fi
  [[ "$ok" == true ]] || return "$EX_UNAVAILABLE"
}
doctor_tools() {
  local json=0 rows='[]' status path entry command capability platform host data expected remediation
  [[ "${1:-}" != --json ]] || json=1
  host="$(resolve_host)"
  data="$(host_json "$host")"
  while IFS= read -r entry; do
    command="$(jq -r '.command' <<<"$entry")"
    capability="$(jq -r '.capability' <<<"$entry")"
    platform="$(jq -r '.platform // empty' <<<"$entry")"
    expected=false
    if jq -e --arg capability "$capability" '.capabilities | index($capability)' <<<"$data" >/dev/null &&
      [[ -z "$platform" || "$platform" == "$(jq -r '.platform' <<<"$data")" ]]; then
      expected=true
    fi
    if path="$(command -v "$command" 2>/dev/null)"; then
      status=ok
    else
      status=missing
      path=''
    fi
    remediation="enable the $capability capability and apply the registered host; do not install globally"
    rows="$(jq -c --argjson entry "$entry" --arg status "$status" --arg path "$path" \
      --argjson expected "$expected" --arg remediation "$remediation" \
      '. + [$entry + {status:$status,path:$path,expected:$expected,remediation:(if $status == "missing" then $remediation else null end)}]' <<<"$rows")"
  done < <(jq -c '.[]' "$tool_inventory")
  if [[ "$json" == 1 ]]; then
    printf '%s\n' "$rows"
  else jq -r '.[] | "\(.name): \(.status) [\(.capability)]\(if .path == "" then "" else " (\(.path))" end)"' <<<"$rows"; fi
  jq -e 'all(.[]; (.expected | not) or .status == "ok")' <<<"$rows" >/dev/null
}

system_checks='[]'
system_fixture='{}'

system_check_add() {
  local id="$1" owner="$2" required="$3" status="$4" code="$5"
  local summary="$6" remediation="$7" expected="$8" actual="$9"

  system_checks="$(jq -c \
    --arg id "$id" \
    --arg owner "$owner" \
    --argjson required "$required" \
    --arg status "$status" \
    --arg code "$code" \
    --arg summary "$summary" \
    --arg remediation "$remediation" \
    --argjson expected "$expected" \
    --argjson actual "$actual" \
    '. + [{
      id: $id,
      owner: $owner,
      required: $required,
      status: $status,
      code: (if $code == "" then null else $code end),
      summary: $summary,
      remediation: (if $remediation == "" then null else $remediation end),
      expected: $expected,
      actual: $actual
    }]' <<<"$system_checks")"
}

load_system_fixture() {
  local fixture_path="${_ATYRODE_TEST_SYSTEM_FIXTURE:-}"

  if [[ "$test_hooks" != 1 || -z "$fixture_path" ]]; then
    printf '{}\n'
    return
  fi
  [[ -f "$fixture_path" && ! -L "$fixture_path" ]] ||
    die "$EX_DATAERR" "system diagnostic fixture must be a regular file"
  jq -ec 'select(type == "object")' "$fixture_path" ||
    die "$EX_DATAERR" "system diagnostic fixture is not a JSON object"
}

has_system_fixture() {
  [[ "$system_fixture" != '{}' ]]
}

is_nixos_owned() {
  local data="$1"

  if jq -e '.activation == "nixos" or .activation == "nixos-wsl"' <<<"$data" >/dev/null; then
    return 0
  fi
  has_capability "$data" server
}

nix_system_owner() {
  local data="$1" platform="$2"

  if [[ "$platform" == darwin ]]; then
    printf 'nix-darwin\n'
  elif is_nixos_owned "$data"; then
    printf 'nixos\n'
  else
    printf 'system\n'
  fi
}

probe_login_shell() {
  local data="$1" platform="$2" user="$3"
  local owner expected current="" executable=false listed=false status code summary remediation
  local expected_json actual_json nixos_wrapped=false

  if [[ "$platform" == darwin ]]; then
    owner=nix-darwin
    expected="$(jq -r '.loginShell.darwinPath' "$system_policy")"
  elif is_nixos_owned "$data"; then
    owner=nixos
    expected="$(jq -r '.loginShell.nixosPath' "$system_policy")"
  else
    # No system configuration owns the account database on a home-manager host,
    # which is why this case exists at all. Apply converges it, so apply is the
    # owner named here.
    owner=atyrode
    expected="$HOME/.nix-profile/bin/zsh"
  fi

  if has_system_fixture; then
    current="$(jq -r '.loginShell.path // empty' <<<"$system_fixture")"
    executable="$(jq -r '.loginShell.executable // false' <<<"$system_fixture")"
    listed="$(jq -r '.loginShell.listed // false' <<<"$system_fixture")"
  else
    if [[ "$platform" == darwin ]]; then
      current="$(/usr/bin/dscl . -read "/Users/$user" UserShell 2>/dev/null | awk '{ print $2 }')"
    elif command -v getent >/dev/null 2>&1; then
      current="$(getent passwd "$user" 2>/dev/null | awk -F: 'NR == 1 { print $7 }')"
    fi
    [[ -x "$current" ]] && executable=true
    grep -Fqx -- "$current" /etc/shells 2>/dev/null && listed=true
  fi

  # NixOS may write its generated wrapped Zsh directly to the account database.
  # That path is owned by the active system closure and intentionally does not
  # need a second, store-specific entry in /etc/shells.
  if [[ "$owner" == nixos && "$current" == /nix/store/*-wrapped-zsh/wrapper &&
    "$executable" == true ]]; then
    nixos_wrapped=true
  fi

  expected_json="$(jq -nc --arg path "$expected" '{program:"zsh",path:$path,listed:true,executable:true}')"
  actual_json="$(jq -nc --arg path "$current" --argjson executable "$executable" \
    --argjson listed "$listed" '{path:$path,executable:$executable,listed:$listed,source:"account-database"}')"
  if { [[ "$current" == "$expected" && "$executable" == true && "$listed" == true ]]; } ||
    [[ "$nixos_wrapped" == true ]]; then
    status=ok
    code=""
    summary="account login shell is the managed Zsh path"
    remediation=""
  else
    status=incomplete
    code="login-shell-mismatch"
    summary="Zsh is installed but the account login shell is not operationally configured"
    if [[ "$platform" == darwin ]]; then
      remediation="apply nix-darwin again; its activation owns the primary account UserShell"
    elif [[ "$owner" == nixos ]]; then
      remediation="configure programs.zsh and users.users.<name>.shell in the NixOS infrastructure"
    else
      remediation="run atyrode apply with privilege; it registers and selects the managed Zsh path"
    fi
  fi
  system_check_add login-shell "$owner" true "$status" "$code" "$summary" "$remediation" \
    "$expected_json" "$actual_json"
}

probe_nix_daemon() {
  local data="$1" platform="$2" reachable=false owner status code summary remediation expected_json actual_json

  owner="$(nix_system_owner "$data" "$platform")"
  if has_system_fixture; then
    reachable="$(jq -r '.nix.daemonReachable // false' <<<"$system_fixture")"
  elif nix store info --store daemon --json >/dev/null 2>&1; then
    reachable=true
  fi
  expected_json='{"store":"daemon","reachable":true}'
  actual_json="$(jq -nc --argjson reachable "$reachable" '{store:"daemon",reachable:$reachable}')"
  if [[ "$reachable" == true ]]; then
    status=ok
    code=""
    summary="the system-owned Nix daemon is reachable"
    remediation=""
  else
    status=incomplete
    code="nix-daemon-unreachable"
    summary="the Nix client cannot reach the daemon"
    remediation="repair the system Nix service; Home Manager cannot own or restart it"
  fi
  system_check_add nix-daemon "$owner" true "$status" "$code" "$summary" "$remediation" \
    "$expected_json" "$actual_json"
}

probe_nix_policy() {
  local data="$1" platform="$2" owner config_json='{}'
  local trusted_exact=false official_cache=false official_key=false signatures=false optimiser=false
  local status code summary remediation expected_json actual_json expected_users

  owner="$(nix_system_owner "$data" "$platform")"
  expected_users="$(jq -c 'select(.nixTrustedUsers != null) | .nixTrustedUsers | sort' <<<"$data")"
  if [[ -z "$expected_users" ]]; then
    expected_users="$(jq -c '.nix.trustedUsers | sort' "$system_policy")"
  fi
  if has_system_fixture; then
    trusted_exact="$(jq -r '.nix.trustedUsersExact // false' <<<"$system_fixture")"
    official_cache="$(jq -r '.nix.officialCacheOnly // false' <<<"$system_fixture")"
    official_key="$(jq -r '.nix.officialKeyOnly // false' <<<"$system_fixture")"
    signatures="$(jq -r '.nix.signaturesRequired // false' <<<"$system_fixture")"
    optimiser="$(jq -r '.nix.optimiserScheduled // false' <<<"$system_fixture")"
  else
    config_json="$(nix config show --json 2>/dev/null || printf '{}')"
    jq -e --argjson expected "$expected_users" \
      '.["trusted-users"].value | sort == $expected' <<<"$config_json" >/dev/null && trusted_exact=true
    jq -e --arg expected "$(jq -r '.nix.substituter' "$system_policy")" \
      '.["substituters"].value == [$expected]' <<<"$config_json" >/dev/null && official_cache=true
    jq -e --arg expected "$(jq -r '.nix.trustedPublicKey' "$system_policy")" \
      '.["trusted-public-keys"].value == [$expected]' <<<"$config_json" >/dev/null && official_key=true
    jq -e '.["require-sigs"].value == true' <<<"$config_json" >/dev/null && signatures=true
    if [[ "$platform" == darwin ]] && /bin/launchctl print \
      "system/$(jq -r '.nix.darwinOptimiserLabel' "$system_policy")" >/dev/null 2>&1; then
      optimiser=true
    fi
  fi

  expected_json="$(jq -nc --argjson trustedUsers "$expected_users" \
    --argjson scheduled "$([[ "$platform" == darwin ]] && echo true || echo false)" \
    '{trustedUsers:$trustedUsers,officialSignedCacheOnly:true,signaturesRequired:true,optimiserScheduled:$scheduled}')"
  actual_json="$(jq -nc --argjson trustedUsersExact "$trusted_exact" \
    --argjson officialCacheOnly "$official_cache" --argjson officialKeyOnly "$official_key" \
    --argjson signaturesRequired "$signatures" --argjson optimiserScheduled "$optimiser" \
    '{trustedUsersExact:$trustedUsersExact,officialCacheOnly:$officialCacheOnly,
      officialKeyOnly:$officialKeyOnly,signaturesRequired:$signaturesRequired,
      optimiserScheduled:$optimiserScheduled}')"
  if [[ "$trusted_exact" == true && "$official_cache" == true && "$official_key" == true &&
    "$signatures" == true && ("$platform" != darwin || "$optimiser" == true) ]]; then
    status=ok
    code=""
    summary="Nix trust, signed cache, and optimisation ownership match policy"
    remediation=""
  else
    status=incomplete
    code="nix-policy-drift"
    summary="effective Nix daemon policy differs from the reviewed system boundary"
    remediation="repair the owning nix-darwin or NixOS/Nix-daemon configuration; do not use a user nix.conf override"
  fi
  system_check_add nix-policy "$owner" true "$status" "$code" "$summary" "$remediation" \
    "$expected_json" "$actual_json"
}

probe_container_engine() {
  local data="$1" platform="$2" user="$3" required=false groups="" docker_group=false mode=unavailable
  local owner status code summary remediation expected_json actual_json uid socket security

  owner="$(portable_system_owner "$data")"
  has_capability "$data" containers && required=true
  if has_system_fixture; then
    docker_group="$(jq -r '.container.dockerGroup // false' <<<"$system_fixture")"
    mode="$(jq -r '.container.mode // "unavailable"' <<<"$system_fixture")"
  else
    groups="$(id -Gn "$user" 2>/dev/null || true)"
    word_in_list docker "$groups" && docker_group=true
    if [[ "$required" == true && "$platform" == darwin ]]; then
      if docker --context "$(jq -r '.containers.darwin.context' "$system_policy")" \
        info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
        mode=orbstack
      fi
    elif [[ "$required" == true ]]; then
      uid="$(id -u "$user" 2>/dev/null || true)"
      socket="$(jq -r '.containers.linux.socketTemplate' "$system_policy")"
      socket="${socket//\{uid\}/$uid}"
      security="$(docker --host "unix://$socket" info --format '{{json .SecurityOptions}}' 2>/dev/null || true)"
      grep -qi "$(jq -r '.containers.linux.requiredSecurityOption' "$system_policy")" \
        <<<"$security" && mode=rootless
    fi
  fi

  if [[ "$platform" == darwin ]]; then
    expected_json='{"mode":"orbstack","dockerGroup":false}'
  else
    expected_json='{"mode":"rootless","dockerGroup":false}'
  fi
  actual_json="$(jq -nc --arg mode "$mode" --argjson dockerGroup "$docker_group" \
    '{mode:$mode,dockerGroup:$dockerGroup}')"
  if [[ "$docker_group" == true ]]; then
    status=incomplete
    code="docker-group-membership"
    summary="the account belongs to the root-equivalent Docker group"
    remediation="remove Docker-group membership and use a rootless user engine; this command never changes groups"
  elif [[ "$required" != true ]]; then
    status=not-applicable
    code="capability-not-selected"
    summary="the containers capability is not selected"
    remediation=""
  elif [[ ("$platform" == darwin && "$mode" == orbstack) ||
    ("$platform" != darwin && "$mode" == rootless) ]]; then
    status=ok
    code=""
    summary="the declared container engine is reachable without root-equivalent membership"
    remediation=""
  else
    status=incomplete
    code="container-engine-unavailable"
    summary="container clients are installed but the declared engine policy is not operational"
    if [[ "$platform" == darwin ]]; then
      remediation="start and repair the nix-darwin-selected OrbStack engine"
    else
      remediation="configure a rootless Docker engine at the per-user socket; never add the user to the Docker group"
    fi
  fi
  system_check_add container-engine "$owner" "$required" "$status" "$code" "$summary" "$remediation" \
    "$expected_json" "$actual_json"
}

probe_antivirus() {
  local data="$1" owner present=false binary status code summary remediation
  local expected_json actual_json reason

  owner="$(portable_system_owner "$data")"
  reason="$(jq -r '.antivirus.reason' "$system_policy")"
  if has_system_fixture; then
    present="$(jq -r '.antivirus.binariesPresent // false' <<<"$system_fixture")"
  else
    for binary in clamscan freshclam; do
      if command -v "$binary" >/dev/null 2>&1; then
        present=true
        break
      fi
    done
  fi
  expected_json='{"managed":false,"binariesPresent":false}'
  actual_json="$(jq -nc --argjson binariesPresent "$present" \
    '{managed:false,binariesPresent:$binariesPresent,signatures:null,scanningWorkflow:null}')"
  if [[ "$present" == true ]]; then
    status=incomplete
    code="unmanaged-antivirus-present"
    summary="ClamAV binaries are present without owned signatures or a scanning workflow"
    remediation="remove the undeclared binaries, or first define a system-owned update, scan, and response policy"
  else
    status=not-applicable
    code="not-configured"
    summary="ClamAV is intentionally absent because no host owns signatures and scanning"
    remediation="$reason"
  fi
  system_check_add antivirus-data "$owner" false "$status" "$code" \
    "$summary" "$remediation" \
    "$expected_json" "$actual_json"
}

android_rule_roots() {
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_UDEV_ROOT:-}" ]]; then
    printf '%s\n' "$_ATYRODE_TEST_UDEV_ROOT"
  else
    jq -r '.android.linuxRuleRoots[]' "$system_policy"
  fi
}

probe_android_policy() {
  local groups="$1" root file group base rule

  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    for file in "$root"/*.rules; do
      [[ -f "$file" && -r "$file" ]] || continue
      base="${file##*/}"
      case "$base" in
        *android* | *Android* | *adb* | *ADB*) ;;
        *) continue ;;
      esac
      while IFS= read -r rule || [[ -n "$rule" ]]; do
        [[ ! "$rule" =~ ^[[:space:]]*# ]] || continue
        grep -Eq 'ATTR(S)?\{idVendor\}' <<<"$rule" 2>/dev/null || continue
        if grep -Eq 'TAG\+?=[[:space:]]*"uaccess"' <<<"$rule" 2>/dev/null; then
          printf 'uaccess\n'
          return
        fi
        while IFS= read -r group; do
          if grep -Eq "GROUP\\+?=[[:space:]]*\"$group\"" <<<"$rule" 2>/dev/null &&
            word_in_list "$group" "$groups"; then
            printf 'group:%s\n' "$group"
            return
          fi
        done < <(jq -r '.android.acceptedGroups[]' "$system_policy")
      done <"$file"
    done
  done < <(android_rule_roots)
  printf 'missing\n'
}

probe_device_permissions() {
  local data="$1" platform="$2" user="$3" required=false adb_available=false policy=not-applicable
  local owner groups status code summary remediation expected_json actual_json

  owner="$(portable_system_owner "$data")"
  has_capability "$data" mobile && required=true
  if [[ "$required" != true ]]; then
    expected_json='{"policy":null}'
    actual_json='{"adbAvailable":null,"policy":null}'
    system_check_add device-permissions "$owner" false not-applicable capability-not-selected \
      "the mobile capability is not selected" "" "$expected_json" "$actual_json"
    return
  fi
  if [[ "$platform" == darwin ]]; then
    if has_system_fixture && jq -e 'has("device")' <<<"$system_fixture" >/dev/null; then
      adb_available="$(jq -r '.device.adbAvailable // false' <<<"$system_fixture")"
    elif command -v adb >/dev/null 2>&1; then
      adb_available=true
    fi
    expected_json='{"policy":"macos-user-authorization"}'
    actual_json="$(jq -nc --argjson adbAvailable "$adb_available" \
      '{adbAvailable:$adbAvailable,policy:"macos-user-authorization"}')"
    if [[ "$adb_available" == true ]]; then
      status=ok
      code=""
      summary="ADB is installed; macOS owns per-device authorization at connection time"
      remediation=""
    else
      status=incomplete
      code="android-tools-missing"
      summary="the mobile capability is selected but ADB is unavailable"
      remediation="reapply the registered host so Home Manager provides Android platform tools"
    fi
    system_check_add device-permissions "$owner" true "$status" "$code" \
      "$summary" "$remediation" "$expected_json" "$actual_json"
    return
  fi

  if has_system_fixture && jq -e '.device | has("adbAvailable")' <<<"$system_fixture" >/dev/null; then
    adb_available="$(jq -r '.device.adbAvailable // false' <<<"$system_fixture")"
  else
    command -v adb >/dev/null 2>&1 && adb_available=true
  fi
  if has_system_fixture && jq -e '.device | has("policy")' <<<"$system_fixture" >/dev/null; then
    policy="$(jq -r '.device.policy // "missing"' <<<"$system_fixture")"
  else
    groups="$(id -Gn "$user" 2>/dev/null || true)"
    policy="$(probe_android_policy "$groups")"
  fi
  expected_json='{"adbAvailable":true,"policy":["uaccess","reviewed-user-group"]}'
  actual_json="$(jq -nc --argjson adbAvailable "$adb_available" --arg policy "$policy" \
    '{adbAvailable:$adbAvailable,policy:$policy}')"
  if [[ "$adb_available" == true && ("$policy" == uaccess || "$policy" == group:*) ]]; then
    status=ok
    code=""
    summary="ADB is installed and a reviewed udev access policy is present"
    remediation=""
  else
    status=incomplete
    code="android-device-permissions"
    summary="Android binaries are installed but Linux device access is not operationally configured"
    remediation="add a system-owned Android udev uaccess rule or reviewed adbusers/plugdev rule; do not run privileged ADB"
  fi
  system_check_add device-permissions "$owner" true "$status" "$code" "$summary" "$remediation" \
    "$expected_json" "$actual_json"
}

probe_homebrew_drift() {
  local platform="$1" available=false drift=true probe_failed=false
  local check_status=127 cleanup_status=127
  local status code summary remediation
  local expected_count expected_json actual_json

  expected_count="$(jq 'length' "$homebrew_cask_inventory")"
  expected_json="$(jq -nc --argjson casks "$expected_count" '{cleanup:"zap",expectedCasks:$casks}')"
  if [[ "$platform" != darwin ]]; then
    actual_json='{"available":null,"drift":null}'
    system_check_add homebrew-drift nix-darwin false not-applicable platform-not-darwin \
      "Homebrew is not part of the Linux ownership boundary" "" "$expected_json" "$actual_json"
    return
  fi
  # A fixture answers only for the keys it declares: a fixture WITHOUT .homebrew
  # falls through to the live probe below, which is how the check suite reaches
  # the real brew invocation without letting every other probe read the build
  # host. Production never evaluates the second conjunct — it has no fixture, so
  # has_system_fixture is false and the live branch always runs there.
  if has_system_fixture && jq -e 'has("homebrew")' <<<"$system_fixture" >/dev/null; then
    available="$(jq -r '.homebrew.available // false' <<<"$system_fixture")"
    drift="$(jq -r 'if .homebrew | has("drift") then .homebrew.drift else true end' \
      <<<"$system_fixture")"
    probe_failed="$(jq -r '.homebrew.probeFailed // false' <<<"$system_fixture")"
  elif command -v brew >/dev/null 2>&1; then
    available=true
    check_status=0
    cleanup_status=0
    env -u HOMEBREW_BUNDLE_FILE HOMEBREW_NO_AUTO_UPDATE=1 \
      brew bundle check --no-upgrade --file "$homebrew_brewfile" </dev/null >/dev/null 2>&1 || check_status=$?
    env -u HOMEBREW_BUNDLE_FILE HOMEBREW_NO_AUTO_UPDATE=1 \
      brew bundle cleanup --file "$homebrew_brewfile" </dev/null >/dev/null 2>&1 || cleanup_status=$?
    if [[ "$check_status" -gt 1 || "$cleanup_status" -gt 1 ]]; then
      probe_failed=true
    fi
    [[ "$check_status" -eq 0 && "$cleanup_status" -eq 0 ]] && drift=false
  fi
  actual_json="$(jq -nc --argjson available "$available" --argjson drift "$drift" \
    --argjson probeFailed "$probe_failed" \
    '{available:$available,drift:$drift,probeFailed:$probeFailed,
      probe:"brew-bundle-check-and-cleanup-without-force"}')"
  if [[ "$available" != true ]]; then
    status=incomplete
    code="homebrew-unavailable"
    summary="nix-darwin expects Homebrew but brew is unavailable"
    remediation="repair the nix-homebrew installation, then re-run the non-destructive drift check"
  elif [[ "$probe_failed" == true ]]; then
    status=incomplete
    code="homebrew-probe-failed"
    summary="Homebrew state could not be compared with the immutable Brewfile"
    remediation="repair Homebrew or Brew Bundle, then rerun the read-only drift check"
  elif [[ "$drift" == false ]]; then
    status=ok
    code=""
    summary="Homebrew matches the immutable nix-darwin Brewfile"
    remediation=""
  else
    status=incomplete
    code="homebrew-drift"
    summary="Homebrew has missing or extra state relative to the generated Brewfile"
    remediation="declare the drift or run atyrode apply; activation uninstalls and zaps undeclared state"
  fi
  system_check_add homebrew-drift nix-darwin true "$status" "$code" "$summary" "$remediation" \
    "$expected_json" "$actual_json"
}

doctor_system() {
  local requested="" json=0 host data platform user system capabilities ok result

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json=1
        shift
        ;;
      --*) die "$EX_USAGE" "unknown doctor system option: $1" ;;
      *)
        [[ -z "$requested" ]] || die "$EX_USAGE" "doctor system accepts at most one host"
        requested="$1"
        shift
        ;;
    esac
  done
  host="$(resolve_host "$requested")"
  doctor_host "$host" 1 >/dev/null || return $?
  data="$(host_json "$host")"
  platform="$(jq -r '.platform' <<<"$data")"
  user="$(jq -r '.username' <<<"$data")"
  system="$(jq -r '.system' <<<"$data")"
  capabilities="$(jq -c '.capabilities' <<<"$data")"
  system_fixture="$(load_system_fixture)"
  system_checks='[]'

  jq -e '.schemaVersion == 1' "$system_policy" >/dev/null ||
    die "$EX_SOFTWARE" "unsupported system policy schema"
  probe_login_shell "$data" "$platform" "$user"
  probe_nix_daemon "$data" "$platform"
  probe_nix_policy "$data" "$platform"
  probe_container_engine "$data" "$platform" "$user"
  probe_antivirus "$data"
  probe_device_permissions "$data" "$platform" "$user"
  probe_homebrew_drift "$platform"
  jq -e --argjson expected "$(jq -c '.checkOrder' "$system_policy")" \
    'map(.id) == $expected' <<<"$system_checks" >/dev/null ||
    die "$EX_SOFTWARE" "system diagnostics do not match the policy order"

  ok=false
  jq -e 'all(.[]; .status != "incomplete")' <<<"$system_checks" >/dev/null && ok=true
  result="$(jq -nc --argjson ok "$ok" --arg host "$host" --arg system "$system" \
    --arg platform "$platform" --argjson capabilities "$capabilities" \
    --argjson checks "$system_checks" \
    '{schemaVersion:1,command:"doctor system",ok:$ok,host:$host,system:$system,
      platform:$platform,capabilities:$capabilities,checks:$checks,mutationBoundary:"read-only probes"}')"
  if [[ "$json" == 1 ]]; then
    printf '%s\n' "$result"
  else
    jq -r '.checks[] | "\(.id): \(.status) — \(.summary)"' <<<"$result"
    jq -r '"status: \(if .ok then "ready" else "incomplete" end)"' <<<"$result"
  fi
  [[ "$ok" == true ]] || return "$EX_UNAVAILABLE"
}

probe_omp_seed() {
  local seed_status drift_count

  if ! command -v atyrode-omp-seed >/dev/null 2>&1; then
    provisioning_check_add omp-seed not-applicable capability-not-selected \
      "the omp seeder is not installed on this machine" ""
    return 0
  fi
  if ! seed_status="$(atyrode-omp-seed status --json 2>/dev/null)" ||
    ! drift_count="$(jq -er '.drift | length' <<<"$seed_status" 2>/dev/null)"; then
    provisioning_check_add omp-seed degraded seed-status-unreadable \
      "the omp seeder is installed but its status could not be read" \
      "atyrode-omp-seed status"
    return 0
  fi
  if [[ "$drift_count" == 0 ]]; then
    provisioning_check_add omp-seed ok "" "omp settings match the repository defaults" ""
  else
    provisioning_check_add omp-seed degraded seed-drift \
      "$drift_count omp setting(s) kept over the repository defaults" \
      "atyrode-omp-seed resolve"
  fi
}

# Detection needs no vault and no network: a diagnostic that opens a vault
# session would cost a password to answer a question about a password.
probe_git_identity() {
  local signing_public reason=""

  signing_public="$(git config --global --get user.signingKey 2>/dev/null || true)"
  if [[ -n "$signing_public" && ! -r "$(expand_home_path "$signing_public")" ]]; then
    reason="the configured signing key is missing"
  elif command -v ssh-add >/dev/null 2>&1 &&
    [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK:-}" ]] &&
    ! ssh-add -l >/dev/null 2>&1; then
    reason="the agent holds no keys"
  fi
  if [[ -z "$reason" ]]; then
    provisioning_check_add git-identity ok "" "this machine has a usable Git identity" ""
  else
    provisioning_unconfigured git-identity "Git identity incomplete: $reason"
  fi
}

probe_babel_archive() {
  local config_file stamp_file last="" last_epoch now

  config_file="${XDG_CONFIG_HOME:-$HOME/.config}/babel/storage.json"
  stamp_file="${XDG_STATE_HOME:-$HOME/.local/state}/babel/last-success"
  if [[ ! -x "$babel_storage_configure" ]]; then
    provisioning_check_add babel-archive not-applicable capability-not-selected \
      "the babel archive ceremony is not part of this build" ""
    return 0
  fi
  if [[ ! -f "$config_file" ]]; then
    provisioning_unconfigured babel-archive \
      "the hourly timer is installed but archives nothing until this is configured"
    return 0
  fi
  [[ ! -f "$stamp_file" ]] || read -r last <"$stamp_file" || true
  if [[ -z "$last" ]]; then
    provisioning_check_add babel-archive degraded never-succeeded \
      "babel is configured here but has never archived successfully" \
      "babel archive status (then: babel archive push)"
    return 0
  fi
  if last_epoch="$(date -u -d "$last" +%s 2>/dev/null)"; then
    now="$(date -u +%s)"
    if ((now - last_epoch > 48 * 3600)); then
      provisioning_check_add babel-archive degraded archive-stale \
        "the last successful babel archive was $last" "babel archive status"
      return 0
    fi
  fi
  provisioning_check_add babel-archive ok "" "babel archived successfully at $last" ""
}

# Applicability and provisioned-ness both come from the runtime's own status,
# never re-derived here: the WSL and CUDA predicate belongs to the capability
# that needs it, and a second copy would be a second answer.
probe_local_qwen() {
  local status

  if ! status="$("$atyrode_runtime" status local-qwen --json 2>/dev/null)"; then
    provisioning_check_add local-qwen not-applicable capability-not-selected \
      "the local-qwen runtime is not available on this machine" ""
    return 0
  fi
  if [[ "$(jq -r '.applicable' <<<"$status")" != true ]]; then
    provisioning_check_add local-qwen not-applicable capability-not-selected \
      "$(jq -r '.reason' <<<"$status")" ""
  elif [[ "$(jq -r '.provisioned' <<<"$status")" == true ]]; then
    provisioning_check_add local-qwen ok "" \
      "local-qwen is provisioned at $(jq -r '.dataDir' <<<"$status")" ""
  else
    provisioning_unconfigured local-qwen \
      "this machine can host the model runtime but has not fetched it"
  fi
}

probe_manifold_agent() {
  if ! manifold_applicable; then
    provisioning_check_add manifold-agent not-applicable capability-not-selected \
      "requires a Linux host with the manifold-node capability installed" ""
  elif manifold_enrolled; then
    provisioning_check_add manifold-agent ok "" \
      "this machine is enrolled with the manifold hub" ""
  else
    provisioning_unconfigured manifold-agent \
      "the agent is installed but this machine is not enrolled with any hub"
  fi
}

# Never fails: an unconfigured optional surface is a to-do, not a fault, and a
# diagnostic that exits non-zero for one would make "this machine is fine"
# unsayable on any machine that declined something.
doctor_provisioning() {
  local json=0 result

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json=1
        shift
        ;;
      *) die "$EX_USAGE" "unknown doctor provisioning option: $1" ;;
    esac
  done
  collect_provisioning_checks
  result="$(jq -nc --argjson surfaces "$provisioning_checks" \
    '{schemaVersion:1,command:"doctor provisioning",
      pending:([$surfaces[]|select(.status=="incomplete")]|length),
      surfaces:$surfaces,mutationBoundary:"read-only probes"}')"
  if [[ "$json" == 1 ]]; then
    printf '%s\n' "$result"
  else
    jq -r '.surfaces[] | "\(.id): \(.status) — \(.summary)"' <<<"$result"
    jq -r '.surfaces[] | select(.remediation) | "  \(.id): \(.remediation)"' <<<"$result"
  fi
}

# The question an operator has is "what is missing on this machine", and until
# now answering it meant knowing which four families to run and in which order.
# The aggregate runs them all and keeps each one's own verdict: a required
# family that fails makes the whole run fail, while an unconfigured optional
# surface is reported and changes nothing -- otherwise every machine that
# declined a 40 GB model would report itself broken forever.
doctor_all() {
  local requested="" json=0 status=0 section

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json=1
        shift
        ;;
      --*) die "$EX_USAGE" "unknown doctor option: $1" ;;
      *)
        [[ -z "$requested" ]] || die "$EX_USAGE" "doctor accepts at most one host"
        requested="$1"
        shift
        ;;
    esac
  done

  if [[ "$json" == 1 ]]; then
    jq -nc \
      --argjson host "$(doctor_host "$requested" 1 || printf 'null')" \
      --argjson system "$(doctor_system "$requested" --json || printf 'null')" \
      --argjson git "$(doctor_git --json || printf 'null')" \
      --argjson tools "$(doctor_tools --json || printf 'null')" \
      --argjson provisioning "$(doctor_provisioning --json)" \
      '{schemaVersion:1,command:"doctor",
        ok:([$host,$system,$git,$tools]|all(. != null and (.ok != false))),
        host:$host,system:$system,git:$git,tools:$tools,
        provisioning:$provisioning}'
    return
  fi

  for section in host system git tools provisioning; do
    printf '\n%s\n' "$section"
    case "$section" in
      host) doctor_host "$requested" 0 || status=$? ;;
      system) doctor_system "$requested" || status=$? ;;
      git) doctor_git || status=$? ;;
      tools) doctor_tools || status=$? ;;
      provisioning) doctor_provisioning ;;
    esac
  done
  return "$status"
}
