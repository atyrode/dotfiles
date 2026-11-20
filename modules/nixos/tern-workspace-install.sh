# shellcheck shell=bash
owner=$1
source=$2/.local/bin/tern
directory=$3
destination=$directory/tern
digest=4bfb8c8396d90d1db58e482e43152a55b3187e3e2e1a058ee230f4e016ff2b58

fail() {
  printf 'Tern workspace install: %s\n' "$*" >&2
  exit 1
}

verified() {
  printf '%s  %s\n' "$digest" "$1" | sha256sum --check --status
}

if [[ ! -e $directory && ! -L $directory ]]; then
  mkdir -m 0755 -- "$directory" || fail "cannot create $directory"
fi
if [[ -L $directory || ! -d $directory || $(stat -c '%u:%g:%a' -- "$directory") != 0:0:755 ]]; then
  fail "$directory must be a real root:root directory with mode 0755"
fi

if [[ -e $destination || -L $destination ]]; then
  if [[ -L $destination || ! -f $destination ]]; then
    fail "$destination must be a regular file, not a symlink"
  fi
  case $(stat -c '%u:%g:%a' -- "$destination") in
    0:0:755 | 0:0:555) ;;
    *) fail "$destination must be root:root with mode 0755 or 0555" ;;
  esac
  verified "$destination" || fail "$destination does not match approved Tern 0.9.29; move it aside before retrying"
  exit 0
fi

stage=$(mktemp -- "$directory/.tern.XXXXXXXX") || fail "cannot stage executable in $directory"
trap 'rm -f -- "$stage"' EXIT

# Open the operator's source with their permissions (their installer uses a symlink).
# Bound the copy above the size of the pinned executable without trusting that path.
group=$(id -g -- "$owner") || fail "cannot resolve primary group for $owner"
if ! setpriv --reuid="$owner" --regid="$group" --init-groups --reset-env --no-new-privs \
  "$(type -P dd)" if="$source" bs=1M count=256 iflag=nonblock,fullblock status=none >"$stage"; then
  fail "cannot read $source as $owner; install the approved Tern 0.9.29 with the vendor installer and retry"
fi
verified "$stage" || fail "$source does not match approved Tern 0.9.29; restore that version and retry"
chmod 0755 -- "$stage" || fail "cannot make staged executable readable and executable"
mv -T --update=none-fail -- "$stage" "$destination" || fail "cannot publish $destination"
printf 'Tern workspace install: installed approved Tern 0.9.29 at %s\n' "$destination"
