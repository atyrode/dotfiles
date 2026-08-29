#!/usr/bin/env bash
set -euo pipefail

# Configure Babel's storage on this machine: the Bitwarden unlock/retrieve/relock
# ceremony that hands one document to `babel storage configure` over stdin.
#
# The split of responsibility is deliberate and recorded in babel's SPEC.md as
# decisions 38, 50 and 51:
#
#   Bitwarden holds the restic repository password, and nothing else. It is the
#   one secret no provider can reissue: lose it and every snapshot is
#   permanently unreadable. Bitwarden generates it here on first run, so neither
#   this script nor Babel ever invents a credential.
#
#   Clever Cloud holds its own credentials, read live through `clever addon env`.
#   Copying them into the vault would create a second source of truth that goes
#   stale the moment either is rotated.
#
#   Babel receives one complete document on stdin and stays vault-agnostic. It
#   never learns what Bitwarden is, never generates a secret, and never prints
#   one. That keeps its "no credential in output" invariant absolute and keeps
#   its configuration testable without a vault.
#
# The document itself never touches the filesystem: it is piped. Secrets travel
# to helpers through the environment rather than argv, because argv is readable
# from any process listing while the environment is readable only by this user.
# The repository password does reach disk, at the mode-0600 path the document
# points restic at, because restic accepts a password only by file or
# environment and a file keeps it off every command line.
#
# Re-running is safe. The vault item is created only when absent, the password
# is never regenerated once stored, and `babel storage configure` validates
# identity, TLS, privileges and schema compatibility before replacing anything.

usage() {
  cat <<'USAGE'
Usage: babel-storage-configure.sh [flags]

Every value is defaulted or discovered, so the intended invocation carries no
arguments at all: `atyrode apply` offers this ceremony after activation and
supplies this machine's identity from the host registry. The flags below exist
for overrides and recovery, not for routine use.

Flags:
  --host-id ID          this machine's archive identity (default: the identity
                        already configured here; required once, on a machine
                        that has never been configured)
  --instance-id ID      this instance within the deployment (default: --host-id)
  --force-host-id       allow changing an already-configured archive identity
  --deployment-id ID    deployment name (default: babel-prod)
  --catalog-addon REF   Clever Cloud PostgreSQL add-on, by name or addon_ id
                        (default: babel-catalog-prod)
  --cellar-addon REF    Clever Cloud Cellar add-on, by name or addon_ id
                        (default: session-archive)
  --clever-org NAME     organisation owning those add-ons (default: Tyrode)
  --bucket NAME         Cellar bucket holding the repository (default: tyrode-babel-archive)
  --prefix PATH         repository prefix inside the bucket (default: babel/v1)
  --vault-item NAME     Bitwarden item holding the repository password
                        (default: Babel repository password)
  --keep-unlocked       do not relock the vault on exit
  --dry-run             report what would be configured; write nothing
  -h, --help            this text

Requires bw, clever, babel and python3 on PATH. The vault must be logged in;
this script unlocks it and relocks it on exit unless --keep-unlocked.
USAGE
}

host_id=""
instance_id=""
force_host_id=0
deployment_id="babel-prod"
# Add-ons are referenced by name, not by id. An add-on recreated in the console
# keeps its name and gets a new id, so the name is the stable reference and the
# id is resolved at run time -- which also means no opaque identifier has to be
# recorded in this repository or carried by an operator.
catalog_addon="${BABEL_CATALOG_ADDON:-babel-catalog-prod}"
cellar_addon="${BABEL_CELLAR_ADDON:-session-archive}"
clever_org="${BABEL_CLEVER_ORG:-Tyrode}"
bucket="tyrode-babel-archive"
prefix="babel/v1"
vault_item="Babel repository password"
keep_unlocked=0
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host-id)
      host_id="${2:?}"
      shift 2
      ;;
    --instance-id)
      instance_id="${2:?}"
      shift 2
      ;;
    --force-host-id)
      force_host_id=1
      shift
      ;;
    --clever-org)
      clever_org="${2:?}"
      shift 2
      ;;
    --deployment-id)
      deployment_id="${2:?}"
      shift 2
      ;;
    --catalog-addon)
      catalog_addon="${2:?}"
      shift 2
      ;;
    --cellar-addon)
      cellar_addon="${2:?}"
      shift 2
      ;;
    --bucket)
      bucket="${2:?}"
      shift 2
      ;;
    --prefix)
      prefix="${2:?}"
      shift 2
      ;;
    --vault-item)
      vault_item="${2:?}"
      shift 2
      ;;
    --keep-unlocked)
      keep_unlocked=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown flag: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

die() {
  printf 'babel-storage-configure: %s\n' "$1" >&2
  exit 1
}

for tool in bw clever babel python3; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

