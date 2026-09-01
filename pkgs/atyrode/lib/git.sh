# shellcheck shell=bash
#
# Git identity diagnostics -- remotes, agent, signing key, allowed signers.
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

git_checks='[]'

git_check_add() {
  local id="$1" owner="$2" required="$3" status="$4" code="$5"
  local summary="$6" remediation="$7" expected="$8" actual="$9"

  git_checks="$(jq -c \
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
    }]' <<<"$git_checks")"
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
