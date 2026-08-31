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
#   That same vault item carries the Phase B payload key ring, in a hidden
#   `payload_keys` field (babel issue 112). One custody path for the whole
#   deployment rather than two: `atyrode provision babel` hands a machine its
#   locator, its provider credentials and its keys in one act. The ring is the
#   deployment's full append-only history and never the newest key alone,
#   because a host given only the active key seals correctly and cannot open one
#   historical record. Babel installs it at mode 0600 beside storage.json; this
#   script carries it and never prints it.
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
  --upload-payload-keys upload this machine's payload key ring into the vault
                        item and exit, writing nothing else: the one-time step
                        for a machine whose keys predate this ceremony, and the
                        step that follows every "babel sync --generate-key"
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
# An upload carries this machine's payload key ring to the vault and configures
# nothing. It is a separate act because it is an operator's decision about
# custody, not part of provisioning a machine.
upload_ring=0

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
    --upload-payload-keys)
      upload_ring=1
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
# The ring Babel reads on this machine. This script never writes it: `babel
# storage configure` installs it, at the mode 0600 that document has always been
# written with. The path is here to read an existing ring from and to name in a
# message.
payload_keys_file="${XDG_CONFIG_HOME:-$HOME/.config}/babel/payload-keys.json"
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
  # An upload configures nothing, so it needs no archive identity: a machine can
  # hold keys before it holds a configuration, because `babel sync
  # --generate-key` deliberately does not require one.
  [ -n "$host_id" ] || [ "$upload_ring" -eq 1 ] ||
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
    bw lock >/dev/null 2>&1 || true
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

# One export, and nothing below ever repeats it as an argument. `bw` reads
# BW_SESSION from the environment on its own, so naming the session on a
# command line adds nothing except the session itself -- read and write access
# to every item in the vault for as long as it lasts -- in argv, which any
# process listing on this host can read. The environment is readable only by
# this user, which is the whole reason the header above gives for preferring
# it. Exported unconditionally rather than only on the branch that unlocks, so
# the guarantee holds without reasoning about which branch ran.
# checks/babel-archive.nix fails the build if a session argument comes back:
# a redundant flag is exactly the kind of addition that reads as harmless.
export BW_SESSION

bw sync >/dev/null || die "vault sync failed"

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

# The ring in custody, and the item id an edit needs. Both are read from the
# item that already holds the repository password, because one item is the whole
# custody story for this deployment.
read_ring='
import json, sys
item = json.load(sys.stdin)
for field in (item.get("fields") or []):
    if field.get("name") == "payload_keys":
        print(field.get("value") or "")
        break
'

read_item_id='
import json, sys
print(json.load(sys.stdin)["id"] or "")
'

# The upload merge. It is a union on exactly the terms Babel installs one:
#
#   A key the vault carries and this host lacks is kept, because every object
#   ever sealed under it still needs it and nothing in this deployment deletes a
#   remote object. A key this host carries and the vault lacks is added, which
#   is the whole reason to run this. Conflicting material under one key id
#   refuses, because a key id is what selects the key that opens a record: two
#   keys under one id is a fork of the deployment's key space, and nothing here
#   can tell which side is authoritative.
#
# The active key is this host's, because the host that just generated a key is
# the one naming what the fleet should seal under next. Every summary line names
# key ids and counts; the material reaches stdout only inside the item body that
# is piped to `bw`, and never a terminal.
upload_ring_py='
import json, os, sys


def fail(message):
    print("babel-storage-configure: " + message, file=sys.stderr)
    raise SystemExit(1)


def ring_keys(ring, where):
    entries = ring.get("keys") or []
    if not entries:
        fail(where + " carries no keys")
    keys = {}
    for entry in entries:
        key_id, material = entry.get("key_id"), entry.get("key")
        if not key_id or not material:
            fail(where + " carries an entry with no key id or no material")
        if keys.get(key_id, material) != material:
            fail(where + " names key id " + key_id + " twice with different material")
        keys[key_id] = material
    active = ring.get("active_key_id")
    if not active or active not in keys:
        fail(where + " does not name an active key that it carries")
    return keys, active


item = json.load(sys.stdin)
with open(os.environ["BABEL_PAYLOAD_KEYS_FILE"], encoding="utf-8") as handle:
    local = json.load(handle)
