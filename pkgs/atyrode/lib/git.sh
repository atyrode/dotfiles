# shellcheck shell=bash
#
# Git identity diagnostics -- remotes, agent, signing key, allowed signers,
# and the authentication key a forge is offered.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

actual_system() {
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_SYSTEM:-}" ]]; then
    printf '%s\n' "$_ATYRODE_TEST_SYSTEM"
    return
  fi
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) printf 'aarch64-darwin\n' ;;
    Darwin:x86_64) printf 'x86_64-darwin\n' ;;
    Linux:arm64 | Linux:aarch64) printf 'aarch64-linux\n' ;;
    Linux:x86_64) printf 'x86_64-linux\n' ;;
    *) die "$EX_UNAVAILABLE" "unsupported platform: $(uname -s) $(uname -m)" ;;
  esac
}

actual_user() {
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_USER:-}" ]]; then
    printf '%s\n' "$_ATYRODE_TEST_USER"
  else
    id -un
  fi
}

actual_home() {
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_HOME:-}" ]]; then
    printf '%s\n' "$_ATYRODE_TEST_HOME"
  else
    printf '%s\n' "${HOME:-}"
  fi
}

actual_hostname() {
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_HOSTNAME:-}" ]]; then
    printf '%s\n' "$_ATYRODE_TEST_HOSTNAME"
  else
    hostname -s 2>/dev/null || hostname
  fi
}

# One row of a doctor family's verdict. Every family (git, system) appends
# rows of this exact shape to its own accumulator, so the JSON a check reads
# is the same whichever family produced it.
check_row() { # id owner required status code summary remediation expected actual
  jq -nc \
    --arg id "$1" \
    --arg owner "$2" \
    --argjson required "$3" \
    --arg status "$4" \
    --arg code "$5" \
    --arg summary "$6" \
    --arg remediation "$7" \
    --argjson expected "$8" \
    --argjson actual "$9" \
    '{
      id: $id,
      owner: $owner,
      required: $required,
      status: $status,
      code: (if $code == "" then null else $code end),
      summary: $summary,
      remediation: (if $remediation == "" then null else $remediation end),
      expected: $expected,
      actual: $actual
    }'
}

git_checks='[]'

git_check_add() {
  git_checks="$(jq -c --argjson row "$(check_row "$@")" '. + [$row]' <<<"$git_checks")"
}

git_helper_is_store() {
  local helper="$1"
  [[ "$helper" =~ ^store([[:space:]]|$) ||
    "$helper" =~ (^|[[:space:]/])git-credential-store([[:space:]]|$) ]]
}

git_helper_is_gh() {
  local helper="$1"
  [[ "$helper" =~ (^|[[:space:]/])gh[[:space:]]+auth[[:space:]]+git-credential([[:space:]]|$) ]]
}

git_helper_is_secure() {
  local helper="$1"
  if git_helper_is_gh "$helper"; then
    return 0
  fi
  [[ "$helper" =~ ^(osxkeychain|libsecret|manager|manager-core)([[:space:]]|$) ||
    "$helper" =~ (^|[[:space:]/])git-credential-(osxkeychain|libsecret|manager|manager-core)([[:space:]]|$) ]]
}

git_forge_url_kind() {
  local url="$1" rest authority host scheme
  case "$url" in
    git@github.com:* | ssh://git@github.com/* | ssh://github.com/*)
      printf 'github-ssh\n'
      return
      ;;
    git@gitlab.com:* | ssh://git@gitlab.com/* | ssh://gitlab.com/*)
      printf 'gitlab-ssh\n'
      return
      ;;
    git://github.com/*)
      printf 'github-insecure\n'
      return
      ;;
    git://gitlab.com/*)
      printf 'gitlab-insecure\n'
      return
      ;;
    https://* | http://*)
      scheme="${url%%://*}"
      rest="${url#*://}"
      authority="${rest%%/*}"
      host="${authority##*@}"
      host="${host%%:*}"
      case "$host:$scheme" in
        github.com:https) printf 'github-https\n' ;;
        gitlab.com:https) printf 'gitlab-https\n' ;;
        github.com:http) printf 'github-insecure\n' ;;
        gitlab.com:http) printf 'gitlab-insecure\n' ;;
        *) printf 'other\n' ;;
      esac
      return
      ;;
  esac
  printf 'other\n'
}

