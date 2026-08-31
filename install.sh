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
STALE_FSTAB_ENTRY=""
ORPHANED_NIX_VOLUME=""
ORPHANED_NIX_VOLUME_UUID=""
RUN_LOG=""

die() {
  printf 'bootstrap: %s\n' "$*" >&2
  return 1
}

# Every state an operator can land in carries a stable code. The code is the
# handle for improving this script: it names one machine state, it is
# greppable in docs/bootstrap.md, and an unrecognised one is a request for a
# new repair rather than a wall of prose and a dead end.
fail() {
  local code="$1" message="$2" remedy="${3:-}"

  printf 'bootstrap: [%s] %s\n' "$code" "$message" >&2
  [[ -z "$remedy" ]] || printf '  next: %s\n' "$remedy" >&2
  [[ -z "$RUN_LOG" ]] || printf '  log: %s\n' "$RUN_LOG" >&2
  printf '  unrecognised states belong at %s, with the code and the log.\n' "$ISSUE_URL" >&2
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
  ./install.sh verify [OPTIONS]

Options:
  --repo PATH          Use this existing checkout (default: script checkout).
  --config HOST        Select a registered host explicitly.
  --update             Fetch origin and fast-forward main before activation.
  --allow-dirty        Intentionally use a checkout with local changes.
  --allow-non-main     Intentionally use a branch or detached revision other than main.
  --yes                Confirm apply without an interactive prompt.
  -h, --help           Show this help.

Inside a standard Coder workspace, a no-command invocation selects this
repository's architecture-specific portable profile. Elsewhere, run `plan`,
inspect it, then run `apply`.
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
  printf 'bootstrap: warning: previous apply of %s (started %s) was interrupted; state is safe — re-run: ./install.sh apply --config %s\n' \
    "${config:-unknown}" "${started:-unknown}" "${config:-$FLAKE_CONFIG}" >&2
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
      printf 'Kept the interrupted install'"'"'s %s as %s\n' "$target" "$superseded"
    fi
    run_privileged mv "$backup" "$target" ||
      die "could not restore $backup to $target"
    printf 'Restored %s from %s\n' "$target" "$backup"
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
  while IFS= read -r entry; do
    [[ -L "$entry" && ! -e "$entry" ]] || continue
    target="$(readlink "$entry" 2>/dev/null)" || continue
    etc_link_owned "$target" || continue
    STALE_ETC_LINKS+=("$entry")
  done < <(find -P "$etc" -type l 2>/dev/null | LC_ALL=C sort)
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
    printf 'Removed dangling %s (pointed into a store that no longer exists)\n' "$entry"
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
  printf 'Dropped the stale /nix entry from %s (archived at %s)\n' "$fstab" "$archive"
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

repair_orphaned_nix_volume() {
  local renamed

  [[ -n "$ORPHANED_NIX_VOLUME" ]] || return 0
  renamed="$NIX_VOLUME_LABEL (orphaned $(date -u +%Y%m%dT%H%M%SZ))"
  run_privileged "$(diskutil_command)" rename "$ORPHANED_NIX_VOLUME" "$renamed" ||
    fail BOOT-E213 "could not rename the orphaned volume $ORPHANED_NIX_VOLUME" \
      "run: sudo diskutil rename $ORPHANED_NIX_VOLUME '$renamed'"
  journal_repair "renamed orphaned volume $ORPHANED_NIX_VOLUME to '$renamed'" \
    "diskutil rename '$ORPHANED_NIX_VOLUME' '$NIX_VOLUME_LABEL'"
  printf 'Renamed the orphaned volume %s to "%s"\n' "$ORPHANED_NIX_VOLUME" "$renamed"
  printf '  Nothing on it was deleted. Reclaim the space once the install works:\n'
  printf '    sudo diskutil apfs deleteVolume %s\n' "$ORPHANED_NIX_VOLUME"
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

# Nix selects its trust anchors from a fixed list of well-known paths, and a
# dangling link at one of them fails every download with a CA error that names
# the path but not the reason. Re-derived at failure time rather than parsed
# out of prose, because the state is cheaper to observe than to recognise.
stale_ca_bundle() {
  local candidate

  [[ "$SYSTEM" == *-darwin ]] || return 0
  for candidate in \
    "$(etc_root)/ssl/certs/ca-certificates.crt" \
    "$(etc_root)/ssl/cert.pem"; do
    if [[ -L "$candidate" && ! -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

# Every managed step runs Nix, so every managed step fails when Nix cannot
# reach the cache. Without this the operator gets a raw nix error as the last
# word: no code, no log path, nothing to report.
report_managed_failure() {
  local step="$1" ca target

  log_event "managed step failed: $step"
  ca="$(stale_ca_bundle)"
  if [[ -n "$ca" ]]; then
    target="$(readlink "$ca" 2>/dev/null)" || target=""
    if etc_link_owned "$target"; then
      fail BOOT-E301 \
        "$step failed, and $ca points into a store that no longer exists, so Nix cannot verify TLS" \
        "re-run bootstrap: it clears that link before Nix is used"
    else
      fail BOOT-E302 \
        "$step failed, and $ca is a dangling link bootstrap does not own, so Nix cannot verify TLS" \
        "point $ca at a real CA bundle or remove it, then re-run bootstrap"
    fi
  else
    fail BOOT-E399 \
      "$step failed in a way bootstrap does not recognise yet" \
      "send the log below so this state can get its own code and repair"
  fi
}

run_managed_step() {
  local label="$1"

  shift
  "$@" || report_managed_failure "$label"
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
  # The /etc sweep is different: it repairs Nix itself, not the installer. A
  # dangling link at /etc/ssl/certs/ca-certificates.crt stops an already
  # installed Nix from verifying TLS, so gating this on Nix being absent
  # leaves the one machine that most needs it unable to repair itself. On a
  # healthy managed host nothing dangles and the sweep finds nothing.
  detect_stale_etc_links

  warn_if_interrupted

  printf 'Preflight passed\n'
  printf '  system: %s\n' "$SYSTEM"
  printf '  configuration: %s\n' "$FLAKE_CONFIG"
  printf '  repository: %s\n' "$DOTFILES_DIR"
  printf '  revision: %s\n' "$(git -C "$DOTFILES_DIR" rev-parse --short=12 HEAD)"
}

print_plan() {
  local step=1 target

  printf '\nPlan\n'
  if [[ "$UPDATE_SOURCE" -eq 1 ]]; then
    printf '  %s. Fetch the verified origin and fast-forward main.\n' "$step"
    step=$((step + 1))
  fi
  if [[ "${#STALE_PROFILE_BACKUPS[@]}" -gt 0 ]]; then
    printf '  %s. Restore the pre-Nix shell rc file an interrupted Nix install left backed up:\n' \
      "$step"
    for target in "${STALE_PROFILE_BACKUPS[@]}"; do
      printf '       %s\n' "$target"
    done
    step=$((step + 1))
  fi
  if [[ "${#STALE_ETC_LINKS[@]}" -gt 0 ]]; then
    printf '  %s. Remove links a previous nix-darwin left pointing into a store that is gone:\n' \
      "$step"
    for target in "${STALE_ETC_LINKS[@]}"; do
      printf '       %s\n' "$target"
    done
    step=$((step + 1))
  fi
  if [[ -n "$STALE_FSTAB_ENTRY" ]]; then
    printf '  %s. Drop the dead /nix entry from %s, archiving the file first.\n' \
      "$step" "$STALE_FSTAB_ENTRY"
    step=$((step + 1))
  fi
  if [[ -n "$ORPHANED_NIX_VOLUME" ]]; then
    printf '  %s. Rename the orphaned %s volume %s so a fresh one can be created; nothing on it is deleted.\n' \
      "$step" "$NIX_VOLUME_LABEL" "$ORPHANED_NIX_VOLUME"
    step=$((step + 1))
  fi
  if command_exists nix; then
    printf '  %s. Reuse the installed Nix command; do not reinstall it.\n' "$step"
  else
    printf '  %s. Download upstream Nix %s for %s and require SHA-256 %s.\n' \
      "$step" "$NIX_VERSION" "$SYSTEM" "$NIX_SHA256"
  fi
  step=$((step + 1))
  printf '  %s. Evaluate the registered host through the packaged atyrode CLI.\n' "$step"
  step=$((step + 1))
  printf '  %s. Activate %s through atyrode/nh.\n' "$step" "$FLAKE_CONFIG"
  step=$((step + 1))
  printf '  %s. Verify host state and clear the interrupted-apply marker.\n' "$step"
  step=$((step + 1))
  if [[ "$SYSTEM" == *-darwin ]]; then
    printf '  %s. Verify nix-darwin configured the real account login shell.\n' "$step"
  else
    printf '  %s. Register and select the managed Zsh login shell with explicit privilege, then verify the account database.\n' "$step"
  fi
  printf '\nNo changes were made. apply will show this plan again before confirmation.\n'
}

confirm_action() {
  local prompt="$1"
  local answer

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return
  fi
  [[ -t 0 ]] || die "$prompt requires an interactive terminal or --yes"
  printf '%s [y/N] ' "$prompt" >&2
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

ensure_safe_login_shell_marker() {
  local marker

  marker="$(bootstrap_state_root)/login-shell.incomplete"
  if [[ -L "$marker" ]]; then
    die "unsafe login-shell prerequisite marker"
  elif [[ -f "$marker" || ! -e "$marker" ]]; then
    return
  else
    die "login-shell prerequisite marker has an unsupported type"
  fi
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

  git -C "$DOTFILES_DIR" fetch --prune origin || return 1
  git -C "$DOTFILES_DIR" show-ref --verify --quiet refs/remotes/origin/main || return 1

  branch="$(git -C "$DOTFILES_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ "$branch" != main ]]; then
    printf 'bootstrap: moving the checkout from %s to main; return to it with: git -C %s checkout %s\n' \
      "${branch:-a detached revision}" "$DOTFILES_DIR" "${branch:--}" >&2
    if git -C "$DOTFILES_DIR" show-ref --verify --quiet refs/heads/main; then
      git -C "$DOTFILES_DIR" checkout --quiet main || return 1
    else
      git -C "$DOTFILES_DIR" checkout --quiet -b main --track origin/main || return 1
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
    git -C "$DOTFILES_DIR" merge --ff-only origin/main || return 1
    SOURCE_CHANGED=1
  fi
  SOURCE_UPDATED=1
}

restart_after_source_update() {
  local args=(apply --repo "$DOTFILES_DIR" --config "$FLAKE_CONFIG")

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    args+=(--yes)
  fi
  if [[ "$ALLOW_NON_MAIN" -eq 1 ]]; then
    args+=(--allow-non-main)
  fi
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
  if ! curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$NIX_URL"; then
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
  nix run "$DOTFILES_DIR#atyrode" -- "$@"
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
  run_atyrode doctor host "$FLAKE_CONFIG" >/dev/null || return 1
  printf 'Verification passed for %s on %s\n' "$FLAKE_CONFIG" "$SYSTEM"
}

account_login_shell() {
  local user="$1"
  local fixture=""

  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && -n "${BOOTSTRAP_ACCOUNT_SHELL_FILE:-}" ]]; then
    fixture="$BOOTSTRAP_ACCOUNT_SHELL_FILE"
  fi

  if [[ -n "$fixture" ]]; then
    [[ -f "$fixture" && ! -L "$fixture" ]] || return 1
    cat "$fixture"
  elif command_exists getent; then
    getent passwd "$user" 2>/dev/null | awk -F: 'NR == 1 { print $7 }'
  else
    return 1
  fi
}

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo -- "$@"
  else
    printf 'bootstrap: system prerequisite incomplete: sudo is required for a privileged bootstrap step\n' >&2
    return 1
  fi
}

managed_login_shell() {
  if [[ "$SYSTEM" == *-linux ]]; then
    printf '%s\n' "$HOME/.nix-profile/bin/zsh"
  else
    printf '%s\n' /run/current-system/sw/bin/zsh
  fi
}

configure_linux_login_shell() {
  local user target shells_file current

  [[ "$SYSTEM" == *-linux ]] || return 0
  user="$(id -un)"
  target="$(managed_login_shell)"
  shells_file=/etc/shells
  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && -n "${BOOTSTRAP_SHELLS_FILE:-}" ]]; then
    shells_file="$BOOTSTRAP_SHELLS_FILE"
  fi
  [[ -x "$target" ]] || {
    printf 'bootstrap: system prerequisite incomplete: managed Zsh is not executable at %s\n' "$target" >&2
    return 1
  }
  [[ -f "$shells_file" && ! -L "$shells_file" ]] || {
    printf 'bootstrap: system prerequisite incomplete: %s must be a regular file\n' "$shells_file" >&2
    return 1
  }
  if ! grep -Fqx -- "$target" "$shells_file"; then
    # shellcheck disable=SC2016 # Positional parameters expand in the privileged shell.
    run_privileged sh -c \
      'grep -Fqx -- "$1" "$2" || printf "%s\n" "$1" >> "$2"' \
      sh "$target" "$shells_file" || {
      printf 'bootstrap: system prerequisite incomplete: could not register managed Zsh in %s\n' \
        "$shells_file" >&2
      return 1
    }
  fi
  current="$(account_login_shell "$user" || true)"
  if [[ "$current" != "$target" ]]; then
    command_exists chsh || {
      printf 'bootstrap: system prerequisite incomplete: chsh is unavailable\n' >&2
      return 1
    }
    run_privileged chsh -s "$target" "$user" || {
      printf 'bootstrap: system prerequisite incomplete: chsh could not update the account database\n' >&2
      return 1
    }
  fi
  current="$(account_login_shell "$user" || true)"
  [[ "$current" == "$target" ]] || {
    printf 'bootstrap: system prerequisite incomplete: account login shell remains %s\n' \
      "${current:-unknown}" >&2
    return 1
  }
}

