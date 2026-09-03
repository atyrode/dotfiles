# shellcheck shell=bash
#
# Diagnostics. Every family here observes and none of them mutate; that
# rule is asserted structurally in checks/atyrode/atyrode-apply.nix.
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
    elif [[ "$expected" == false ]]; then
      # Absent because this machine does not ask for it or cannot have it at
      # all, which is what every other family calls not-applicable. Reporting
      # it as missing invites an operator to repair a machine that is already
      # correct: bwrap is a Linux kernel facility, and no amount of applying
      # will put one on a Mac.
      status=not-applicable
      path=''
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

# The daemon configuration lines that enrol a standalone Linux host in the
# fleet cache. `extra-` appends to Nix's built-in defaults, so the file never
# has to restate the official cache and the result is exactly the reviewed
# order: official first, fleet second. Bootstrap writes these on a new machine;
# doctor quotes them when an existing machine lacks them.
fleet_cache_conf_lines() {
  jq -r '"extra-substituters = \(.nix.fleetCache.substituter)",
    "extra-trusted-public-keys = \(.nix.fleetCache.trustedPublicKey)"' "$system_policy"
}

# The one privileged line that enrols a standalone Linux daemon in the fleet
# cache, shell-quoted so it can be pasted back verbatim. The daemon trusts
# only root, so a user nix.conf cannot add a key - the daemon ignores
# restricted settings from an untrusted client - and the file the daemon
# reads is the one place the fix can go; it reads that file at start only, so
# the restart is part of the same line. It lives outside the probe because
# probes only observe: this is text handed to the operator, never run here.
fleet_cache_enrolment_command() {
  local line quoted=""

  while IFS= read -r line; do
    quoted+=" '${line//\'/\'\\\'\'}'"
  done < <(fleet_cache_conf_lines)
  printf '%s%s%s\n' "printf '%s\\n'" "$quoted" \
    " | sudo tee -a /etc/nix/nix.conf >/dev/null && sudo systemctl restart nix-daemon"
}