# Identity is read, not invented. A machine that has already published keeps the
# identity it published under: host generations and commit ordering are
# per-host, so renaming a configured machine starts an empty history and
# abandons the one it already has.
config_file="${XDG_CONFIG_HOME:-$HOME/.config}/babel/storage.json"
configured_host=""
if [ -f "$config_file" ]; then
  configured_host="$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("host_id") or "")
except Exception:
    pass' "$config_file")"
fi
if [ -z "$host_id" ]; then
  host_id="$configured_host"
  [ -n "$host_id" ] ||
    die "this machine has never been configured, so there is no identity to reuse: run 'atyrode apply', which supplies it from the host registry"
elif [ -n "$configured_host" ] && [ "$host_id" != "$configured_host" ] && [ "$force_host_id" -eq 0 ]; then
  die "this machine already publishes as '$configured_host'; changing it to '$host_id' would fork the archive (pass --force-host-id if that is intended)"
fi
# One Babel per machine, so the instance is the host unless told otherwise.
[ -n "$instance_id" ] || instance_id="$host_id"

# Every secret this script handles lives in shell variables and one mode-0600
# file. umask covers anything created below.
umask 077

# The vault is relocked on every exit path, including failure, unless the
# operator asked otherwise. Leaving it unlocked is the failure this ceremony
# exists to bound.
relock() {
  if [ "$keep_unlocked" -eq 0 ] && [ -n "${BW_SESSION:-}" ]; then
    bw lock --session "$BW_SESSION" >/dev/null 2>&1 || true
  fi
}
trap relock EXIT

vault_status="$(bw status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null || echo unknown)"
case "$vault_status" in
  unauthenticated) die "Bitwarden is not logged in: run 'bw login' first" ;;
  unlocked) : ;;
  locked)
    # Prompts on the terminal. The master password is never an argument and
    # never an environment variable this script sets.
    BW_SESSION="$(bw unlock --raw)" || die "vault unlock failed"
    export BW_SESSION
    ;;
  *) die "cannot determine Bitwarden status" ;;
esac
[ -n "${BW_SESSION:-}" ] || die "no vault session; export BW_SESSION or let this script unlock"

bw sync --session "$BW_SESSION" >/dev/null || die "vault sync failed"

render_item='
import json, os
print(json.dumps({
    "type": 1,
    "name": os.environ["BABEL_ITEM_NAME"],
    "notes": ("Restic repository password for the Babel archive. Losing this "
              "makes every snapshot permanently unreadable. Created by "
              "scripts/babel-storage-configure.sh."),
    "login": {"username": "babel-archive", "password": os.environ["BABEL_REPO_PW"]},
}))
'

read_password='
import json, sys
item = json.load(sys.stdin)
print((item.get("login") or {}).get("password") or "")
'

# Retrieved when the item exists; generated by Bitwarden and stored when it does
# not. Generation lives in the vault so the secret is never invented by a script
# and is in its custodian from birth.
created_item=0
if item_json="$(bw get item "$vault_item" --session "$BW_SESSION" 2>/dev/null)"; then
  repo_password="$(printf '%s' "$item_json" | python3 -c "$read_password")"
  [ -n "$repo_password" ] || die "vault item '$vault_item' has no password"
else
  [ "$dry_run" -eq 0 ] || die "vault item '$vault_item' is absent; a real run would create it"
  repo_password="$(bw generate --length 64 --uppercase --lowercase --number --session "$BW_SESSION")"
  [ -n "$repo_password" ] || die "password generation failed"
  item_body="$(BABEL_REPO_PW="$repo_password" BABEL_ITEM_NAME="$vault_item" python3 -c "$render_item")" ||
    die "rendering the vault item failed"
  printf '%s' "$item_body" | bw encode | bw create item --session "$BW_SESSION" >/dev/null ||
    die "storing the generated password in the vault failed"
  created_item=1
fi

# Add-on names are resolved to ids here rather than recorded anywhere. An
# explicit addon_ id is honoured as given, so recovery never depends on the
# lookup succeeding.
resolve_addon() {
  case "$1" in
    addon_*)
      printf '%s' "$1"
      return 0
      ;;
  esac
  clever addon list --org "$clever_org" --format json 2>/dev/null |
    BABEL_ADDON_NAME="$1" python3 -c '
import json, os, sys
raw = sys.stdin.read()
start = min((raw.find(c) for c in "[{" if raw.find(c) >= 0), default=-1)
if start < 0:
    sys.exit(1)
want = os.environ["BABEL_ADDON_NAME"]
for entry in json.loads(raw[start:]):
    if entry.get("name") == want:
        print(entry.get("addonId") or entry.get("id") or "")
        break
'
}

