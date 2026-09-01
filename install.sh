#!/usr/bin/env bash
set -Eeuo pipefail

# The bootstrap intentionally stays compatible with Bash 3.2 and platform
# tools because it runs before the managed Nix environment exists.

readonly REPO_HTTPS_URL="https://github.com/atyrode/dotfiles.git"
readonly REPO_SSH_URL="git@github.com:atyrode/dotfiles.git"
readonly NIX_VERSION="2.34.7"
readonly PROFILE_BACKUP_SUFFIX=".backup-before-nix"
readonly NIX_VOLUME_LABEL="Nix Store"
readonly ISSUE_URL="https://github.com/atyrode/dotfiles/issues/new"
readonly BOOTSTRAP_TEST_HOOKS=0

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
COMMAND="${1:-}"
if [[ -n "$COMMAND" ]]; then
  shift
fi

DOTFILES_DIR="${DOTFILES_DIR:-$SCRIPT_DIR}"
FLAKE_CONFIG="${FLAKE_CONFIG:-}"
ALLOW_DIRTY=0
ALLOW_NON_MAIN=0
UPDATE_SOURCE=0
ASSUME_YES=0
SYSTEM=""
NIX_URL=""
NIX_SHA256=""
SOURCE_CHANGED=0
SOURCE_UPDATED=0
STALE_PROFILE_BACKUPS=()
STALE_ETC_LINKS=()
UNRECOGNISED_ETC_PROFILES=()
ETC_ACTIVATION_CONFLICTS=()
BROKEN_TRUST_ANCHORS=()
STALE_FSTAB_ENTRY=""
ORPHANED_NIX_VOLUME=""
ORPHANED_NIX_VOLUME_UUID=""
MOUNT_FAILURE=""
RUN_LOG=""
# Set when `atyrode doctor` completed the machine but still named work. Read by
# the completion notice, which prints on the operator's terminal rather than
# inside a captured step.
DOCTOR_FINDINGS=0

# Colour is a reading aid, never data. It is on only where the stream is a
# terminal and the environment permits it, so pipes, redirects, and the check
# harness receive exactly the bytes they assert on. Same gate and same palette
# as the atyrode CLI, so one machine speaks with one voice: 1 bold, 2 dim,
# 33 warning, 36 a value or a path, 1;36 a command to type, 1;31 a failure,
# 1;32 a success.
COLOR_OUT=0
COLOR_ERR=0
init_color() {
  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && -n "${BOOTSTRAP_TEST_COLOR:-}" ]]; then
    if [[ "$BOOTSTRAP_TEST_COLOR" == 1 ]]; then
      COLOR_OUT=1
      COLOR_ERR=1
    fi
    return 0
  fi
  [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]] || return 0
  [[ ! -t 1 ]] || COLOR_OUT=1
  [[ ! -t 2 ]] || COLOR_ERR=1
  return 0
}

# Two painters rather than one, because the two streams are decided separately:
# `plan | less` must stay plain while a failure on the terminal beside it stays
# red. Both degrade to bare text, so no message depends on colour to be read.
paint() {
  local code="$1"

  shift
  if [[ "$COLOR_OUT" == 1 ]]; then
    printf '\033[%sm%s\033[0m' "$code" "$*"
  else
    printf '%s' "$*"
  fi
}

paint_err() {
  local code="$1"

  shift
  if [[ "$COLOR_ERR" == 1 ]]; then
    printf '\033[%sm%s\033[0m' "$code" "$*"
  else
    printf '%s' "$*"
  fi
}

# Every command that changes this machine, reaches the network, or takes real
# time is printed before it runs. An operator watching a bootstrap should never
# have to guess which program produced the next thousand lines of output, and
# the transcript it leaves should be enough to repeat any step by hand. The
# rendering is shell-quoted for exactly that reason: what is shown is what can
# be pasted back. Silent steps are the reason a failure ever looks inexplicable.
show_command() {
  local rendered="" part

  for part in "$@"; do
    rendered="$rendered${rendered:+ }$(printf '%q' "$part")"
  done
  printf '%s\n' "$(paint_err 2 "\$ $rendered")" >&2
}

run_visible() {
  show_command "$@"
  "$@"
}

die() {
  printf '%s %s\n' "$(paint_err '1;31' 'bootstrap:')" "$*" >&2
  return 1
}

# Every state an operator can land in carries a stable code. The code is the
# handle for improving this script: it names one machine state, it is
# greppable in docs/bootstrap.md, and an unrecognised one is a request for a
# new repair rather than a wall of prose and a dead end.
fail() {
  local code="$1" message="$2" remedy="${3:-}"

  printf '%s %s %s\n' "$(paint_err '1;31' 'bootstrap:')" \
    "$(paint_err '1;31' "[$code]")" "$message" >&2
  [[ -z "$remedy" ]] || printf '  %s %s\n' "$(paint_err 1 'next:')" "$remedy" >&2
  [[ -z "$RUN_LOG" ]] || printf '  %s %s\n' "$(paint_err 2 'log:')" "$(paint_err 36 "$RUN_LOG")" >&2
  printf '  %s\n' \
    "$(paint_err 2 "unrecognised states belong at $ISSUE_URL, with the code and the log.")" >&2
  log_event "failed $code: $message"
  return 1
}

# The terminal shows progress; the log keeps the detail a later diagnosis
# needs. Logging never fails a run: a machine too broken to write state is
# still allowed to attempt its own repair.
log_event() {
  [[ -n "$RUN_LOG" ]] || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$RUN_LOG" 2>/dev/null || true
}

# A machine state that needs a round trip to diagnose costs a release cycle,
# and the facts that resolve one are cheap to collect while the failure is
# still on the machine. Every failure records them, so an unrecognised code
# arrives with its evidence instead of requiring another run to produce it.
log_diagnostics() {
  local source path

  [[ -n "$RUN_LOG" ]] || return 0
  {
    printf -- '--- diagnostics ---\n'
    printf 'system: %s\n' "$SYSTEM"
    printf 'nix: %s\n' "$(command -v nix || printf 'absent')"
    printf 'PATH: %s\n' "$PATH"
    printf 'NIX_SSL_CERT_FILE: %s\n' "${NIX_SSL_CERT_FILE:-unset}"
    printf 'SSL_CERT_FILE: %s\n' "${SSL_CERT_FILE:-unset}"
    printf 'profile CA bundle: %s\n' "$(stat_path "$(trust_anchor_bundle)")"
    while IFS=$'\t' read -r source path; do
      printf 'trust anchor named by %s: %s -> %s\n' "$source" "$path" "$(stat_path "$path")"
    done < <(trust_anchor_candidates)
    printf -- '--- end diagnostics ---\n'
  } >>"$RUN_LOG" 2>/dev/null || true
}

# Reports what a path is without following it, so a dangling link reads as a
# dangling link rather than as a missing file.
stat_path() {
  local path="$1"

  if [[ -L "$path" ]]; then
    if [[ -e "$path" ]]; then
      printf 'link -> %s\n' "$(readlink "$path" 2>/dev/null)"
    else
      printf 'dangling link -> %s\n' "$(readlink "$path" 2>/dev/null)"
    fi
  elif [[ -e "$path" ]]; then
    printf 'file\n'
  else
    printf 'absent\n'
  fi
}

# Only called once the state root has been validated, so this never creates
# anything through an unsafe path.
start_run_log() {
  local dir

  dir="$(bootstrap_state_root)/logs"
  [[ ! -L "$dir" ]] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  RUN_LOG="$dir/$(date -u +%Y%m%dT%H%M%SZ)-${COMMAND:-run}.log"
  if ! : >"$RUN_LOG" 2>/dev/null; then
    RUN_LOG=""
    return 0
  fi
  chmod 600 "$RUN_LOG" 2>/dev/null || true
  log_event "bootstrap $COMMAND for $FLAKE_CONFIG on $SYSTEM at $DOTFILES_DIR"
}

# Repairs mutate a machine bootstrap did not create, so each records how to
# put back exactly what it changed. Reversibility is the constraint that
# decides repair design: nothing here may destroy state it cannot
# reconstruct, which is why the volume repair renames instead of deleting.
repair_state_dir() {
  printf '%s\n' "$(bootstrap_state_root)/repairs"
}

journal_repair() {
  local note="$1" undo="$2" dir log

  dir="$(repair_state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  log="$dir/undo.log"
  printf '%s\t%s\tundo: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$note" "$undo" \
    >>"$log" 2>/dev/null || true
  chmod 600 "$log" 2>/dev/null || true
  log_event "repaired: $note (undo: $undo)"
}

GIT_AUTH_MODE="${ATYRODE_GIT_AUTH_MODE:-ssh}"
case "$GIT_AUTH_MODE" in
  ssh | https-gh) ;;
  *) die "ATYRODE_GIT_AUTH_MODE must be ssh or https-gh" ;;
esac

usage() {
  cat <<'EOF'
Usage:
  ./install.sh preflight [OPTIONS]
  ./install.sh plan [OPTIONS]
  ./install.sh apply [OPTIONS]
  ./install.sh recover [OPTIONS]
  ./install.sh verify [OPTIONS]

Options:
  --repo PATH          Use this existing checkout (default: script checkout).
  --config HOST        Select a registered host explicitly.
  --update             Fetch origin and fast-forward main before activation.
  --allow-dirty        Intentionally use a checkout with local changes.
  --allow-non-main     Intentionally use a branch or detached revision other than main.
  --yes                Confirm apply or recover without an interactive prompt.
  -h, --help           Show this help.

Inside a standard Coder workspace, a no-command invocation selects this
repository's architecture-specific portable profile. Elsewhere, run `plan`,
inspect it, then run `apply`.

`recover` is the exit when a state has no repair: on macOS it resets this
machine's Nix installation - daemon, /etc/nix, and the store volume, each
archived or renamed rather than deleted - then installs Nix fresh and
activates normally.
EOF
}

parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires a path"
        DOTFILES_DIR="$2"
        shift 2
        ;;
      --config)
        [[ $# -ge 2 ]] || die "--config requires a registered host"
        FLAKE_CONFIG="$2"
        shift 2
        ;;
      --update)
        UPDATE_SOURCE=1
        shift
        ;;
      --allow-dirty)
        ALLOW_DIRTY=1
        shift
        ;;
      --allow-non-main)
        ALLOW_NON_MAIN=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

detect_system() {
  # The macOS repairs below are unreachable on a Linux runner, so the check
  # harness forces the platform to exercise them everywhere rather than only
  # in the one native CI job. Inert in production, like every hook here.
  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && -n "${BOOTSTRAP_FORCE_SYSTEM:-}" ]]; then
    printf '%s\n' "$BOOTSTRAP_FORCE_SYSTEM"
    return 0
  fi
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) printf 'aarch64-darwin\n' ;;
    Linux:arm64 | Linux:aarch64) printf 'aarch64-linux\n' ;;
    Linux:x86_64) printf 'x86_64-linux\n' ;;
    *) die "unsupported system: $(uname -s) $(uname -m)" ;;
  esac
}

configure_coder_runtime() {
  if [[ -n "$COMMAND" ]]; then
    return 0
  fi
  if [[ -z "${CODER_WORKSPACE_NAME:-}" || -z "${CODER_AGENT_URL:-}" ]]; then
    return 0
  fi

  SYSTEM="$(detect_system)"
  COMMAND=apply
  FLAKE_CONFIG="development-$SYSTEM"
  ASSUME_YES=1

  # Coder-style deployments provision GitHub's HTTPS credential helper
  # independently of dotfiles. Prefer it when it is already usable;
  # otherwise retain the normal SSH-first policy.
  if [[ -z "${ATYRODE_GIT_AUTH_MODE:-}" ]] &&
    command -v gh >/dev/null 2>&1 &&
    gh auth status >/dev/null 2>&1; then
    GIT_AUTH_MODE=https-gh
  fi
}

select_nix_artifact() {
  case "$SYSTEM" in
    aarch64-darwin)
      NIX_SHA256="71e18301c4ea78c667f2753159156b5bdb899993720e8aa7bcca97e8312d3d6b"
      ;;
    aarch64-linux)
      NIX_SHA256="f1cee64ae7a02330c6421924c28f597c41813f2214ff108622087d8056378b08"
      ;;
    x86_64-linux)
      NIX_SHA256="eafe5042404e818505e28c5ca3d0885f3ec45c31f955489a25bb38258f87560e"
      ;;
    *) die "no pinned Nix artifact for $SYSTEM" ;;
  esac
  [[ "$NIX_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    die "pinned Nix SHA-256 for $SYSTEM is malformed"
  NIX_URL="https://releases.nixos.org/nix/nix-${NIX_VERSION}/nix-${NIX_VERSION}-${SYSTEM}.tar.xz"
}

source_nix() {
  local profile=""

  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && "${BOOTSTRAP_NIX_PROFILE_SCRIPT+x}" == x ]]; then
    profile="${BOOTSTRAP_NIX_PROFILE_SCRIPT:-}"
  elif [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    profile="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
  elif [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    profile="$HOME/.nix-profile/etc/profile.d/nix.sh"
  fi
  if [[ -n "$profile" && -f "$profile" ]]; then
    set +u
    # shellcheck disable=SC1090 # The selected Nix profile script is runtime-dependent.
    . "$profile"
    set -u
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

canonicalize_repo() {
  [[ -d "$DOTFILES_DIR" ]] || die "repository directory does not exist: $DOTFILES_DIR"
  DOTFILES_DIR="$(CDPATH='' cd -- "$DOTFILES_DIR" && pwd -P)"
}

verify_origin() {
  local origin resolved

  origin="$(git -C "$DOTFILES_DIR" config --get remote.origin.url 2>/dev/null || true)"
  case "$origin" in
    "$REPO_HTTPS_URL" | "${REPO_HTTPS_URL%.git}" | "$REPO_SSH_URL" | ssh://git@github.com/atyrode/dotfiles.git)
      ;;
    '') die "checkout has no origin remote; expected $REPO_HTTPS_URL" ;;
    *) die "checkout origin is not atyrode/dotfiles; refusing to fetch or activate it" ;;
  esac
  resolved="$(git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null || true)"
  case "$resolved" in
    "$REPO_HTTPS_URL" | "${REPO_HTTPS_URL%.git}" | "$REPO_SSH_URL" | ssh://git@github.com/atyrode/dotfiles.git)
      ;;
    *) die "origin resolves through Git configuration to an untrusted URL; remove url.*.insteadOf rewrites" ;;
  esac
}

verify_checkout() {
  local root branch status counts local_ahead remote_ahead

  [[ -f "$DOTFILES_DIR/flake.nix" ]] || die "not a dotfiles flake checkout: $DOTFILES_DIR"
  git -C "$DOTFILES_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "repository is not a Git checkout: $DOTFILES_DIR"
  git -C "$DOTFILES_DIR" ls-files --error-unmatch -- flake.nix install.sh >/dev/null 2>&1 ||
    die "bootstrap entrypoints must be tracked by the verified repository"
  root="$(git -C "$DOTFILES_DIR" rev-parse --show-toplevel)"
  root="$(CDPATH='' cd -- "$root" && pwd -P)"
  [[ "$root" == "$DOTFILES_DIR" ]] || die "--repo must name the checkout root: $root"
  verify_origin

  if [[ "$UPDATE_SOURCE" -eq 1 && "$ALLOW_DIRTY" -eq 1 ]]; then
    die "--update cannot be combined with --allow-dirty"
  fi

  status="$(git -C "$DOTFILES_DIR" status --porcelain --untracked-files=normal)"
  if [[ -n "$status" && "$ALLOW_DIRTY" -ne 1 ]]; then
    die "checkout has staged, tracked, or untracked changes; use --allow-dirty only after reviewing them"
  fi

  branch="$(git -C "$DOTFILES_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ "$branch" != main && "$ALLOW_NON_MAIN" -ne 1 ]]; then
    # An --update run has already proven the tree clean, so returning it to
    # main only moves HEAD: the branch ref, and every commit on it, survives.
    # update_checkout does that and announces the way back.
    if [[ "$UPDATE_SOURCE" -ne 1 || "$SOURCE_UPDATED" -eq 1 ]]; then
      if [[ -z "$branch" ]]; then
        die "checkout is detached; use --allow-non-main only for an intentionally reviewed revision"
      fi
      die "checkout is on $branch, not main; use --allow-non-main only after reviewing it"
    fi
  fi
  if [[ "$branch" == main ]]; then
    if git -C "$DOTFILES_DIR" show-ref --verify --quiet refs/remotes/origin/main; then
      counts="$(git -C "$DOTFILES_DIR" rev-list --left-right --count HEAD...origin/main)"
      local_ahead="${counts%%[[:space:]]*}"
      remote_ahead="${counts##*[[:space:]]}"
      if [[ ("$local_ahead" != 0 || "$remote_ahead" != 0) && "$ALLOW_NON_MAIN" -ne 1 && "$UPDATE_SOURCE" -ne 1 ]]; then
        die "main differs from cached origin/main; use --update or --allow-non-main for a reviewed revision"
      fi
    elif [[ "$UPDATE_SOURCE" -ne 1 && "$ALLOW_NON_MAIN" -ne 1 ]]; then
      die "origin/main is unavailable; use --update or --allow-non-main for a reviewed revision"
    fi
  fi
}

bootstrap_state_root() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap"
}

interrupted_marker_path() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/install-interrupted"
}

warn_if_interrupted() {
  local marker line config="" started=""

  marker="$(interrupted_marker_path)"
  if [[ ! -e "$marker" && ! -L "$marker" ]]; then
    return 0
  fi
  [[ -f "$marker" && ! -L "$marker" ]] || die "unsafe interrupted-apply marker: $marker"
  while IFS= read -r line; do
    case "$line" in
      config=*) config="${line#config=}" ;;
      started=*) started="${line#started=}" ;;
    esac
  done <"$marker"
  printf '%s %s %s\n' "$(paint_err 33 'bootstrap: warning:')" \
    "$(printf 'previous apply of %s (started %s) was interrupted; state is safe — re-run:' \
      "${config:-unknown}" "${started:-unknown}")" \
    "$(paint_err '1;36' "./install.sh apply --config ${config:-$FLAKE_CONFIG}")" >&2
}

# The upstream multi-user installer backs each shell rc file up to
# `<target>.backup-before-nix` before it appends its own lines, and refuses to
# start when such a backup already exists and no longer matches its target.
# An interrupted install therefore leaves a machine that fails every retry,
# and it fails late: after the artifact download, after the volume repair, and
# after several minutes of installer prose. Its remediation reads like an
# invitation to delete the backup, which discards the only copy of the
# original file.
#
# Repairing this is bootstrap's job, not the operator's, so detection is
# read-only and the restore runs as a confirmed, planned step of apply.
detect_shell_profile_backups() {
  local etc target backup

  STALE_PROFILE_BACKUPS=()
  etc="$(etc_root)"
  for target in \
    "$etc/bashrc" \
    "$etc/profile.d/nix.sh" \
    "$etc/zshrc" \
    "$etc/bash.bashrc" \
    "$etc/zsh/zshrc"; do
    backup="$target$PROFILE_BACKUP_SUFFIX"
    [[ -e "$backup" ]] || continue
    # A backup identical to its target is what a completed install leaves
    # behind; upstream overwrites it with the same content and proceeds.
    if [[ -e "$target" ]] && cmp -s "$backup" "$target"; then
      continue
    fi
    if [[ -L "$backup" || -L "$target" ]]; then
      die "unsafe shell rc state: $backup or $target is a symlink"
    fi
    STALE_PROFILE_BACKUPS+=("$target")
  done
}