# The identity Git offers a forge over SSH, read from the configuration Git
# itself consults, in Git's own precedence: GIT_SSH_COMMAND, core.sshCommand,
# GIT_SSH, then plain ssh. Nothing here is executed. The managed configuration
# writes `ssh -i <key> -o IdentitiesOnly=yes`, and that exact shape is the only
# one read for a key: a command of any other shape is somebody's own, and
# running it to ask what it would do is exactly what a diagnostic must not do.
#
# Prints one tab-separated line: source, shape, key. `source` is which of the
# four Git would use; `shape` is `managed` when a key was read, `custom` when a
# command exists but was not examined, `default` when ssh's own selection
# (agent, ~/.ssh/config, ~/.ssh/id_*) decides; `key` is the -i path or empty.
git_ssh_identity_selection() {
  local source="" line="" shape=custom key=""
  local -a tokens
  if [[ -n "${GIT_SSH_COMMAND+x}" ]]; then
    source=GIT_SSH_COMMAND
    line="$GIT_SSH_COMMAND"
  elif line="$(git config --get core.sshCommand 2>/dev/null)"; then
    source=core.sshCommand
  elif [[ -n "${GIT_SSH+x}" ]]; then
    source=GIT_SSH
    line="$GIT_SSH"
  else
    printf 'ssh\tdefault\t\n'
    return
  fi
  read -ra tokens <<<"$line"
  if [[ "$source" != GIT_SSH && "$line" != *$'\n'* && "${#tokens[@]}" == 5 &&
    ("${tokens[0]}" == ssh || "${tokens[0]}" =~ ^/nix/store/[A-Za-z0-9.+_-]+/bin/ssh$) &&
    "${tokens[1]}" == -i && "${tokens[2]}" =~ ^[A-Za-z0-9._/@~+:-]+$ &&
    ("${tokens[2]}" == /* || "${tokens[2]}" == '~/'*) &&
    "${tokens[3]}" == -o && "${tokens[4]}" == IdentitiesOnly=yes ]]; then
    shape=managed
    key="${tokens[2]}"
  fi
  printf '%s\t%s\t%s\n' "$source" "$shape" "$key"
}

# Whether Git in this directory would reach github.com over SSH: a remote URL
# already on SSH, or the managed pushInsteadOf that rewrites an HTTPS URL to
# one. Only then is a GitHub key registration worth asking about, and only
# github.com is asked. An ssh_config alias (`github:owner/repo`) is opaque to
# git_forge_url_kind and stays unclassified rather than guessed.
git_github_ssh_relevant() {
  local remote url
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r remote; do
      [[ -n "$remote" ]] || continue
      while IFS= read -r url; do
        [[ "$(git_forge_url_kind "$url")" != github-ssh ]] || return 0
      done < <({
        git remote get-url --all "$remote"
        git remote get-url --push --all "$remote"
      } 2>/dev/null)
    done < <(git remote 2>/dev/null || true)
  fi
  return 1
}

# GitHub's key list for the account gh holds on github.com, one `type blob`
# per line with the comment dropped, so a key compares by what it is rather
# than by what somebody named it. Announced and bounded: this is the one
# network call doctor git makes, and only when asked to. A non-zero exit or a
# body that is not a list of keys prints nothing and fails, and the caller
# treats that as unknown -- a denied scope or a dropped connection is not an
# absent key.
git_github_registered_keys() { # gh endpoint
  local gh="$1" endpoint="$2" body
  local -a argv=(timeout 20s "$gh" api --hostname github.com --paginate "$endpoint")
  show_command "${argv[@]}"
  body="$("${argv[@]}" 2>/dev/null)" || return 1
  # --paginate concatenates one array per page; anything else -- an error
  # object, an empty body -- is not a key list and must not read as one.
  jq -rs '
    if length >= 1 and all(.[]; type == "array") then add else error("malformed") end
    | if all(.[]; type == "object" and (.key | type) == "string") then . else error("malformed") end
    | map(.key | [scan("[^[:space:]]+")])
    | if all(.[]; length >= 2 and (.[0] | test("^(ssh-|ecdsa-|sk-)"))
        and (.[1] | test("^[A-Za-z0-9+/]+={0,3}$")))
      then .[] | "\(.[0]) \(.[1])" else error("malformed") end
  ' <<<"$body" 2>/dev/null
}

# Two rows: which key Git authenticates with, and whether github.com knows it
# as an authentication key. Both are kept apart from the signing rows because
# the powers are different (modules/shared/git-identity.nix): the key that
# registers a signature is not the key that opens the forge, and #573 was a
# machine whose signing key was registered while its authentication key was
# not. The first row is offline. The second reaches github.com only with
# online=1, only when GitHub is reached over SSH from here, and only for a key
# the first row identified.
doctor_git_authentication() { # online (0|1)
  local online="$1"
  local selection source shape auth_config="" auth_path="" auth_mode="" auth_readable=false
  local auth_permissions=false auth_valid=false auth_type="" auth_blob="" auth_fingerprint=""
  local public_line fleet_member=false signing_config="" signing_type="" signing_blob=""
  local same_as_signing=false github_ssh=false
  local expected actual status code summary remediation

  selection="$(git_ssh_identity_selection)"
  IFS=$'\t' read -r source shape auth_config <<<"$selection"
  if [[ -n "$auth_config" ]]; then
    auth_path="$(expand_home_path "$auth_config")"
  fi
  if [[ -n "$auth_path" && -f "$auth_path" && -r "$auth_path" ]]; then
    auth_readable=true
    auth_mode="$(stat -c '%a' -- "$auth_path" 2>/dev/null || true)"
    if [[ "$auth_mode" =~ ^[0-7]{3,4}$ ]] && (((8#$auth_mode & 8#077) == 0)); then
      auth_permissions=true
    fi
    if public_line="$(ssh-keygen -y -P "" -f "$auth_path" 2>/dev/null)"; then
      auth_valid=true
      IFS=' ' read -r auth_type auth_blob _ <<<"$public_line"
      auth_fingerprint="$(ssh-keygen -lf - <<<"$public_line" 2>/dev/null | awk '{ print $2 }' || true)"
    fi
  fi

  signing_config="$(git config --get user.signingKey 2>/dev/null || true)"
  [[ -z "$signing_config" ]] || fleet_member=true
  if [[ -n "$signing_config" ]] &&
    public_line="$(ssh-keygen -y -P "" -f "$(expand_home_path "$signing_config")" 2>/dev/null)"; then
    IFS=' ' read -r signing_type signing_blob _ <<<"$public_line"
    [[ "$auth_valid" == false || "$signing_type $signing_blob" != "$auth_type $auth_blob" ]] ||
      same_as_signing=true
  fi
  git_github_ssh_relevant && github_ssh=true

  expected='{"selected":true,"readable":true,"privateKey":true,"permissionsPrivate":true}'
  actual="$(jq -nc \
    --arg source "$source" \
    --arg shape "$shape" \
    --arg key "$auth_path" \
    --argjson readable "$auth_readable" \
    --argjson privateKey "$auth_valid" \
    --argjson permissionsPrivate "$auth_permissions" \
    --arg mode "$auth_mode" \
    --arg keyType "$auth_type" \
    --arg fingerprint "$auth_fingerprint" \
    --argjson sameAsSigningKey "$same_as_signing" \
    --argjson githubOverSsh "$github_ssh" \
    '{source:$source,shape:$shape,selected:($shape == "managed"),
      key:(if $key == "" then null else $key end),
      readable:$readable,privateKey:$privateKey,permissionsPrivate:$permissionsPrivate,
      mode:(if $mode == "" then null else $mode end),
      keyType:(if $keyType == "" then null else $keyType end),
      fingerprint:(if $fingerprint == "" then null else $fingerprint end),
      sameAsSigningKey:$sameAsSigningKey,githubOverSsh:$githubOverSsh}')"
  if [[ "$shape" == managed && "$auth_readable" == true && "$auth_valid" == true &&
    "$auth_permissions" == true ]]; then
    status=ok
    code=""
    summary="$source selects $auth_path for SSH authentication; SSH configuration may add other identities"
    remediation=""
  elif [[ "$shape" == managed ]]; then
    local identity_host
    identity_host="$(resolve_host 2>/dev/null)" || identity_host='<host>'
    status=failed
    code=authentication-key-invalid
    summary="$source selects $auth_path, which is missing, unreadable, not a private key, or readable by group or others"
    remediation="the key is a clan var placed by activation: on an operator device, clan vars generate $identity_host; then atyrode apply"
  elif [[ "$shape" == custom ]]; then
    status=warning
    code=ssh-command-unexamined
    summary="$source is a custom SSH command; doctor does not run it, so which key it offers a forge is unknown"
    remediation="unset it, or confirm by hand that it offers only this machine's placed authentication key"
  elif [[ "$fleet_member" == true && "$github_ssh" == true ]]; then
    status=failed
    code=authentication-key-unselected
    summary="Git reaches GitHub over SSH without a selected key: ssh will offer whatever the agent or ~/.ssh holds, so the forge may authenticate this machine as someone else"
    remediation="apply the current Home Manager generation; the managed git configuration sets core.sshCommand to the placed authentication key"
  elif [[ "$fleet_member" == true ]]; then
    status=not-applicable
    code=no-github-ssh
    summary="no SSH key is selected and this directory has no GitHub SSH remote to check"
    remediation=""
  else
    status=not-applicable
    code=not-fleet-member
    summary="no authentication key is selected: a portable profile is not a fleet member and reaches forges with the account's own ssh identity"
    remediation=""
  fi
  git_check_add authentication-key operator true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"

  # Registration on github.com. `checked` is true only when the account's key
  # list was read in full; every other outcome leaves the registration unknown
  # rather than absent.
  local gh="" checked=false registered=false signing_checked=false signing_only=false signing_registered=false
  local auth_keys="" signing_keys=""
  expected='{"registeredForAuthentication":true}'
  if [[ "$github_ssh" == false ]]; then
    status=not-applicable
    code=no-github-ssh
    summary="GitHub is not reached over SSH from here, so no key registration applies"
    remediation=""
  elif [[ "$auth_valid" == false ]]; then
    status=not-applicable
    code=no-selected-key
    summary="no single authentication key is identified, so there is nothing to look up on github.com"
    remediation=""
  elif [[ "$online" != 1 ]]; then
    status=not-applicable
    code=offline
    summary="github.com was not asked whether it knows the authentication key; rerun with --online to check"
    remediation=""
  elif ! gh="$(optional_host_command ATYRODE_GH gh)"; then
    status=warning
    code=registration-unverified
    summary="gh is unavailable, so whether github.com knows the authentication key is unknown"
    remediation="repair the managed gh installation, then rerun with --online"
  else
    say "asking github.com which keys the gh account holds; read-only, at most 20s per request"
    if auth_keys="$(git_github_registered_keys "$gh" user/keys)"; then
      checked=true
      ! grep -qxF "$auth_type $auth_blob" <<<"$auth_keys" || registered=true
      [[ -z "$signing_blob" ]] || ! grep -qxF "$signing_type $signing_blob" <<<"$auth_keys" ||
        signing_registered=true
      # Best effort: a denied read:ssh_signing_key scope only loses the
      # sharper diagnosis, never the verdict.
      if [[ "$registered" == false ]] &&
        signing_keys="$(git_github_registered_keys "$gh" user/ssh_signing_keys)"; then
        signing_checked=true
        ! grep -qxF "$auth_type $auth_blob" <<<"$signing_keys" || signing_only=true
      fi
    fi
    if [[ "$checked" == false ]]; then
      status=warning
      code=registration-unverified
      summary="github.com did not answer with the gh account's key list (not authenticated, scope denied, or unreachable), so the registration is unknown"
      remediation="give gh a github.com token with the read:public_key scope, then rerun with --online"
    elif [[ "$registered" == true ]]; then
      status=ok
      code=""
      summary="github.com knows the authentication key ${auth_fingerprint:-$auth_path} as an authentication key of the gh account"
      remediation=""
    elif [[ "$signing_only" == true ]]; then
      status=failed
      code=authentication-key-signing-only
      summary="the gh account holds ${auth_fingerprint:-$auth_path} only as a signing key, which does not grant SSH authentication"
      remediation="register the public half of $auth_path on github.com as an authentication key; a signing registration does not authenticate"
    else
      status=failed
      code=authentication-key-unregistered
      summary="github.com holds no authentication key matching ${auth_fingerprint:-$auth_path} for the gh account"
      [[ "$signing_registered" == false ]] ||
        summary="$summary; the signing key is registered for authentication instead, which does not help Git"
      remediation="register the public half of $auth_path on github.com as an authentication key for the account this machine pushes as"
    fi
  fi
  actual="$(jq -nc \
    --argjson online "$([[ "$online" == 1 ]] && echo true || echo false)" \
    --argjson checked "$checked" \
    --argjson registered "$registered" \
    --argjson signingOnly "$signing_only" \
    --argjson signingChecked "$signing_checked" \
    --argjson signingKeyRegisteredForAuthentication "$signing_registered" \
    --arg fingerprint "$auth_fingerprint" \
    '{online:$online,checked:$checked,
      registeredForAuthentication:(if $checked then $registered else null end),
      registeredAsSigningOnly:(if $signingChecked then $signingOnly else null end),
      signingKeyRegisteredForAuthentication:(if $checked then $signingKeyRegisteredForAuthentication else null end),
      fingerprint:(if $fingerprint == "" then null else $fingerprint end)}')"
  git_check_add authentication-registration gh true "$status" "$code" "$summary" "$remediation" \
    "$expected" "$actual"
}