catalog_ref="$catalog_addon"
cellar_ref="$cellar_addon"
catalog_addon="$(resolve_addon "$catalog_ref")" || true
[ -n "$catalog_addon" ] ||
  die "no Clever Cloud add-on named '$catalog_ref' in organisation $clever_org (is 'clever' logged in?)"
cellar_addon="$(resolve_addon "$cellar_ref")" || true
[ -n "$cellar_addon" ] ||
  die "no Clever Cloud add-on named '$cellar_ref' in organisation $clever_org (is 'clever' logged in?)"

# Provider credentials, read live rather than duplicated into the vault. The
# deprecation notice clever prints on stdout would corrupt the JSON, so the
# document is taken from the first brace onward.
addon_env() {
  clever addon env "$1" --format json 2>/dev/null | sed -n '/^{/,$p'
}
catalog_json="$(addon_env "$catalog_addon")"
[ -n "$catalog_json" ] || die "no environment for catalog add-on $catalog_addon"
cellar_json="$(addon_env "$cellar_addon")"
[ -n "$cellar_json" ] || die "no environment for cellar add-on $cellar_addon"

password_file="${XDG_CONFIG_HOME:-$HOME/.config}/babel/repository-password"

render_document='
import json, os, sys
catalog = json.loads(os.environ["BABEL_CATALOG_JSON"])
cellar = json.loads(os.environ["BABEL_CELLAR_JSON"])
locator = "s3:https://%s/%s/%s" % (
    cellar["CELLAR_ADDON_HOST"], os.environ["BABEL_BUCKET"], os.environ["BABEL_PREFIX"])
json.dump({
    "config_schema": 2,
    "mode": "shared",
    "repository": locator,
    "password_file": os.environ["BABEL_PASSWORD_FILE"],
    "host_id": os.environ["BABEL_HOST_ID"],
    "deployment_id": os.environ["BABEL_DEPLOYMENT_ID"],
    "instance_id": os.environ["BABEL_INSTANCE_ID"],
    "repository_store": {
        "access_key_id": cellar["CELLAR_ADDON_KEY_ID"],
        "secret_access_key": cellar["CELLAR_ADDON_KEY_SECRET"],
    },
    "catalog": {
        "host": catalog["POSTGRESQL_ADDON_HOST"],
        "port": int(catalog["POSTGRESQL_ADDON_PORT"]),
        "database": catalog["POSTGRESQL_ADDON_DB"],
        "user": catalog["POSTGRESQL_ADDON_USER"],
        "password": catalog["POSTGRESQL_ADDON_PASSWORD"],
        "tls_mode": "require",
    },
}, sys.stdout)
'

if [ "$dry_run" -eq 1 ]; then
  cellar_host="$(printf '%s' "$cellar_json" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["CELLAR_ADDON_HOST"])')"
  catalog_host="$(printf '%s' "$catalog_json" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["POSTGRESQL_ADDON_HOST"])')"
  printf 'would configure:\n'
  printf '  host           %s\n' "$host_id"
  printf '  instance       %s\n' "$instance_id"
  printf '  deployment     %s\n' "$deployment_id"
  printf '  repository     s3:https://%s/%s/%s\n' "$cellar_host" "$bucket" "$prefix"
  printf '  catalog        %s\n' "$catalog_host"
  printf '  add-ons        %s -> %s\n' "$catalog_ref" "$catalog_addon"
  printf '                 %s -> %s\n' "$cellar_ref" "$cellar_addon"
  printf '  password file  %s\n' "$password_file"
  printf '  vault item     %s (present)\n' "$vault_item"
  exit 0
fi

# The password file is the one secret that must reach disk, because restic reads
# it by path. Written before the document that references it.
mkdir -p "$(dirname "$password_file")"
printf '%s\n' "$repo_password" >"$password_file"
chmod 600 "$password_file"

# One document, on stdin, never a file. Babel validates it and atomically
# replaces its own mode-0600 configuration.
BABEL_CATALOG_JSON="$catalog_json" \
  BABEL_CELLAR_JSON="$cellar_json" \
  BABEL_HOST_ID="$host_id" \
  BABEL_INSTANCE_ID="$instance_id" \
  BABEL_DEPLOYMENT_ID="$deployment_id" \
  BABEL_BUCKET="$bucket" \
  BABEL_PREFIX="$prefix" \
  BABEL_PASSWORD_FILE="$password_file" \
  python3 -c "$render_document" | babel storage configure --from-json -

if [ "$created_item" -eq 1 ]; then
  printf 'created vault item "%s" with a Bitwarden-generated repository password\n' "$vault_item"
  printf 'that password is now the only way to read the archive: keep the vault backed up\n'
fi
printf 'configured %s as instance %s of deployment %s\n' "$host_id" "$instance_id" "$deployment_id"