local_keys, active = ring_keys(local, "the ring on this host")

fields = list(item.get("fields") or [])
vault_keys, schema = {}, int(local.get("key_schema") or 1)
for field in fields:
    if field.get("name") == "payload_keys":
        vault_ring = json.loads(field.get("value") or "{}")
        vault_keys, _ = ring_keys(vault_ring, "the ring in the vault")
        schema = max(schema, int(vault_ring.get("key_schema") or 1))
        break

merged, added = dict(vault_keys), []
for key_id, material in local_keys.items():
    if key_id in merged:
        if merged[key_id] != material:
            fail("key id " + key_id + " names different material in the vault than on this host; "
                 "reconcile it by hand, because nothing here can tell which side is authoritative")
        continue
    merged[key_id] = material
    added.append(key_id)

ring = {
    "key_schema": schema,
    "active_key_id": active,
    "keys": [{"key_id": key_id, "key": merged[key_id]} for key_id in sorted(merged)],
}
fields = [field for field in fields if field.get("name") != "payload_keys"]
fields.append({"name": "payload_keys", "value": json.dumps(ring, separators=(",", ":")), "type": 1})
item["fields"] = fields
json.dump(item, sys.stdout)

print("ring for the vault: %d key(s), sealing under %s" % (len(merged), active), file=sys.stderr)
print("adding: " + (", ".join(sorted(added)) if added else "nothing this host holds is new"), file=sys.stderr)
kept = sorted(set(vault_keys) - set(local_keys))
if kept:
    print("kept from the vault and absent from this host: " + ", ".join(kept), file=sys.stderr)
'

# One line of the dry-run report. Key ids and counts only.
ring_summary_py='
import json, os
ring = json.loads(os.environ["BABEL_PAYLOAD_KEYS_JSON"])
print("%d key(s) in the vault, sealing under %s" % (
    len(ring.get("keys") or []), ring.get("active_key_id") or "nothing"))
'

# Retrieved when the item exists; generated by Bitwarden and stored when it does
# not. Generation lives in the vault so the secret is never invented by a script
# and is in its custodian from birth.
created_item=0
if item_json="$(bw get item "$vault_item" 2>/dev/null)"; then
  repo_password="$(printf '%s' "$item_json" | python3 -c "$read_password")"
  [ -n "$repo_password" ] || die "vault item '$vault_item' has no password"
elif [ "$upload_ring" -eq 1 ]; then
  # An upload is not a provisioning run and must not mint a repository
  # password: without the item there is nothing to attach a ring to.
  die "vault item '$vault_item' does not exist yet; run this ceremony without --upload-payload-keys first"
else
  [ "$dry_run" -eq 0 ] || die "vault item '$vault_item' is absent; a real run would create it"
  repo_password="$(bw generate --length 64 --uppercase --lowercase --number)"
  [ -n "$repo_password" ] || die "password generation failed"
  item_body="$(BABEL_REPO_PW="$repo_password" BABEL_ITEM_NAME="$vault_item" python3 -c "$render_item")" ||
    die "rendering the vault item failed"
  printf '%s' "$item_body" | bw encode | bw create item >/dev/null ||
    die "storing the generated password in the vault failed"
  created_item=1
fi

vault_ring=""
item_id=""
if [ -n "${item_json:-}" ]; then
  vault_ring="$(printf '%s' "$item_json" | python3 -c "$read_ring")" ||
    die "reading the payload key ring from vault item '$vault_item' failed"
  item_id="$(printf '%s' "$item_json" | python3 -c "$read_item_id")" ||
    die "reading the id of vault item '$vault_item' failed"
fi

if [ "$upload_ring" -eq 1 ]; then
  [ -n "$item_id" ] || die "vault item '$vault_item' has no id, so it cannot be edited"
  [ -f "$payload_keys_file" ] ||
    die "no payload key ring at $payload_keys_file: create one with 'babel sync --generate-key ID' first"
  merged_item="$(printf '%s' "$item_json" |
    BABEL_PAYLOAD_KEYS_FILE="$payload_keys_file" python3 -c "$upload_ring_py")" ||
    die "merging this machine's payload key ring with the vault's failed"
  if [ "$dry_run" -eq 1 ]; then
    printf 'would upload that ring to vault item "%s"; nothing was written\n' "$vault_item"
    exit 0
  fi
  printf '%s' "$merged_item" | bw encode | bw edit item "$item_id" >/dev/null ||
    die "storing the payload key ring in vault item '$vault_item' failed"
  printf 'payload key ring uploaded to vault item "%s"\n' "$vault_item"
  printf 'every other host installs it on its next provision: atyrode provision babel\n'
  exit 0