mark_login_shell_incomplete() {
  local root temporary marker

  root="$(bootstrap_state_root)"
  marker="$root/login-shell.incomplete"
  ensure_safe_login_shell_marker
  temporary="$(mktemp "$root/.login-shell.incomplete.XXXXXX")"
  {
    printf 'version\t1\n'
    printf 'status\tincomplete\n'
    printf 'owner\tsystem-prerequisite\n'
  } >"$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$marker"
}

clear_login_shell_incomplete() {
  local marker

  marker="$(bootstrap_state_root)/login-shell.incomplete"
  ensure_safe_login_shell_marker
  if [[ -f "$marker" ]]; then
    rm "$marker"
  fi
}

verify_system_login_shell() {
  local diagnostics

  diagnostics="$(run_atyrode doctor system "$FLAKE_CONFIG" 2>/dev/null || true)"
  if ! grep -q '^login-shell: ok ' <<<"$diagnostics"; then
    printf 'bootstrap: system prerequisite incomplete: atyrode could not verify the real account login shell\n' >&2
    return 1
  fi
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

  ensure_safe_state_root "$(bootstrap_state_root)"
  ensure_safe_login_shell_marker
  start_run_log
  write_interrupted_marker

  repair_shell_profile_backups
  repair_stale_etc_links
  repair_stale_fstab_entry
  repair_orphaned_nix_volume
  ensure_nix
  enable_flakes_for_process

  run_managed_step evaluation managed_activation_plan

  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && "${BOOTSTRAP_FAILPOINT:-}" == before-activation ]]; then
    printf 'bootstrap: interrupted at test failpoint before-activation\n' >&2
    exit 75
  fi

  run_managed_step activation activate_configuration
  run_managed_step verification verify_installation
  mark_login_shell_incomplete
  clear_interrupted_marker

  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && "${BOOTSTRAP_FAILPOINT:-}" == after-login-shell-receipt ]]; then
    printf 'bootstrap: interrupted at test failpoint after-login-shell-receipt\n' >&2
    exit 75
  fi

  if ! configure_linux_login_shell || ! verify_system_login_shell; then
    printf 'Home Manager activation completed, but the login-shell system prerequisite is incomplete.\n' >&2
    printf 'Fix the reported system boundary and run ./install.sh verify --config %s.\n' \
      "$FLAKE_CONFIG" >&2
    return 69
  fi
  clear_login_shell_incomplete

  printf '\nBootstrap complete. Open a new terminal or run: exec %q -l\n' \
    "$(managed_login_shell)"
}

configure_coder_runtime
parse_options "$@"

case "$COMMAND" in
  preflight) preflight ;;
  plan)
    preflight
    print_plan
    ;;
  apply) apply_configuration ;;
  verify)
    preflight
    enable_flakes_for_process
    run_managed_step verification verify_installation
    verify_system_login_shell || die "login-shell system prerequisite is incomplete"
    clear_login_shell_incomplete
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