# Restore each backup over its target. The target here is the interrupted
# install's own derived file, but proving that byte for byte across installer
# versions is not worth guessing wrong about on someone's /etc: keep it beside
# the restored original instead of discarding it.
repair_shell_profile_backups() {
  local target backup superseded

  [[ "${#STALE_PROFILE_BACKUPS[@]}" -gt 0 ]] || return 0
  for target in "${STALE_PROFILE_BACKUPS[@]}"; do
    backup="$target$PROFILE_BACKUP_SUFFIX"
    [[ -e "$backup" ]] || continue
    if [[ -e "$target" ]]; then
      superseded="$target.nix-install-leftover"
      run_privileged mv -f "$target" "$superseded" ||
        die "could not set aside $target"
      printf '%s the interrupted install'"'"'s %s as %s\n' "$(paint 32 'Kept')" \
        "$target" "$superseded"
    fi
    run_privileged mv "$backup" "$target" ||
      die "could not restore $backup to $target"
    printf '%s %s from %s\n' "$(paint 32 'Restored')" "$target" "$backup"
  done
}

# nix-darwin refuses to activate when an /etc file it manages holds content it
# does not recognise, and the content it will not recognise here is the block
# the upstream Nix installer appends to the shell rc files nix-darwin also
# owns. The refusal is a review gate, not a disagreement about the outcome:
# nix-darwin's own etc activation moves any conflicting file to
# <file>.before-nix-darwin one step later. This performs that same move
# before activation, so the review happens in the plan instead of as an abort
# 30 minutes into a build.
detect_unrecognised_etc_profiles() {
  local etc target

  UNRECOGNISED_ETC_PROFILES=()
  [[ "$SYSTEM" == *-darwin ]] || return 0
  etc="$(etc_root)"
  for target in \
    "$etc/bashrc" \
    "$etc/zshrc" \
    "$etc/bash.bashrc" \
    "$etc/zsh/zshrc"; do
    # A link is either nix-darwin's own path into /etc/static or someone
    # else's redirection; neither is a file bootstrap wrote, and neither is
    # bootstrap's to move. A regular file carrying the installer's marker is.
    [[ -f "$target" && ! -L "$target" ]] || continue
    grep -q '^# End Nix$' "$target" 2>/dev/null || continue
    UNRECOGNISED_ETC_PROFILES+=("$target")
  done
}

# Renaming is what nix-darwin does to the same file, so the end state matches
# a successful activation exactly. A backup that is already there is the one
# an earlier nix-darwin generation made, and it holds the pre-nix-darwin
# original: that copy is worth more than this one, so the installer's file is
# archived under the repairs directory rather than written over it.
repair_unrecognised_etc_profiles() {
  local target moved archive

  [[ "${#UNRECOGNISED_ETC_PROFILES[@]}" -gt 0 ]] || return 0
  for target in "${UNRECOGNISED_ETC_PROFILES[@]}"; do
    [[ -f "$target" && ! -L "$target" ]] || continue
    moved="$target.before-nix-darwin"
    if [[ -e "$moved" || -L "$moved" ]]; then
      mkdir -p "$(repair_state_dir)" 2>/dev/null || true
      archive="$(repair_state_dir)/${target##*/}.$(date -u +%Y%m%dT%H%M%SZ)"
      cp "$target" "$archive" ||
        fail BOOT-E216 "could not archive $target before removing it" \
          "check that $(repair_state_dir) is writable"
      run_privileged rm -f "$target" ||
        fail BOOT-E216 "could not remove $target" "restore it from $archive"
      journal_repair "archived $target; $moved already held the pre-nix-darwin original" \
        "cp '$archive' '$target'"
      printf '%s %s at %s: %s already holds the original.\n' "$(paint 32 'Archived')" \
        "$target" "$archive" "$moved"
    else
      run_privileged mv "$target" "$moved" ||
        fail BOOT-E216 "could not move $target aside for nix-darwin" \
          "move it by hand: sudo mv $target $moved"
      journal_repair "moved $target to $moved so nix-darwin can manage the path" \
        "mv '$moved' '$target'"
      printf '%s %s to %s: nix-darwin manages that path and refuses to\n' "$(paint 32 'Moved')" "$target" "$moved"
      printf '  overwrite a file it does not recognise. Nothing was deleted.\n'
    fi
  done
}

# The /etc bootstrap inspects. Redirected under test so no fixture can reach
# the real system files.
etc_root() {
  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && -n "${BOOTSTRAP_PROFILE_TARGET_ROOT:-}" ]]; then
    printf '%s\n' "$BOOTSTRAP_PROFILE_TARGET_ROOT/etc"
  else
    printf '/etc\n'
  fi
}

# A populated store database is the difference between a volume that is
# orphaned and one that is carrying a live install. Redirected under test so
# both answers can be staged.
nix_store_db() {
  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && -n "${BOOTSTRAP_PROFILE_TARGET_ROOT:-}" ]]; then
    printf '%s\n' "$BOOTSTRAP_PROFILE_TARGET_ROOT/nix/var/nix/db/db.sqlite"
  else
    printf '/nix/var/nix/db/db.sqlite\n'
  fi
}

# The CA bundle the upstream installer puts in the default profile: the one
# trust anchor on a Nix machine whose lifetime is not tied to a nix-darwin
# generation, and therefore the one a repair can point at.
trust_anchor_bundle() {
  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && -n "${BOOTSTRAP_PROFILE_TARGET_ROOT:-}" ]]; then
    printf '%s\n' "$BOOTSTRAP_PROFILE_TARGET_ROOT/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt"
  else
    printf '/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt\n'
  fi
}

nix_daemon_plist() {
  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && -n "${BOOTSTRAP_PROFILE_TARGET_ROOT:-}" ]]; then
    printf '%s\n' "$BOOTSTRAP_PROFILE_TARGET_ROOT/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
  else
    printf '/Library/LaunchDaemons/org.nixos.nix-daemon.plist\n'
  fi
}

# macOS keeps diskutil in /usr/sbin, which a machine with a broken /etc can
# drop from PATH - precisely the machine these repairs exist for. Prefer the
# PATH entry so the check harness can substitute a fake; fall back to the
# absolute path so a degraded login shell still works.
diskutil_command() {
  if command_exists diskutil; then
    printf 'diskutil\n'
  else
    printf '/usr/sbin/diskutil\n'
  fi
}

diskutil_field() {
  local device="$1" field="$2"

  "$(diskutil_command)" info "$device" 2>/dev/null |
    awk -F: -v want="$field" '
      {
        key = $1
        sub(/^[[:space:]]+/, "", key)
        sub(/[[:space:]]+$/, "", key)
      }
      key == want {
        sub(/^[^:]*:[[:space:]]*/, "")
        print
        exit
      }
    '
}

nix_volume_present() {
  "$(diskutil_command)" info "$1" >/dev/null 2>&1
}