fi

# A vault item without a ring is the ordinary state of every machine provisioned
# before this ceremony carried keys, so it is a note and not a failure: the
# configuration still has to be installed, and a host with no ring stages its
# Phase B records pending-sync and says so rather than losing them. The note
# names the exact one-time step, because the operator cannot infer it and
# because the cost of not taking it is invisible until a disk dies.
if [ -z "$vault_ring" ]; then
  if [ -f "$payload_keys_file" ]; then
    printf 'note: vault item "%s" carries no payload key ring, and this machine holds one at %s\n' \
      "$vault_item" "$payload_keys_file" >&2
    printf '      until the vault carries it, no other host can open a single Phase B record this one sealed,\n' >&2
    printf '      and losing this disk loses every record sealed under it\n' >&2
    printf '      one time, on this machine: babel-storage-configure --upload-payload-keys\n' >&2
    printf '      then re-provision the fleet: atyrode provision babel\n' >&2
  else
    printf 'note: vault item "%s" carries no payload key ring, so this machine seals no Phase B record yet\n' \
      "$vault_item" >&2
    printf '      create one with "babel sync --generate-key ID", then upload it:\n' >&2
    printf '      babel-storage-configure --upload-payload-keys\n' >&2
  fi
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
document = {
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
}
# The ring rides in the same document, and only when custody carries one: a
# document without the field leaves the keys on this machine exactly as they
# are, which is what every document written before this field existed does.
ring = os.environ["BABEL_PAYLOAD_KEYS_JSON"]
if ring:
    document["payload_keys"] = json.loads(ring)
json.dump(document, sys.stdout)
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
  if [ -n "$vault_ring" ]; then
    ring_state="$(BABEL_PAYLOAD_KEYS_JSON="$vault_ring" python3 -c "$ring_summary_py")" ||
      die "reading the payload key ring from vault item '$vault_item' failed"
  else
    ring_state="absent from the vault"
  fi
  printf '  payload keys   %s\n' "$ring_state"
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
  BABEL_PAYLOAD_KEYS_JSON="$vault_ring" \
  python3 -c "$render_document" | babel storage configure --from-json -

# Babel installs the delivered ring itself, at the mode 0600 that document has
# always been written with. This verifies the outcome rather than trusting it,
# because the whole point of carrying the ring through the ceremony is that no
# operator places a key file by hand: an absent ring here means this machine's
# Babel predates payload-key delivery, and a loose mode means every local
# account can read what the sealing exists to protect.
#
# Both are warnings rather than failures. The configuration is already
# installed, the archive timer's arming hangs off this command's exit status,
# and neither finding is fixed by refusing to have configured the machine.
if [ -n "$vault_ring" ]; then
  if [ ! -f "$payload_keys_file" ]; then
    printf 'warning: the vault delivered a payload key ring and %s was not written;\n' "$payload_keys_file" >&2
    printf '         this babel predates payload-key delivery - upgrade it with "atyrode apply"\n' >&2
  else
    ring_mode="$(stat -c '%a' "$payload_keys_file" 2>/dev/null ||
      stat -f '%Lp' "$payload_keys_file" 2>/dev/null || printf unknown)"
    if [ "$ring_mode" != "600" ]; then
      printf 'warning: %s is mode %s and a payload key ring is 600: chmod 600 %s\n' \
        "$payload_keys_file" "$ring_mode" "$payload_keys_file" >&2
    fi
  fi
fi

if [ "$created_item" -eq 1 ]; then
  printf 'created vault item "%s" with a Bitwarden-generated repository password\n' "$vault_item"
  printf 'that password is now the only way to read the archive: keep the vault backed up\n'
fi
printf 'configured %s as instance %s of deployment %s\n' "$host_id" "$instance_id" "$deployment_id"
