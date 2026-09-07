# shellcheck shell=bash
set -u

fail() {
  printf 'development-image: %s\n' "$*" >&2
}

if [[ ! -d @homeDirectory@ ]]; then
  fail 'configured home /home/developer is missing'
  exit 1
fi
if [[ $(@stat@ -c %u @homeDirectory@) != 1000 ]]; then
  fail 'configured home /home/developer must be owned by UID 1000 (refusing to chown a possible host mount)'
  exit 1
fi

shutdown_signal=0
daemon_pid=
application_pid=
application_status=
forced_application=0

running() {
  local stat state parent _rest
  [[ -n $1 ]] || return 1
  # A command-substitution copy of Bash's job table can outlive a reaped child.
  # Read the kernel's state instead, and never signal a PID no longer owned here.
  IFS= read -r stat 2>/dev/null <"/proc/$1/stat" || return 1
  read -r state parent _rest <<<"${stat##*) }"
  [[ $parent == "$$" && $state != Z && $state != X ]]
}

# The INT/TERM traps invoke this callback asynchronously.
# shellcheck disable=SC2329
request_shutdown() {
  local signal=$1
  if ((shutdown_signal == 0)); then
    shutdown_signal=$2
    # Tini also forwards to the process group. Direct forwarding covers callers
    # signalling this supervisor alone without signalling unrelated processes.
    if running "$application_pid"; then kill -s "$signal" "$application_pid" 2>/dev/null || :; fi
    if running "$daemon_pid"; then kill -s "$signal" "$daemon_pid" 2>/dev/null || :; fi
  fi
}
trap 'request_shutdown INT 130' INT
trap 'request_shutdown TERM 143' TERM

# Neither daemon startup nor readiness may consult the developer's Nix config
# or create a root-owned evaluation cache below the developer's home.
root_environment=(
  @env@ -i
  'PATH=@runtimePath@'
  HOME=/root USER=root LOGNAME=root
  NIX_CONF_DIR=/etc/nix NIX_USER_CONF_FILES=/dev/null
  LANG=C.UTF-8
  'SSL_CERT_FILE=@caFile@' 'NIX_SSL_CERT_FILE=@caFile@'
)
@mkdir@ -p /root || exit 1
@chmod@ 0700 /root || exit 1

cleanup() {
  local pid deadline
  for pid in "$application_pid" "$daemon_pid"; do
    if running "$pid"; then kill -TERM "$pid" 2>/dev/null || :; fi
  done
  deadline=$((SECONDS + 5))
  while running "$application_pid" || running "$daemon_pid"; do
    ((SECONDS < deadline)) || break
    @sleep@ 0.1
  done
  for pid in "$application_pid" "$daemon_pid"; do
    if running "$pid"; then
      [[ $pid != "$application_pid" ]] || forced_application=1
      kill -KILL "$pid" 2>/dev/null || :
    fi
  done
  if [[ -n $application_pid && -z $application_status ]]; then
    # A trapped signal can interrupt wait before the child has actually exited.
    while :; do
      wait "$application_pid"
      application_status=$?
      running "$application_pid" || break
    done
  fi
  if [[ -n $daemon_pid ]]; then
    while :; do
      wait "$daemon_pid" 2>/dev/null
      running "$daemon_pid" || break
    done
  fi
}

"${root_environment[@]}" @nixDaemon@ </dev/null &
daemon_pid=$!
deadline=$((SECONDS + 10))
ready=0
while ((shutdown_signal == 0 && SECONDS < deadline)); do
  if ! running "$daemon_pid"; then
    fail 'Nix daemon exited before readiness'
    break
  fi
  if "${root_environment[@]}" @timeout@ --kill-after=0.2s 0.5s \
    @nix@ path-info --store daemon @activationPackage@ >/dev/null 2>&1; then
    ready=1
    break
  fi
  @sleep@ 0.1
done
if ((shutdown_signal != 0)); then
  cleanup
  exit "$shutdown_signal"
fi
if ((ready == 0)); then
  fail 'Nix daemon did not become ready within 10 seconds'
  cleanup
  exit 1
fi
if ! running "$daemon_pid"; then
  fail 'Nix daemon exited before session startup'
  cleanup
  exit 1
fi

# Asynchronous commands otherwise inherit /dev/null as stdin in a noninteractive
# Bash script. Keep the container TTY attached to the actual user session.
@setpriv@ --reuid=1000 --regid=1000 --init-groups @session@ "$@" <&0 &
application_pid=$!
result=1
while :; do
  if ((shutdown_signal != 0)); then break; fi
  finished=
  wait -n -p finished "$application_pid" "$daemon_pid"
  status=$?
  if [[ ${finished:-} == "$application_pid" ]]; then
    application_status=$status
    result=$status
    break
  fi
  if ((shutdown_signal != 0)); then break; fi
  # Prefer an already completed application's status when both children exit
  # together; an exited daemon is fatal only while the application is live.
  if ! running "$application_pid"; then
    wait "$application_pid"
    application_status=$?
    result=$application_status
    break
  fi
  if [[ ${finished:-} == "$daemon_pid" ]] || ! running "$daemon_pid"; then
    fail 'Nix daemon exited unexpectedly while the application was running'
    result=1
    break
  fi
done
cleanup
if ((shutdown_signal != 0)); then
  if ((forced_application != 0)); then exit "$shutdown_signal"; fi
  exit "${application_status:-$shutdown_signal}"
fi
exit "$result"