# A previous nix-darwin generation owns /etc through a store indirection:
# /etc/bashrc -> /etc/static/bashrc -> /nix/store/<hash>-etc/bashrc. Lose that
# store and every one of those links dangles. A dangling link is worse than a
# missing file: test -e reports it absent, so the upstream installer takes its
# "create a stub" branch, and touch follows the link to a target whose parent
# is gone and fails with ENOENT on a path that visibly exists.
#
# Only links this toolchain owns are considered - ones resolving into the Nix
# store or through /etc/static. A dangling link elsewhere may be deliberate,
# naming a volume that mounts later, and is none of bootstrap's business.
# Ownership is the whole safety argument for removing anything under /etc, so
# it is one predicate used by both the sweep and the failure classifier.
etc_link_owned() {
  case "$1" in
    /nix/store/* | /etc/static | /etc/static/* | */etc/static | */etc/static/*) return 0 ;;
  esac
  return 1
}

detect_stale_etc_links() {
  local etc entry target

  STALE_ETC_LINKS=()
  [[ "$SYSTEM" == *-darwin ]] || return 0
  etc="$(etc_root)"
  [[ -d "$etc" ]] || return 0
  # Nested entries dangle exactly like top-level ones: nix-darwin owns
  # /etc/ssl/certs/ca-certificates.crt the same way it owns /etc/bashrc, and
  # that is the file Nix reads for TLS trust anchors. A depth-limited sweep
  # leaves a machine that installs Nix and then cannot download through it.
  # -H follows the operand only: /etc is itself a symlink to private/etc on
  # macOS, so -P would refuse to descend and find nothing, while links met
  # during the walk are still reported as links rather than chased.
  while IFS= read -r entry; do
    [[ -L "$entry" && ! -e "$entry" ]] || continue
    target="$(readlink "$entry" 2>/dev/null)" || continue
    etc_link_owned "$target" || continue
    STALE_ETC_LINKS+=("$entry")
  done < <(find -H "$etc" -type l 2>/dev/null | LC_ALL=C sort)
}

repair_stale_etc_links() {
  local entry target

  [[ "${#STALE_ETC_LINKS[@]}" -gt 0 ]] || return 0
  for entry in "${STALE_ETC_LINKS[@]}"; do
    [[ -L "$entry" && ! -e "$entry" ]] || continue
    target="$(readlink "$entry" 2>/dev/null)" || target=""
    run_privileged rm -f "$entry" ||
      fail BOOT-E210 "could not remove the dangling link $entry" \
        "remove it by hand: sudo rm $entry"
    journal_repair "removed dangling $entry -> $target" "ln -s '$target' '$entry'"
    printf '%s dangling %s (pointed into a store that no longer exists)\n' "$(paint 32 'Removed')" "$entry"
  done
}

# Which file Nix trusts is a machine fact, not a constant. A nix-darwin
# generation names one under /etc, and when that generation's store is gone the
# name outlives the file: removing the dangling link is not enough, because
# whatever named it still names it and Nix fails on a path that is now merely
# absent. Every namer is observable, so bootstrap reads them rather than
# guessing which one is in force.
trust_anchor_candidates() {
  local etc conf plist value path

  etc="$(etc_root)"
  conf="$etc/nix/nix.conf"
  plist="$(nix_daemon_plist)"

  # A login shell started under the previous generation keeps exporting the
  # path it was built with, long after the store behind it is collected.
  [[ -z "${NIX_SSL_CERT_FILE:-}" ]] || printf 'NIX_SSL_CERT_FILE\t%s\n' "$NIX_SSL_CERT_FILE"
  [[ -z "${SSL_CERT_FILE:-}" ]] || printf 'SSL_CERT_FILE\t%s\n' "$SSL_CERT_FILE"

  if [[ -f "$conf" ]]; then
    while IFS= read -r value; do
      [[ -z "$value" ]] || printf '%s\t%s\n' "$conf" "$value"
    done < <(sed -n \
      's/^[[:space:]]*ssl-cert-file[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' \
      "$conf" 2>/dev/null)
  fi

  # launchd plists are routinely stored as binary, where the paths inside are
  # not greppable text. plutil renders one as XML on stdout without touching
  # the file on disk.
  if [[ -f "$plist" ]]; then
    while IFS= read -r value; do
      case "$value" in
        *.crt | *.pem) printf '%s\t%s\n' "$plist" "$value" ;;
      esac
    done < <(plist_strings "$plist")
  fi

  # Nothing has to name a path for Nix to read it: with no setting in force it
  # probes a fixed list and takes the first that lstat can see. Absent is not a
  # problem - Nix skips it and falls through to the profile bundle. Present but
  # unusable is, and it is indistinguishable in the error message.
  for path in "$etc/ssl/certs/ca-certificates.crt" "$etc/ssl/cert.pem"; do
    if [[ -e "$path" || -L "$path" ]]; then
      printf 'the path Nix probes by default\t%s\n' "$path"
    fi
  done
}

plist_strings() {
  local plist="$1"

  if command_exists plutil; then
    plutil -convert xml1 -o - "$plist" 2>/dev/null |
      sed -n 's|.*<string>\(/[^<]*\)</string>.*|\1|p'
  else
    sed -n 's|.*<string>\(/[^<]*\)</string>.*|\1|p' "$plist" 2>/dev/null
  fi
}

# Nix does not merely look for this file, it loads it. An empty or unparseable
# bundle fails every download exactly like a missing one and reports the same
# error naming the same path, so usable - not present - is the condition that
# matters, and the one the repair converges on.
trust_anchor_usable() {
  local path="$1"

  [[ -e "$path" && -s "$path" ]] || return 1
  grep -q 'BEGIN CERTIFICATE' "$path" 2>/dev/null
}

detect_broken_trust_anchors() {
  local etc source path seen=""

  BROKEN_TRUST_ANCHORS=()
  [[ "$SYSTEM" == *-darwin ]] || return 0
  etc="$(etc_root)"
  while IFS=$'\t' read -r source path; do
    [[ -n "$path" ]] || continue
    # Only paths under /etc are bootstrap's to answer for; a trust anchor kept
    # anywhere else belongs to whoever put it there.
    case "$path" in "$etc"/*) ;; *) continue ;; esac
    trust_anchor_usable "$path" && continue
    case "$seen" in *"|$path|"*) continue ;; esac
    seen="$seen|$path|"
    BROKEN_TRUST_ANCHORS+=("$source"$'\t'"$path")
  done < <(trust_anchor_candidates)
}

# The upstream installer puts a real CA bundle in the default profile, which is
# what makes this repairable at all. For a link, ownership is the same
# predicate the sweep uses: bootstrap replaces one it left behind, never one
# the operator keeps. A regular file carries no ownership signal, so the
# safety is archival - the original is kept and the undo command restores it.
trust_anchor_restorable() {
  local path="$1" target

  [[ -e "$(trust_anchor_bundle)" ]] || return 1
  if [[ -L "$path" ]]; then
    target="$(readlink "$path" 2>/dev/null)" || return 1
    etc_link_owned "$target" || return 1
  fi
  return 0
}

repair_broken_trust_anchors() {
  local line source path bundle dir target archive

  [[ "${#BROKEN_TRUST_ANCHORS[@]}" -gt 0 ]] || return 0
  bundle="$(trust_anchor_bundle)"
  for line in "${BROKEN_TRUST_ANCHORS[@]}"; do
    source="${line%%$'\t'*}"
    path="${line#*$'\t'}"
    trust_anchor_usable "$path" && continue
    trust_anchor_restorable "$path" || continue
    dir="${path%/*}"
    if [[ ! -d "$dir" ]]; then
      run_privileged mkdir -p "$dir" ||
        fail BOOT-E214 "could not create $dir for the TLS trust anchor" \
          "create it by hand: sudo mkdir -p $dir"
    fi
    if [[ -L "$path" ]]; then
      target="$(readlink "$path" 2>/dev/null)" || target=""
      run_privileged rm -f "$path" ||
        fail BOOT-E214 "could not remove the unusable trust anchor $path" \
          "remove it by hand: sudo rm $path"
      journal_repair "removed unusable trust anchor link $path -> $target" \
        "ln -s '$target' '$path'"
    elif [[ -e "$path" ]]; then
      mkdir -p "$(repair_state_dir)" 2>/dev/null || true
      archive="$(repair_state_dir)/ca-bundle.$(date -u +%Y%m%dT%H%M%SZ)"
      cp "$path" "$archive" ||
        fail BOOT-E214 "could not archive the unusable trust anchor $path" \
          "check that $(repair_state_dir) is writable"
      run_privileged rm -f "$path" ||
        fail BOOT-E214 "could not remove the unusable trust anchor $path" \
          "remove it by hand: sudo rm $path"
      journal_repair "archived unusable trust anchor $path" "cp '$archive' '$path'"
      printf '%s unusable %s at %s\n' "$(paint 32 'Archived')" "$path" "$archive"
    fi
    run_privileged ln -sfn "$bundle" "$path" ||
      fail BOOT-E214 "could not restore the TLS trust anchor $path" \
        "link it by hand: sudo ln -sfn $bundle $path"
    journal_repair "restored trust anchor $path -> $bundle (named by $source)" \
      "rm -f '$path'"
    printf '%s %s -> %s (named by %s)\n' "$(paint 32 'Restored')" "$path" "$bundle" "$source"
  done
}

# A crashed install leaves /etc/fstab naming a volume UUID that no longer
# resolves. Upstream only tests whether a /nix line is present, never whether
# it still means anything, so a dead line survives and the volume created next
# mounts without the options that line was supposed to supply.
detect_stale_fstab_entry() {
  local fstab uuid

  STALE_FSTAB_ENTRY=""
  [[ "$SYSTEM" == *-darwin ]] || return 0
  fstab="$(etc_root)/fstab"
  [[ -f "$fstab" && ! -L "$fstab" ]] || return 0
  uuid="$(awk '$2 == "/nix" && $3 == "apfs" {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^UUID=/) {
          sub(/^UUID=/, "", $i)
          print $i
          exit
        }
    }' "$fstab")"
  [[ -n "$uuid" ]] || return 0
  # A line naming the volume this run is about to rename is stale too: a
  # rename keeps the UUID, so resolvability alone would not catch it.
  if [[ -n "$ORPHANED_NIX_VOLUME_UUID" && "$uuid" == "$ORPHANED_NIX_VOLUME_UUID" ]]; then
    STALE_FSTAB_ENTRY="$fstab"
    return 0
  fi
  nix_volume_present "$uuid" && return 0
  STALE_FSTAB_ENTRY="$fstab"
}

repair_stale_fstab_entry() {
  local fstab archive temporary

  [[ -n "$STALE_FSTAB_ENTRY" ]] || return 0
  fstab="$STALE_FSTAB_ENTRY"
  [[ -f "$fstab" ]] || return 0
  mkdir -p "$(repair_state_dir)" 2>/dev/null || true
  archive="$(repair_state_dir)/fstab.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$fstab" "$archive" ||
    fail BOOT-E211 "could not archive $fstab before editing it" \
      "check that $(repair_state_dir) is writable"
  temporary="$(mktemp "${TMPDIR:-/tmp}/atyrode-fstab.XXXXXX")"
  awk '!($2 == "/nix" && $3 == "apfs")' "$fstab" >"$temporary"
  if [[ -s "$temporary" ]]; then
    run_privileged cp "$temporary" "$fstab" ||
      fail BOOT-E211 "could not rewrite $fstab" "restore it from $archive"
  else
    # macOS ships without /etc/fstab, so an emptied file is not stock state.
    run_privileged rm -f "$fstab" ||
      fail BOOT-E211 "could not remove the emptied $fstab" "restore it from $archive"
  fi
  rm -f "$temporary"
  journal_repair "dropped the dead /nix entry from $fstab" "cp '$archive' '$fstab'"
  printf '%s the stale /nix entry from %s (archived at %s)\n' "$(paint 32 'Dropped')" "$fstab" "$archive"
}

# An orphaned "Nix Store" volume is what makes the upstream installer take its
# least-tested path: cure a pre-existing volume, encrypt it in place, carry
# on. Renaming is enough to sidestep that path, because the installer finds
# volumes by label - and unlike deleting, it destroys nothing and undoes with
# a single command.
detect_orphaned_nix_volume() {
  ORPHANED_NIX_VOLUME=""
  ORPHANED_NIX_VOLUME_UUID=""
  [[ "$SYSTEM" == *-darwin ]] || return 0
  # Only reachable when Nix is absent. A populated store database means
  # something real is mounted, so the volume is in use, not orphaned.
  [[ ! -e "$(nix_store_db)" ]] || return 0
  nix_volume_present "$NIX_VOLUME_LABEL" || return 0
  ORPHANED_NIX_VOLUME="$(diskutil_field "$NIX_VOLUME_LABEL" 'Device Identifier')"
  ORPHANED_NIX_VOLUME_UUID="$(diskutil_field "$NIX_VOLUME_LABEL" 'Volume UUID')"
  [[ -n "$ORPHANED_NIX_VOLUME" ]] ||
    fail BOOT-E212 \
      "found a $NIX_VOLUME_LABEL volume but could not read its device identifier" \
      "run: diskutil info '$NIX_VOLUME_LABEL'"
}

# The installer stores an encrypted Nix volume's passphrase in the System
# keychain under the volume UUID, and reading that keychain needs privilege.
# This is the lookup upstream's create-darwin-volume.sh performs, verbatim:
# `security find-generic-password -s "$volume_uuid" -w` under sudo. Running it
# unprivileged finds nothing, which would look exactly like a volume whose key
# is gone and quietly escalate a rename into a delete.
nix_volume_passphrase() {
  local uuid="$1"

  command_exists security || return 1
  run_privileged security find-generic-password -s "$uuid" -w 2>/dev/null
}

mount_nix_volume() {
  local volume="$1" uuid passphrase

  MOUNT_FAILURE=""
  MOUNT_FAILURE="$(run_privileged "$(diskutil_command)" mount "$volume" 2>&1)" && return 0
  # A locked encrypted volume refuses a plain mount, so unlock it with the
  # passphrase the installer left in the keychain.
  uuid="$(diskutil_field "$volume" 'Volume UUID')"
  if [[ -n "$uuid" ]]; then
    passphrase="$(nix_volume_passphrase "$uuid")" || passphrase=""
    if [[ -n "$passphrase" ]]; then
      MOUNT_FAILURE="$(printf '%s' "$passphrase" |
        run_privileged "$(diskutil_command)" apfs unlockVolume "$volume" -stdinpassphrase 2>&1)" &&
        return 0
    else
      MOUNT_FAILURE="no passphrase for $uuid in the System keychain; $MOUNT_FAILURE"
    fi
  fi
  return 1
}

# Renaming is the reversible way to stop the installer finding a volume by
# label, and diskutil renames through the mounted filesystem - so an unmounted
# volume must be mounted first, and recovery unmounts to free /nix, which
# guarantees the next run meets one. An encrypted volume whose key is gone
# cannot be mounted and therefore cannot be renamed; leaving it labelled
# "Nix Store" routes the installer onto the path that crashes. That volume is
# deleted instead: the store-database check proved it carries no live install,
# and every path in a Nix store is re-fetchable from the binary cache.
retire_nix_volume() {
  local volume="$1" renamed="$2" remount=0

  if [[ "$(diskutil_field "$volume" 'Mounted')" == [Nn]o ]]; then
    if mount_nix_volume "$volume"; then
      remount=1
    else
      run_privileged "$(diskutil_command)" apfs deleteVolume "$volume" ||
        fail BOOT-E215 "$volume could not be mounted to rename it, and could not be deleted either" \
          "delete it by hand: sudo diskutil apfs deleteVolume $volume"
      journal_repair \
        "deleted the locked $NIX_VOLUME_LABEL volume $volume; its store is re-fetchable" \
        "none: a locked volume cannot be renamed, and a Nix store re-fetches from the cache"
      printf 'Deleted %s: it could not be mounted, and a volume that cannot be\n' "$volume"
      printf '  mounted cannot be renamed. Reason: %s\n' "${MOUNT_FAILURE:-unknown}"
      printf '  Nothing else was on it. A Nix store is a cache; every path re-downloads.\n'
      return 0
    fi
  fi
  run_privileged "$(diskutil_command)" rename "$volume" "$renamed" ||
    fail BOOT-E213 "could not rename the orphaned volume $volume" \
      "run: sudo diskutil rename $volume '$renamed'"
  journal_repair "renamed orphaned volume $volume to '$renamed'" \
    "diskutil rename '$volume' '$NIX_VOLUME_LABEL'"
  printf '%s the orphaned volume %s to "%s"\n' "$(paint 32 'Renamed')" "$volume" "$renamed"
  printf '  Nothing on it was deleted. Reclaim the space once the install works:\n'
  printf '    sudo diskutil apfs deleteVolume %s\n' "$volume"
  # Leave it as it was found: a volume that was not mounted must not end up
  # occupying /nix, which is the mount point the installer needs.
  if [[ "$remount" -eq 1 ]]; then
    run_privileged "$(diskutil_command)" unmount "$volume" >/dev/null 2>&1 || true
  fi
}

repair_orphaned_nix_volume() {
  [[ -n "$ORPHANED_NIX_VOLUME" ]] || return 0
  retire_nix_volume "$ORPHANED_NIX_VOLUME" \
    "$NIX_VOLUME_LABEL (orphaned $(date -u +%Y%m%dT%H%M%SZ))"
}

# The upstream installer fails by printing prose and exiting 1. Turning its
# known failure shapes into codes is what makes this script improvable: a
# recognised shape names the repair that already fixes it, and an
# unrecognised one is a concrete, reportable gap.
report_installer_failure() {
  local log="$1"

  log_event "upstream installer failed; transcript at $log"
  if grep -q '^touch: .*No such file or directory' "$log" 2>/dev/null; then
    fail BOOT-E201 \
      "the upstream installer could not create a shell rc file, so /etc still holds a link into a store that is gone" \
      "re-run bootstrap: it clears those links before the installer starts"
  elif grep -q 'but the latter already exists' "$log" 2>/dev/null; then
    fail BOOT-E202 \
      "the upstream installer refused to start because a pre-Nix shell rc backup is in the way" \
      "re-run bootstrap: it restores those backups before the installer starts"
  elif grep -q 'Bus error' "$log" 2>/dev/null; then
    fail BOOT-E203 \
      "the upstream installer crashed encrypting a pre-existing Nix volume in place" \
      "re-run bootstrap: it renames an orphaned volume so a fresh one is created"
  elif grep -q 'failed to mount' "$log" 2>/dev/null; then
    fail BOOT-E204 \
      "the upstream installer created the Nix volume but could not mount it" \
      "re-run bootstrap: it clears a dead /nix entry in /etc/fstab, which is the usual cause"
  else
    fail BOOT-E299 \
      "the upstream Nix installer failed in a way bootstrap does not recognise yet" \
      "send the transcript at $log so this state can get its own code and repair"
  fi
}

# nix-darwin prints the paths it refused to overwrite one per line under a
# fixed header, and nh reprints that block indented under its own error. Read
# the list, not the prose around it, and keep only paths that are still there
# to be moved - a name in a transcript is a claim until the machine agrees.
detect_etc_activation_conflicts() {
  local log="$1" path

  ETC_ACTIVATION_CONFLICTS=()
  [[ -n "$log" && -f "$log" ]] || return 0
  while IFS= read -r path; do
    [[ -e "$path" ]] || continue
    ETC_ACTIVATION_CONFLICTS+=("$path")
  done < <(awk '
    /have unrecognized content/ { block = 1; next }
    block {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      if (line !~ /^\//) { block = 0; next }
      print line
    }
  ' "$log")
}

# A derivation whose builder ran and exited non-zero, as opposed to a machine
# that cannot build. The distinction decides the remedy: this failure travels
# with the configuration, reproduces on every machine, and leaves this one
# untouched because the backend builds before it activates. The derivation name
# comes back with it so the report can say which one, since a bootstrap
# transcript is thousands of lines and the operator should not have to hunt.
FAILED_DERIVATION=""
detect_configuration_build_failure() {
  local log="$1"

  FAILED_DERIVATION=""
  [[ -n "$log" && -f "$log" ]] || return 1
  grep -qE "builder failed with exit code|builder for '/nix/store/[^']+' failed|Failed to build .+ configuration" "$log" || return 1
  # Both the current "Cannot build" and the older "builder for" wording name the
  # drv path; the hash in front of the name is noise to everyone but Nix.
  FAILED_DERIVATION="$(sed -nE "s|.*build(er for)? '/nix/store/[a-z0-9]{32}-(.+)\.drv'.*|\2|p" "$log" | head -1)"
  return 0
}

# Every managed step runs Nix, so every managed step fails when Nix cannot
# reach the cache. Without this the operator gets a raw nix error as the last
# word: no code, no log path, nothing to report.
report_managed_failure() {
  local step="$1" log="${2:-}" line source path remedy=""

  log_event "managed step failed: $step"
  log_diagnostics
  # nix-darwin names the files it refused to overwrite. Every file bootstrap
  # moves is already moved by the time activation runs, so a name that
  # survives to here is one bootstrap does not own - which is why the remedy
  # is the operator's command and not another run.
  detect_etc_activation_conflicts "$log"
  if [[ "${#ETC_ACTIVATION_CONFLICTS[@]}" -gt 0 ]]; then
    path="${ETC_ACTIVATION_CONFLICTS[0]}"
    fail BOOT-E303 \
      "$step failed: nix-darwin refused to overwrite $path, and its content is not bootstrap's to move" \
      "keep whatever matters in it, then move it aside and re-run bootstrap: sudo mv $path $path.before-nix-darwin"
    return 1
  fi
  detect_broken_trust_anchors
  if [[ "${#BROKEN_TRUST_ANCHORS[@]}" -eq 0 ]]; then
    # After the trust-anchor check and never before it: a machine that cannot
    # verify TLS also fails to build, and that one is repairable here.
    if detect_configuration_build_failure "$log"; then
      # The marker exists to warn that a run stopped somewhere between the
      # first mutation and the last. This run made none, so leaving it behind
      # opens every later bootstrap with a warning about a machine that was
      # never touched -- and tells the operator to re-run the very command
      # they are running.
      clear_interrupted_marker
      fail BOOT-E304 \
        "$step failed because the configuration did not build${FAILED_DERIVATION:+, at $FAILED_DERIVATION}, so nothing was activated and this machine is unchanged" \
        "the same build fails on every machine, so resetting Nix here cannot help: report the build error in the log below, and re-run bootstrap once the configuration builds"
      return 1
    fi
    fail BOOT-E399 \
      "$step failed in a way bootstrap does not recognise yet" \
      "send the log below so this state can get its own code and repair, or reset this machine's Nix installation with: ./install.sh recover --config $FLAKE_CONFIG"
    return 1
  fi
  line="${BROKEN_TRUST_ANCHORS[0]}"
  source="${line%%$'\t'*}"
  path="${line#*$'\t'}"
  # Two repairs can reach this state and they carry different promises: with a
  # profile bundle available the file comes back, and without one a link
  # bootstrap owns is still removed so Nix stops reading it.
  if trust_anchor_restorable "$path"; then
    remedy="re-run bootstrap: it restores that file from the CA bundle in the Nix profile before Nix is used"
  elif [[ -L "$path" ]] && etc_link_owned "$(readlink "$path" 2>/dev/null)"; then
    remedy="re-run bootstrap: it clears that link before Nix is used"
  fi
  if [[ -n "$remedy" ]]; then
    fail BOOT-E301 \
      "$step failed, and the TLS trust anchor $path named by $source is not a usable CA bundle, so Nix cannot verify TLS" \
      "$remedy"
  else
    fail BOOT-E302 \
      "$step failed, and the TLS trust anchor $path named by $source is not a usable CA bundle and is not bootstrap's to replace" \
      "point $path at a real CA bundle or remove it, then re-run bootstrap"
  fi
}

# A managed step's output is evidence, and its stdio is also a conversation:
# activation asks for sudo, for the vault password, and whether to provision
# each surface it found unconfigured. Capturing the stream costs every one of
# those, because a pipe is not a terminal and the CLI gates its prompts on
# having one. So capture only when there is no terminal to lose - which is
# exactly when there is nobody to ask. On a terminal the operator is the
# transcript, and the run log records where the output went instead of a copy
# of it; a step that fails there is classified from machine state, which is
# what the trust-anchor and volume codes were already derived from.
run_managed_step() {
  local label="$1" transcript status=0

  shift
  if step_can_converse; then
    log_event "$label streamed to the operator terminal; no transcript was captured"
    "$@" || report_managed_failure "$label"
    return
  fi
  if [[ -n "$RUN_LOG" ]]; then
    transcript="${RUN_LOG%.log}-$label.log"
  else
    transcript="$(mktemp "${TMPDIR:-/tmp}/atyrode-$label.XXXXXX")"
  fi
  # Redirect and replay rather than pipe through tee. A pipeline runs the step
  # in a subshell, so anything it records about the machine dies with that
  # subshell -- and only on this path, which made bootstrap behave one way on
  # an operator's terminal and another in CI. There is no one watching a
  # captured step by definition, so nothing is lost by replaying it whole.
  "$@" >"$transcript" 2>&1 || status=$?
  cat "$transcript"
  [[ "$status" -eq 0 ]] || report_managed_failure "$label" "$transcript"
}

# The same predicate the CLI applies to decide whether it may hold a dialogue,
# asked here so bootstrap does not hand it a stream that makes the answer no.
step_can_converse() {
  [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && -n "${BOOTSTRAP_TEST_TTY:-}" ]] && return 0
  [[ -t 0 && -t 1 ]]
}

preflight() {
  command_exists git || die "git is required"
  command_exists mktemp || die "mktemp is required"
  canonicalize_repo
  verify_checkout

  SYSTEM="$(detect_system)"
  select_nix_artifact
  if [[ -z "$FLAKE_CONFIG" ]]; then
    die "--config HOST (or FLAKE_CONFIG) is required; bootstrap never guesses a machine profile"
  fi
  case "$FLAKE_CONFIG" in
    *[!A-Za-z0-9@._-]* | '') die "configuration contains unsupported characters" ;;
  esac

  source_nix
  # These three exist to unblock the upstream installer, so they are only
  # relevant while Nix is missing and the installer is about to run.
  if ! command_exists nix; then
    command_exists curl || die "curl is required to download the pinned Nix artifact"
    command_exists tar || die "tar is required to unpack the pinned Nix artifact"
    if ! command_exists sha256sum && ! command_exists shasum; then
      die "sha256sum or shasum is required to verify the pinned Nix artifact"
    fi
    detect_orphaned_nix_volume
    detect_shell_profile_backups
    detect_stale_fstab_entry
  fi
  # These two are different: they repair Nix itself, not the installer, and a
  # machine whose Nix cannot verify TLS is exactly the machine that needs them.
  # The sweep clears links into a store that is gone; the trust-anchor repair
  # puts a working CA bundle back at the path this machine still names, which
  # removal alone leaves merely absent. On a healthy host nothing dangles,
  # every named anchor resolves, and both find nothing.
  detect_stale_etc_links
  detect_broken_trust_anchors
  # Different again: this one unblocks nix-darwin rather than Nix, so it is
  # relevant exactly when Nix is present and activation is what comes next.
  detect_unrecognised_etc_profiles

  warn_if_interrupted

  printf '%s\n' "$(paint '1;32' 'Preflight passed')"
  printf '  %s %s\n' "$(paint 2 'system:')" "$(paint 36 "$SYSTEM")"
  printf '  %s %s\n' "$(paint 2 'configuration:')" "$(paint 36 "$FLAKE_CONFIG")"
  printf '  %s %s\n' "$(paint 2 'repository:')" "$(paint 36 "$DOTFILES_DIR")"
  printf '  %s %s\n' "$(paint 2 'revision:')" \
    "$(paint 36 "$(git -C "$DOTFILES_DIR" rev-parse --short=12 HEAD)")"
}

print_plan() {
  local step=1 target line path printed

  printf '\n%s\n' "$(paint 1 'Plan')"
  if [[ "$UPDATE_SOURCE" -eq 1 ]]; then
    printf '  %s. Fetch the verified origin and fast-forward main.\n' "$(paint 1 "$step")"
    step=$((step + 1))
  fi
  if [[ "${#STALE_PROFILE_BACKUPS[@]}" -gt 0 ]]; then
    printf '  %s. Restore the pre-Nix shell rc file an interrupted Nix install left backed up:\n' \
      "$(paint 1 "$step")"
    for target in "${STALE_PROFILE_BACKUPS[@]}"; do
      printf '       %s\n' "$(paint 36 "$target")"
    done
    step=$((step + 1))
  fi
  if [[ "${#STALE_ETC_LINKS[@]}" -gt 0 ]]; then
    printf '  %s. Remove links a previous nix-darwin left pointing into a store that is gone:\n' \
      "$(paint 1 "$step")"
    for target in "${STALE_ETC_LINKS[@]}"; do
      printf '       %s\n' "$(paint 36 "$target")"
    done
    step=$((step + 1))
  fi
  if [[ "${#BROKEN_TRUST_ANCHORS[@]}" -gt 0 ]]; then
    printed=0
    for line in "${BROKEN_TRUST_ANCHORS[@]}"; do
      path="${line#*$'\t'}"
      trust_anchor_restorable "$path" || continue
      if [[ "$printed" -eq 0 ]]; then
        printf '  %s. Restore the TLS trust anchor Nix reads, from the CA bundle in the Nix profile:\n' \
          "$(paint 1 "$step")"
        printed=1
      fi
      printf '       %s %s\n' "$(paint 36 "$path")" \
        "$(paint 2 "(named by ${line%%$'\t'*})")"
    done
    [[ "$printed" -eq 0 ]] || step=$((step + 1))
  fi
  if [[ -n "$STALE_FSTAB_ENTRY" ]]; then
    printf '  %s. Drop the dead /nix entry from %s, archiving the file first.\n' \
      "$(paint 1 "$step")" "$STALE_FSTAB_ENTRY"
    step=$((step + 1))
  fi
  if [[ -n "$ORPHANED_NIX_VOLUME" ]]; then
    printf '  %s. Retire the orphaned %s volume %s so a fresh one can be created.\n' \
      "$(paint 1 "$step")" "$NIX_VOLUME_LABEL" "$ORPHANED_NIX_VOLUME"
    printf '       It is renamed and nothing on it is deleted. If it is encrypted and\n'
    printf '       cannot be unlocked, it cannot be renamed, and it is deleted instead:\n'
    printf '       it carries no live store and every Nix path re-downloads.\n'
    step=$((step + 1))
  fi
  if [[ "${#UNRECOGNISED_ETC_PROFILES[@]}" -gt 0 ]]; then
    printf '  %s. Move aside the shell rc files the Nix installer wrote, which nix-darwin\n' "$(paint 1 "$step")"
    printf '       manages and refuses to overwrite. Each keeps its content at\n'
    printf '       <file>.before-nix-darwin, which is where nix-darwin puts it too:\n'
    for target in "${UNRECOGNISED_ETC_PROFILES[@]}"; do
      printf '       %s\n' "$(paint 36 "$target")"
    done
    step=$((step + 1))
  fi
  if command_exists nix; then
    printf '  %s. Reuse the installed Nix command; do not reinstall it.\n' "$(paint 1 "$step")"
  else
    printf '  %s. Download upstream Nix %s for %s and require SHA-256 %s.\n' \
      "$(paint 1 "$step")" "$NIX_VERSION" "$SYSTEM" "$NIX_SHA256"
    printf '       It adds its own block to the shell rc files nix-darwin manages. Those\n'
    printf '       are moved to <file>.before-nix-darwin before activation, which is where\n'
    printf '       nix-darwin puts them too; nothing is deleted.\n'
  fi
  step=$((step + 1))
  printf '  %s. Evaluate the registered host through the packaged atyrode CLI.\n' "$(paint 1 "$step")"
  step=$((step + 1))
  printf '  %s. Activate %s through atyrode/nh.\n' "$(paint 1 "$step")" "$FLAKE_CONFIG"
  step=$((step + 1))
  printf '  %s. Verify the machine with atyrode doctor and clear the interrupted-apply marker.\n' "$(paint 1 "$step")"
  step=$((step + 1))
  printf '  %s. Hand every durable surface to %s, which owns them from here:\n' \
    "$(paint 1 "$step")" "$(paint 36 'atyrode apply')"
  printf '       the login shell, provisioning, and the rest of this machine are\n'
  printf '       converged by it on this run and on every later one.\n'
  printf '\n%s\n' \
    "$(paint 2 'No changes were made. apply will show this plan again before confirmation.')"
}

confirm_action() {
  local prompt="$1"
  local answer

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return
  fi
  [[ -t 0 ]] || die "$prompt requires an interactive terminal or --yes"
  printf '%s %s ' "$(paint_err 1 "$prompt")" "$(paint_err 2 '[y/N]')" >&2
  IFS= read -r answer
  case "$answer" in
    y | Y | yes | YES) ;;
    *) die "cancelled" ;;
  esac
}

ensure_safe_state_root() {
  local root="$1"
  local parent="${root%/*}"

  if [[ -e "$parent" || -L "$parent" ]]; then
    [[ -d "$parent" && ! -L "$parent" ]] || die "$parent must be a real directory"
  else
    mkdir -p "$parent"
  fi
  if [[ -e "$root" || -L "$root" ]]; then
    [[ -d "$root" && ! -L "$root" ]] || die "$root must be a real directory"
  else
    mkdir -p "$root"
  fi
  chmod 700 "$root"
}

write_interrupted_marker() {
  local marker state_dir temporary

  marker="$(interrupted_marker_path)"
  [[ ! -L "$marker" ]] || die "unsafe interrupted-apply marker: $marker"
  state_dir="${marker%/*}"
  if [[ -e "$state_dir" || -L "$state_dir" ]]; then
    [[ -d "$state_dir" && ! -L "$state_dir" ]] || die "$state_dir must be a real directory"
  else
    mkdir -p "$state_dir"
  fi
  temporary="$(mktemp "$state_dir/.install-interrupted.XXXXXX")"
  {
    printf 'config=%s\n' "$FLAKE_CONFIG"
    printf 'started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$marker"
}

clear_interrupted_marker() {
  local marker

  marker="$(interrupted_marker_path)"
  [[ ! -L "$marker" ]] || die "unsafe interrupted-apply marker: $marker"
  if [[ -f "$marker" ]]; then
    rm "$marker"
  fi
}

update_checkout() {
  local branch counts local_ahead remote_ahead

  # Reaches the network and rewrites refs. The read-only queries below stay
  # silent on purpose: showing every `show-ref` would bury the four commands
  # that actually change something.
  run_visible git -C "$DOTFILES_DIR" fetch --prune origin || return 1
  git -C "$DOTFILES_DIR" show-ref --verify --quiet refs/remotes/origin/main || return 1

  branch="$(git -C "$DOTFILES_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ "$branch" != main ]]; then
    printf 'bootstrap: moving the checkout from %s to main; return to it with: git -C %s checkout %s\n' \
      "${branch:-a detached revision}" "$DOTFILES_DIR" "${branch:--}" >&2
    if git -C "$DOTFILES_DIR" show-ref --verify --quiet refs/heads/main; then
      run_visible git -C "$DOTFILES_DIR" checkout --quiet main || return 1
    else
      run_visible git -C "$DOTFILES_DIR" checkout --quiet -b main --track origin/main || return 1
    fi
    SOURCE_CHANGED=1
  fi

  counts="$(git -C "$DOTFILES_DIR" rev-list --left-right --count HEAD...origin/main)" || return 1
  local_ahead="${counts%%[[:space:]]*}"
  remote_ahead="${counts##*[[:space:]]}"
  [[ "$local_ahead" == 0 ]] || {
    printf 'bootstrap: local main has commits not on origin/main; refusing to update\n' >&2
    return 1
  }
  if [[ "$remote_ahead" != 0 ]]; then
    run_visible git -C "$DOTFILES_DIR" merge --ff-only origin/main || return 1
    SOURCE_CHANGED=1
  fi
  SOURCE_UPDATED=1
}

# The fast-forward above may have rewritten this very script, so the run has to
# continue under the new one rather than finish under the code the operator
# fetched a minute ago. That replacement is invisible from the terminal: the
# plan and its confirmation simply appear a second time, and the second plan is
# a different length because the update step is already done. Say so, or the
# operator answers the same question twice with no idea why it was asked.
restart_after_source_update() {
  local args=(apply --repo "$DOTFILES_DIR" --config "$FLAKE_CONFIG")

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    args+=(--yes)
  fi
  if [[ "$ALLOW_NON_MAIN" -eq 1 ]]; then
    args+=(--allow-non-main)
  fi
  printf '\n%s\n' "$(paint 1 'Restarting bootstrap under the updated source')" >&2
  printf '%s\n' "$(paint 2 "the fast-forward changed install.sh itself, so the rest of this run belongs to $(git -C "$DOTFILES_DIR" rev-parse --short HEAD 2>/dev/null || echo 'the new revision'); it prints its plan and asks again")" >&2
  show_command bash "$DOTFILES_DIR/install.sh" "${args[@]}"
  exec bash "$DOTFILES_DIR/install.sh" "${args[@]}"
}

sha256_file() {
  local path="$1"

  if [[ "$SYSTEM" == *-darwin ]] && command_exists shasum; then
    shasum -a 256 "$path" | sed 's/[[:space:]].*$//'
  elif command_exists sha256sum; then
    sha256sum "$path" | sed 's/[[:space:]].*$//'
  else
    shasum -a 256 "$path" | sed 's/[[:space:]].*$//'
  fi
}

install_pinned_nix() {
  local temporary archive extracted actual installer_mode installer_log

  temporary="$(mktemp -d "${TMPDIR:-/tmp}/atyrode-nix.XXXXXX")"
  archive="$temporary/nix.tar.xz"
  printf 'Downloading pinned upstream Nix %s from releases.nixos.org...\n' "$NIX_VERSION"
  if ! run_visible curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$NIX_URL"; then
    rm -rf "$temporary"
    return 1
  fi
  actual="$(sha256_file "$archive")"
  if [[ "$actual" != "$NIX_SHA256" ]]; then
    printf 'bootstrap: Nix artifact checksum mismatch (expected %s, received %s)\n' \
      "$NIX_SHA256" "$actual" >&2
    rm -rf "$temporary"
    return 1
  fi
  if ! tar -xf "$archive" -C "$temporary"; then
    rm -rf "$temporary"
    return 1
  fi
  extracted="$temporary/nix-${NIX_VERSION}-${SYSTEM}/install"
  if [[ ! -f "$extracted" || -L "$extracted" ]]; then
    printf 'bootstrap: verified Nix archive does not contain the expected installer\n' >&2
    rm -rf "$temporary"
    return 1
  fi
  case "$SYSTEM" in
    *-darwin) installer_mode=--daemon ;;
    *-linux) installer_mode=--no-daemon ;;
    *) return 1 ;;
  esac
  # Keep the installer transcript beside the run log so a failure report is
  # one path, not two. Without a run log it lives and dies with the scratch
  # directory, which is still enough for the classifier below.
  if [[ -n "$RUN_LOG" ]]; then
    installer_log="${RUN_LOG%.log}-nix-installer.log"
  else
    installer_log="$temporary/nix-installer.log"
  fi
  # A pipeline cannot go through run_visible, and this is the single command an
  # operator most needs to recognise: everything upstream prints after this
  # line belongs to the Nix installer, not to bootstrap.
  show_command sh "$extracted" "$installer_mode" --yes --no-channel-add --no-modify-profile
  if ! sh "$extracted" "$installer_mode" --yes --no-channel-add --no-modify-profile 2>&1 |
    tee "$installer_log"; then
    report_installer_failure "$installer_log" || true
    rm -rf "$temporary"
    return 1
  fi
  log_event "upstream installer completed; transcript at $installer_log"
  rm -rf "$temporary"
  source_nix
  command_exists nix || return 1
}

ensure_nix() {
  source_nix
  if command_exists nix; then
    return
  fi
  install_pinned_nix
}

enable_flakes_for_process() {
  local feature="extra-experimental-features = nix-command flakes"

  if [[ -n "${NIX_CONFIG:-}" ]]; then
    NIX_CONFIG="${NIX_CONFIG}
$feature"
  else
    NIX_CONFIG="$feature"
  fi
  export NIX_CONFIG
}

run_atyrode() {
  run_visible nix run "$DOTFILES_DIR#atyrode" -- "$@"
}

managed_activation_plan() {
  run_atyrode apply "$FLAKE_CONFIG" --repo "$DOTFILES_DIR" --git-auth-mode "$GIT_AUTH_MODE" --plan
}

activate_configuration() {
  run_atyrode apply "$FLAKE_CONFIG" --repo "$DOTFILES_DIR" --git-auth-mode "$GIT_AUTH_MODE" --restart-shell
}

# Callers catch this function's failure, and catching a function suppresses
# set -e for everything inside it. Every guard therefore returns explicitly
# rather than leaning on the shell to abort the script for it.
verify_installation() {
  local state_file

  source_nix
  command_exists nix || {
    die "Nix is not available"
    return 1
  }
  state_file="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/dotfiles-config"
  [[ -f "$state_file" && ! -L "$state_file" ]] ||
    {
      die "active host receipt is missing"
      return 1
    }
  [[ "$(cat "$state_file")" == "$FLAKE_CONFIG" ]] ||
    {
      die "active host receipt does not match $FLAKE_CONFIG"
      return 1
    }
  # Bare doctor is the aggregate over every family - host, system, git, tools,
  # provisioning - so bootstrap verifies the machine rather than the host
  # alone, and the report reaches the operator instead of /dev/null.
  #
  # Its 69 is a finished bootstrap with findings, not a bootstrap that failed.
  # The machine activated, the receipt matches, and everything doctor still
  # names is either converged by a later `atyrode apply` or is a decision only
  # the operator can make. Treating 69 as a failure sent operators to the issue
  # tracker under [BOOT-E399] and offered to reset a Nix installation that was
  # perfectly healthy, because `gh` was not configured yet. Worse, the marker
  # below never cleared, so the next run opened by warning about an apply that
  # had in fact completed.
  #
  # The finding is recorded rather than announced here. A managed step's output
  # is captured to a transcript whenever there is no terminal to stream it to,
  # so a call to action printed inside the step reaches a log file and nobody
  # else. Doctor's report belongs in the step; what the operator should do next
  # belongs to bootstrap, which still owns the terminal.
  local doctor_status=0
  run_atyrode doctor "$FLAKE_CONFIG" || doctor_status=$?
  case "$doctor_status" in
    0) ;;
    69)
      DOCTOR_FINDINGS=1
      return 0
      ;;
    *) return 1 ;;
  esac
  printf '%s %s %s\n' "$(paint '1;32' 'Verification passed for')" \
    "$(paint 36 "$FLAKE_CONFIG")" "$(paint 2 "on $SYSTEM")"
}

# Privilege is the one place an operator most deserves to see the argv: these
# are the commands that touch /etc, the trust anchors, the daemon plist, and
# the store volume, and they are exactly the ones a reader wants to audit
# before typing a password.
run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    run_visible "$@"
  elif command_exists sudo; then
    run_visible sudo -- "$@"
  else
    # Every remaining caller is a repair - /etc files, trust anchors, the
    # daemon plist, the store volume - so the message names that.
    die "sudo is required for a privileged repair step"
  fi
}

# Bootstrap repairs the states it can name. Recovery is the exit for the ones
# it cannot: reset this machine's Nix installation the way the manual documents
# an uninstall, then install it fresh and continue normally. Nothing here is a
# one-way door - the store volume is renamed rather than deleted, and every
# file removed is archived first - because a store is a re-fetchable cache
# while an operator's data is not.
reset_nix_installation() {
  local plist archive nixconf volume

  plist="$(nix_daemon_plist)"
  if [[ -e "$plist" ]]; then
    # Best effort: an unloaded daemon reports "Boot-out failed", which is the
    # state being converged on, not an error.
    run_privileged launchctl bootout system/org.nixos.nix-daemon >/dev/null 2>&1 || true
    mkdir -p "$(repair_state_dir)" 2>/dev/null || true
    archive="$(repair_state_dir)/nix-daemon.plist.$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$plist" "$archive" ||
      fail BOOT-E220 "could not archive $plist before removing it" \
        "check that $(repair_state_dir) is writable"
    run_privileged rm -f "$plist" ||
      fail BOOT-E220 "could not remove $plist" "remove it by hand: sudo rm $plist"
    journal_repair "removed the nix-daemon LaunchDaemon $plist" "cp '$archive' '$plist'"
    printf '%s and removed %s (archived at %s)\n' "$(paint 32 'Stopped')" "$plist" "$archive"
  fi

  # /etc/nix is where a dead generation's ssl-cert-file and substituters live.
  # The installer writes a fresh one.
  nixconf="$(etc_root)/nix"
  if [[ -d "$nixconf" && ! -L "$nixconf" ]]; then
    mkdir -p "$(repair_state_dir)" 2>/dev/null || true
    archive="$(repair_state_dir)/etc-nix.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -R "$nixconf" "$archive" ||
      fail BOOT-E221 "could not archive $nixconf before removing it" \
        "check that $(repair_state_dir) is writable"
    run_privileged rm -rf "$nixconf" ||
      fail BOOT-E221 "could not remove $nixconf" "remove it by hand: sudo rm -rf $nixconf"
    journal_repair "removed $nixconf" "cp -R '$archive' '$nixconf'"
    printf '%s %s (archived at %s)\n' "$(paint 32 'Removed')" "$nixconf" "$archive"
  fi

  # Retiring the volume is what routes the installer onto its fresh-create
  # path, and unmounting after frees /nix for the volume it creates.
  if nix_volume_present "$NIX_VOLUME_LABEL"; then
    volume="$(diskutil_field "$NIX_VOLUME_LABEL" 'Device Identifier')"
    [[ -n "$volume" ]] ||
      fail BOOT-E212 "found a $NIX_VOLUME_LABEL volume but could not read its device identifier" \
        "inspect it with: diskutil info '$NIX_VOLUME_LABEL'"
    retire_nix_volume "$volume" "$NIX_VOLUME_LABEL (orphaned $(date -u +%Y%m%dT%H%M%SZ))"
    run_privileged "$(diskutil_command)" unmount force "$volume" >/dev/null 2>&1 || true
  fi
}

print_recovery_plan() {
  local step=1

  printf '\n%s\n' "$(paint 1 'Recovery plan')"
  printf '  %s. Stop the nix-daemon and remove its LaunchDaemon, archiving it first.\n' "$(paint 1 "$step")"
  step=$((step + 1))
  printf '  %s. Remove %s, archiving it first.\n' "$(paint 1 "$step")" "$(etc_root)/nix"
  step=$((step + 1))
  printf '  %s. Retire the %s volume so a fresh one is created, and unmount it.\n' \
    "$(paint 1 "$step")" "$NIX_VOLUME_LABEL"
  printf '       It is renamed and nothing on it is deleted. If it is encrypted and\n'
  printf '       cannot be unlocked, it cannot be renamed, and it is deleted instead:\n'
  printf '       it carries no live store and every Nix path re-downloads.\n'
  step=$((step + 1))
  printf '  %s. Put back every /etc file a previous generation left broken.\n' "$(paint 1 "$step")"
  step=$((step + 1))
  printf '  %s. Install upstream Nix %s for %s and require SHA-256 %s.\n' \
    "$(paint 1 "$step")" "$NIX_VERSION" "$SYSTEM" "$NIX_SHA256"
  step=$((step + 1))
  printf '  %s. Evaluate, activate, and verify %s as a normal run.\n' "$(paint 1 "$step")" "$FLAKE_CONFIG"
  printf '\nEvery removal is archived under %s and undone by %s/undo.log.\n' \
    "$(repair_state_dir)" "$(repair_state_dir)"
  printf 'The old store volume keeps its data until you reclaim the space.\n'
  printf '\nNo changes were made. recover will not proceed without confirmation.\n'
}

begin_mutations() {
  ensure_safe_state_root "$(bootstrap_state_root)"
  start_run_log
  write_interrupted_marker
}

run_activation_phases() {
  local handoff

  enable_flakes_for_process

  run_managed_step evaluation managed_activation_plan

  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && "${BOOTSTRAP_FAILPOINT:-}" == before-activation ]]; then
    printf 'bootstrap: interrupted at test failpoint before-activation\n' >&2
    exit 75
  fi

  run_managed_step activation activate_configuration
  run_managed_step verification verify_installation
  clear_interrupted_marker

  # The login shell is atyrode apply's to converge now, so bootstrap derives
  # this path for one purpose only: naming the shell to exec. It stays a
  # literal rather than a helper because this single message is its only
  # reader, and it stays absolute because the operator's terminal is still the
  # pre-activation one, where a bare `zsh` re-execs whatever was there before.
  if [[ "$SYSTEM" == *-linux ]]; then
    handoff="$HOME/.nix-profile/bin/zsh"
  else
    handoff=/run/current-system/sw/bin/zsh
  fi
  if [[ "$DOCTOR_FINDINGS" -eq 1 ]]; then
    printf '\n%s %s\n' \
      "$(paint '1;33' 'Bootstrap complete, with findings for')" \
      "$(paint 36 "$FLAKE_CONFIG")"
    printf '  %s\n' \
      'The machine is the registered host; these are not bootstrap failures.' \
      "$(printf 'Re-read them any time with: %s' "$(paint '1;36' 'atyrode doctor')")" \
      "$(printf 'Converge what apply owns:   %s' "$(paint '1;36' 'atyrode apply')")"
    printf '\n%s Open a new terminal or run: %s\n' \
      "$(paint 1 'Bootstrap complete.')" \
      "$(paint '1;36' "$(printf 'exec %q -l' "$handoff")")"
    return 0
  fi
  printf '\n%s Open a new terminal or run: %s\n' \
    "$(paint '1;32' 'Bootstrap complete.')" \
    "$(paint '1;36' "$(printf 'exec %q -l' "$handoff")")"
}

apply_configuration() {
  preflight
  print_plan
  confirm_action "Apply this bootstrap plan?"

  if [[ "$UPDATE_SOURCE" -eq 1 ]]; then
    update_checkout || die "source update failed before the interrupted-apply marker was written"
    verify_checkout
    if [[ "$SOURCE_CHANGED" -eq 1 ]]; then
      restart_after_source_update
    fi
  fi

  begin_mutations

  repair_shell_profile_backups
  repair_stale_etc_links
  # After the sweep, never before it: the sweep removes the dangling anchor and
  # this puts a working one back at the same path.
  repair_broken_trust_anchors
  repair_stale_fstab_entry
  repair_orphaned_nix_volume
  ensure_nix
  # Re-derived after the installer rather than reused from preflight: writing
  # its block into those rc files is the installer's own documented step, so
  # on a fresh machine this state does not exist until Nix is installed.
  detect_unrecognised_etc_profiles
  repair_unrecognised_etc_profiles
  run_activation_phases
}

recover_configuration() {
  preflight
  # On a Linux host the managed environment lives in /nix and removing it is
  # destruction, not recovery. The states this resolves are macOS system state.
  [[ "$SYSTEM" == *-darwin ]] ||
    die "recover resets a macOS Nix installation; on $SYSTEM removing /nix is not a recovery"
  print_recovery_plan
  confirm_action "Reset this machine's Nix installation and reinstall?"

  begin_mutations
  reset_nix_installation

  # Re-derived after the reset rather than reused from preflight: the reset
  # changed the machine, and a repair planned against the old state would be
  # answering a question nobody is asking any more.
  detect_shell_profile_backups
  detect_stale_etc_links
  detect_broken_trust_anchors
  detect_stale_fstab_entry

  repair_shell_profile_backups
  repair_stale_etc_links
  repair_broken_trust_anchors
  repair_stale_fstab_entry
  install_pinned_nix || die "the pinned Nix installer failed during recovery"
  # Derived after the installer for the same reason apply does it there: the
  # rc files it writes are what nix-darwin then refuses to overwrite.
  detect_unrecognised_etc_profiles
  repair_unrecognised_etc_profiles
  run_activation_phases
}

init_color
configure_coder_runtime
parse_options "$@"

case "$COMMAND" in
  preflight) preflight ;;
  plan)
    preflight
    print_plan
    ;;
  apply) apply_configuration ;;
  recover) recover_configuration ;;
  verify)
    preflight
    enable_flakes_for_process
    run_managed_step verification verify_installation
    ;;
  -h | --help | help) usage ;;
  '')
    usage >&2
    exit 64
    ;;
  *)
    usage >&2
    die "unknown phase: $COMMAND"
    ;;
esac