probe_nix_policy() {
  local data="$1" platform="$2" owner config_json='{}'
  local trusted_exact=false substituters_exact=false keys_exact=false signatures=false optimiser=false
  local status code summary remediation expected_json actual_json expected_users
  local expected_substituters expected_keys

  owner="$(nix_system_owner "$data" "$platform")"
  expected_users="$(jq -c 'select(.nixTrustedUsers != null) | .nixTrustedUsers | sort' <<<"$data")"
  if [[ -z "$expected_users" ]]; then
    expected_users="$(jq -c '.nix.trustedUsers | sort' "$system_policy")"
  fi
  # Order matters and is part of the contract: Nix asks substituters in the
  # listed order, and the official cache answers for almost every path.
  expected_substituters="$(jq -c '[.nix.substituter, .nix.fleetCache.substituter]' "$system_policy")"
  expected_keys="$(jq -c '[.nix.trustedPublicKey, .nix.fleetCache.trustedPublicKey]' "$system_policy")"
  if has_system_fixture; then
    trusted_exact="$(jq -r '.nix.trustedUsersExact // false' <<<"$system_fixture")"
    substituters_exact="$(jq -r '.nix.substitutersExact // false' <<<"$system_fixture")"
    keys_exact="$(jq -r '.nix.trustedKeysExact // false' <<<"$system_fixture")"
    signatures="$(jq -r '.nix.signaturesRequired // false' <<<"$system_fixture")"
    optimiser="$(jq -r '.nix.optimiserScheduled // false' <<<"$system_fixture")"
  else
    config_json="$(nix config show --json 2>/dev/null || printf '{}')"
    jq -e --argjson expected "$expected_users" \
      '.["trusted-users"].value | sort == $expected' <<<"$config_json" >/dev/null && trusted_exact=true
    jq -e --argjson expected "$expected_substituters" \
      '.["substituters"].value == $expected' <<<"$config_json" >/dev/null && substituters_exact=true
    jq -e --argjson expected "$expected_keys" \
      '.["trusted-public-keys"].value == $expected' <<<"$config_json" >/dev/null && keys_exact=true
    jq -e '.["require-sigs"].value == true' <<<"$config_json" >/dev/null && signatures=true
    if [[ "$platform" == darwin ]] && /bin/launchctl print \
      "system/$(jq -r '.nix.darwinOptimiserLabel' "$system_policy")" >/dev/null 2>&1; then
      optimiser=true
    fi
  fi

  # Expected carries the reviewed public strings from the inventory; actual
  # stays boolean so a machine's raw substituter list, which may hold a
  # credentialed URL, never reaches the diagnostic.
  expected_json="$(jq -nc --argjson trustedUsers "$expected_users" \
    --argjson substituters "$expected_substituters" --argjson trustedPublicKeys "$expected_keys" \
    --argjson scheduled "$([[ "$platform" == darwin ]] && echo true || echo false)" \
    '{trustedUsers:$trustedUsers,substituters:$substituters,trustedPublicKeys:$trustedPublicKeys,
      signaturesRequired:true,optimiserScheduled:$scheduled}')"
  actual_json="$(jq -nc --argjson trustedUsersExact "$trusted_exact" \
    --argjson substitutersExact "$substituters_exact" --argjson trustedKeysExact "$keys_exact" \
    --argjson signaturesRequired "$signatures" --argjson optimiserScheduled "$optimiser" \
    '{trustedUsersExact:$trustedUsersExact,substitutersExact:$substitutersExact,
      trustedKeysExact:$trustedKeysExact,signaturesRequired:$signaturesRequired,
      optimiserScheduled:$optimiserScheduled}')"
  if [[ "$trusted_exact" == true && "$substituters_exact" == true && "$keys_exact" == true &&
    "$signatures" == true && ("$platform" != darwin || "$optimiser" == true) ]]; then
    status=ok
    code=""
    summary="Nix trust, signed caches, and optimisation ownership match policy"
    remediation=""
  else
    status=incomplete
    code="nix-policy-drift"
    summary="effective Nix daemon policy differs from the reviewed system boundary"
    if [[ "$owner" == system && "$trusted_exact" == true && "$signatures" == true ]]; then
      # Only the cache lists drift, on a host where no Nix configuration layer
      # owns the daemon's file, so the remediation is the exact line rather
      # than a pointer to a configuration nobody has.
      remediation="the daemon does not list the fleet cache; enrol it with: $(fleet_cache_enrolment_command)"
    else
      remediation="repair the owning nix-darwin or NixOS/Nix-daemon configuration; do not use a user nix.conf override"
    fi
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

# Where the files bootstrap repairs live. A build sandbox is not root of a
# real /etc and a probe that read the builder's would answer for the wrong
# machine, so a scenario relocates the tree through this seam exactly as
# bootstrap/install.sh relocates its own.
bootstrap_etc_root() {
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_ETC_ROOT:-}" ]]; then
    printf '%s' "$_ATYRODE_TEST_ETC_ROOT"
  else
    printf '/etc'
  fi
}

