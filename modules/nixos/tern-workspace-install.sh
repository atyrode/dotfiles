# shellcheck shell=bash
version=${4-}
digest=${5-}

fail() {
  printf 'Tern workspace install: %s\n' "$*" >&2
  exit 1
}

verified() {
  printf '%s  %s\n' "$digest" "$1" | sha256sum --check --status
}

if [[ $# -ne 5 || -z $version || ! $digest =~ ^[0-9a-f]{64}$ ]]; then
  fail "usage: owner home directory version sha256"
fi
owner=$1
source=$2/.local/bin/tern
directory=$3
destination=$directory/tern

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
  if verified "$destination"; then
    exit 0
  fi
fi

stage=$(mktemp -- "$directory/.tern.XXXXXXXX") || fail "cannot stage executable in $directory"
trap 'rm -f -- "$stage"' EXIT

# Open the operator's source with their permissions (their installer uses a symlink).
# Bound the copy above the size of the pinned executable without trusting that path.
group=$(id -g -- "$owner") || fail "cannot resolve primary group for $owner"
if ! setpriv --reuid="$owner" --regid="$group" --init-groups --reset-env --no-new-privs \
  "$(type -P dd)" if="$source" bs=1M count=256 iflag=nonblock,fullblock status=none >"$stage"; then
  fail "cannot read $source as $owner; install the approved Tern $version with the vendor installer and retry"
fi
verified "$stage" || fail "$source does not match approved Tern $version; restore that version and retry"
chmod 0755 -- "$stage" || fail "cannot make staged executable readable and executable"
# Rename the verified file over the old path; running processes keep their inode.
mv -T -- "$stage" "$destination" || fail "cannot publish $destination"
printf 'Tern workspace install: installed approved Tern %s at %s\n' "$version" "$destination"