# The residue of an interrupted or superseded Nix installation on macOS.
# bootstrap/install.sh repairs these states before Nix exists, which is the
# only moment it can; nothing re-examined them afterwards, so a machine that
# installed successfully years ago could carry any of them and never be told.
# Detection is not repair and belongs where the knowledge is shared: this
# probe reads the same paths install.sh's detectors read, and names the
# command that repairs what it finds.
#
# The sixth state install.sh knows, an orphaned Nix Store volume, is
# deliberately absent: its own detector requires the store database to be
# missing, and a machine running this CLI out of the store always has one.
probe_bootstrap_residue() { # platform host
  local platform="$1" host="$2" etc target backup entry link_target named
  local -a backups=() unrecognised=() stale_links=() anchors=()
  local fstab="" status code summary remediation expected_json actual_json

  expected_json='{"shellProfileBackups":[],"unrecognisedProfiles":[],"staleEtcLinks":[],"brokenTrustAnchors":[],"staleFstabEntry":null}'
  if [[ "$platform" != darwin ]]; then
    actual_json='{"shellProfileBackups":null,"unrecognisedProfiles":null,"staleEtcLinks":null,"brokenTrustAnchors":null,"staleFstabEntry":null}'
    system_check_add bootstrap-residue bootstrap false not-applicable platform-not-darwin \
      "the states bootstrap repairs are macOS system state" "" "$expected_json" "$actual_json"
    return
  fi
  etc="$(bootstrap_etc_root)"

  # A backup identical to its target is what a completed install leaves
  # behind; one that differs is an original the install never restored.
  for target in "$etc/bashrc" "$etc/profile.d/nix.sh" "$etc/zshrc" \
    "$etc/bash.bashrc" "$etc/zsh/zshrc"; do
    backup="$target.backup-before-nix"
    [[ -e "$backup" ]] || continue
    [[ -e "$target" ]] && cmp -s "$backup" "$target" && continue
    backups+=("$target")
  done

  # A regular file carrying the installer's marker where nix-darwin expects
  # to own a link: activation will refuse until it is moved aside.
  for target in "$etc/bashrc" "$etc/zshrc" "$etc/bash.bashrc" "$etc/zsh/zshrc"; do
    [[ -f "$target" && ! -L "$target" ]] || continue
    grep -q '^# End Nix$' "$target" 2>/dev/null || continue
    unrecognised+=("$target")
  done

  # Links into a store path or /etc/static that resolve to nothing: the
  # generation they named is gone and every reader of them fails.
  if [[ -d "$etc" ]]; then
    while IFS= read -r entry; do
      [[ -L "$entry" && ! -e "$entry" ]] || continue
      link_target="$(readlink "$entry" 2>/dev/null)" || continue
      case "$link_target" in
        /nix/store/* | /etc/static | /etc/static/* | */etc/static | */etc/static/*) ;;
        *) continue ;;
      esac
      stale_links+=("$entry")
    done < <(find -H "$etc" -type l 2>/dev/null | LC_ALL=C sort)
  fi

  # The TLS anchors Nix reads. Unreadable or empty is the state that turns
  # every substituter into a download failure with no obvious cause. A path
  # nix.conf names answers for itself whether or not it is there; the
  # conventional one answers only once something occupies it, because a
  # machine that keeps its anchors elsewhere is not broken.
  # A machine with no nix.conf names nothing, which is not a failure: under
  # pipefail the missing file would otherwise end this probe in silence.
  named="$(awk '$1 == "ssl-cert-file" { print $3 }' "$etc/nix/nix.conf" 2>/dev/null | tail -n 1 || true)"
  for target in "$etc/ssl/certs/ca-certificates.crt" "$named"; do
    [[ -n "$target" ]] || continue
    case "$target" in "$etc"/*) ;; *) continue ;; esac
    [[ "$target" == "$named" || -e "$target" || -L "$target" ]] || continue
    [[ -r "$target" && -s "$target" ]] && continue
    word_in_list "$target" "${anchors[*]-}" && continue
    anchors+=("$target")
  done

  # An fstab line mounting /nix from a volume UUID that no longer resolves
  # leaves the machine unbootable into its own store.
  if [[ -f "$etc/fstab" && ! -L "$etc/fstab" ]]; then
    local uuid
    uuid="$(awk '$2 == "/nix" && $3 == "apfs" {
        for (i = 1; i <= NF; i++)
          if ($i ~ /^UUID=/) { sub(/^UUID=/, "", $i); print $i; exit }
      }' "$etc/fstab")"
    if [[ -n "$uuid" ]] && ! diskutil info "$uuid" >/dev/null 2>&1; then
      fstab="$etc/fstab"
    fi
  fi

  actual_json="$(jq -nc \
    --args '{shellProfileBackups:$ARGS.positional}' "${backups[@]+"${backups[@]}"}")"
  actual_json="$(jq -nc --argjson base "$actual_json" \
    --args '$base + {unrecognisedProfiles:$ARGS.positional}' "${unrecognised[@]+"${unrecognised[@]}"}")"
  actual_json="$(jq -nc --argjson base "$actual_json" \
    --args '$base + {staleEtcLinks:$ARGS.positional}' "${stale_links[@]+"${stale_links[@]}"}")"
  actual_json="$(jq -nc --argjson base "$actual_json" \
    --args '$base + {brokenTrustAnchors:$ARGS.positional}' "${anchors[@]+"${anchors[@]}"}")"
  actual_json="$(jq -nc --argjson base "$actual_json" --arg fstab "$fstab" \
    '$base + {staleFstabEntry:(if $fstab == "" then null else $fstab end)}')"

  if jq -e '[.shellProfileBackups,.unrecognisedProfiles,.staleEtcLinks,.brokenTrustAnchors]
      | all(length == 0)' <<<"$actual_json" >/dev/null && [[ -z "$fstab" ]]; then
    status=ok
    code=""
    summary="no residue from an interrupted or superseded Nix installation"
    remediation=""
  else
    status=incomplete
    code="bootstrap-residue"
    summary="$(jq -r '[
        (.shellProfileBackups | length | if . > 0 then "\(.) shell rc backup(s)" else empty end),
        (.unrecognisedProfiles | length | if . > 0 then "\(.) unrecognised /etc profile(s)" else empty end),
        (.staleEtcLinks | length | if . > 0 then "\(.) stale /etc link(s)" else empty end),
        (.brokenTrustAnchors | length | if . > 0 then "\(.) unusable TLS trust anchor(s)" else empty end),
        (if .staleFstabEntry then "an fstab entry naming a volume that is gone" else empty end)
      ] | join(", ")' <<<"$actual_json") from an earlier Nix installation"
    remediation="see what would change, then repair: $HOME/nix-dotfiles/bootstrap/install.sh plan --config $host, then the same with apply"
  fi
  system_check_add bootstrap-residue bootstrap true "$status" "$code" "$summary" "$remediation" \
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
  probe_bootstrap_residue "$platform" "$host"
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

# The archive's storage document is a clan var placed by activation, so this
# probe never offers a ceremony: a portable profile cannot have it, a clan
# machine either has the placed document or is owed a generation on an
# operator device, and a configured machine is judged by its last success.
# `-f` follows the link Home Manager installs, so a document not yet placed
# reads as absent exactly as it did before the value existed.
probe_babel_archive() {
  local host config_file stamp_file last="" last_epoch now

  host="$(resolve_host)"
  if [[ "$(jq -r '.identityMode // "fixed"' <<<"$(host_json "$host")")" == runtime ]]; then
    provisioning_check_add babel-archive not-applicable portable-profile \
      "a portable profile is not a clan machine, so no storage document is generated for it" ""
    return 0
  fi
  config_file="${XDG_CONFIG_HOME:-$HOME/.config}/babel/storage.json"
  stamp_file="${XDG_STATE_HOME:-$HOME/.local/state}/babel/last-success"
  if [[ ! -f "$config_file" ]]; then
    provisioning_check_add babel-archive degraded not-generated \
      "no storage document at $config_file; the hourly timer archives nothing until activation places it" \
      "clan vars generate $host (on an operator device), then atyrode apply"
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

# One family's JSON for the aggregate. Findings are exit 69 with complete
# output and are kept; only a family that could not report at all becomes
# null, so the aggregate stays valid JSON and `ok` still reads false.
doctor_family_json() { # function argv...
  local out status=0
  out="$("$@")" || status=$?
  if [[ -n "$out" && ("$status" == 0 || "$status" == "$EX_UNAVAILABLE") ]]; then
    printf '%s' "$out"
  else
    printf 'null'
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
    # A family exits 69 when it has findings and its JSON is complete; that is
    # the common case on a real machine, not an error. Appending `null` to
    # output that was already printed produced `{...}null`, which is what made
    # `doctor --json` -- and the cockpit that reads it -- fail on every host
    # with a single finding while passing on the pristine fixtures.
    jq -nc \
      --argjson host "$(doctor_family_json doctor_host "$requested" 1)" \
      --argjson system "$(doctor_family_json doctor_system "$requested" --json)" \
      --argjson git "$(doctor_family_json doctor_git --json)" \
      --argjson tools "$(doctor_family_json doctor_tools --json)" \
      --argjson provisioning "$(doctor_family_json doctor_provisioning --json)" \
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
