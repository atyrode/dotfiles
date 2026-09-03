#!/usr/bin/env bash
set -euo pipefail

# Carry this machine's Babel payload key ring into the vault.
#
# This script used to be the whole storage ceremony: it fetched the restic
# repository password from Bitwarden, read the Clever Cloud add-on credentials
# live, and piped one document into `babel storage configure`. That half is now
# clan's (ADR 0008 amendment, secrets row): modules/shared/babel-archive.nix
# renders the storage document from values an operator typed once at
# `clan vars generate`, sops-nix places it at activation, and nothing on a
# fleet machine configures storage by hand any more.
#
# What remains here is the one act clan does not yet cover: the Phase B payload
# key ring (babel issue 112), kept in a hidden `payload_keys` field of the vault
# item that held the repository password, because until the ring moves to a
# clan var the vault is its custodian. The ring is the deployment's full
# append-only history and never the newest key alone: a host given only the
# active key seals correctly and cannot open one historical record. This
# script uploads a ring and never installs one -- the ring's own slice will
# deliver it -- so it configures nothing and needs no archive identity.
#
# Secrets travel to helpers through the environment or stdin, never argv:
# argv is readable from any process listing, the environment only by this
# user. Nothing this script handles reaches disk, and no summary line ever
# carries key material -- key ids and counts only.
#
# The vault is relocked on every exit path unless the operator asked otherwise,
# and an absent vault item is refused rather than created: with nothing to
# attach a ring to, there is nothing this script should invent.

usage() {
  cat <<'USAGE'
Usage: babel-storage-configure.sh --upload-payload-keys [flags]

Uploads this machine's payload key ring into the Bitwarden item that custodies
the Babel archive, merging it with the ring already there. Storage itself is
no longer configured here: the document is a clan var, generated once with
`clan vars generate <host>` on an operator device and placed by activation.

Flags:
  --upload-payload-keys upload this machine's payload key ring into the vault
                        item and exit: the one-time step for a machine whose
                        keys predate custody, and the step that follows every
                        "babel sync --generate-key"
  --vault-item NAME     Bitwarden item holding the ring
                        (default: Babel repository password)
  --keep-unlocked       do not relock the vault on exit
  --dry-run             report what would be uploaded; write nothing
  -h, --help            this text

Requires bw and python3 on PATH. The vault must be logged in; this script
unlocks it and relocks it on exit unless --keep-unlocked.
USAGE
}

vault_item="Babel repository password"
keep_unlocked=0
dry_run=0
upload_ring=0

while [ $# -gt 0 ]; do
  case "$1" in
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

# The narration this ceremony shares with the CLI that offers it. Sourced
# rather than reimplemented: the operator is watching one machine, and a
# ceremony that invents its own plain-white dialect is how a careful apply
# turns into an unexplained password prompt halfway down the screen.
# shellcheck source=/dev/null
. "${ATYRODE_NARRATE:?the narration library was not provided}"
# Read by confirm() in the library above, and by the refusal below, so every
# question and every failure says which program is speaking.
NARRATE_NAME=babel-storage-configure

die() {
  refuse "$NARRATE_NAME" "$1"
  exit 1
}

# A bare invocation was, for a long time, how a machine got configured. An
# operator who still types it is told where that went rather than handed a
# ring upload they did not ask for.
[ "$upload_ring" -eq 1 ] ||
  die "storage is a clan var now: run 'clan vars generate <host>' on an operator device, then 'atyrode apply' here; this script only uploads payload keys (--upload-payload-keys)"

for tool in bw python3; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

# The ring Babel reads on this machine, written by `babel sync --generate-key`
# and never by this script.
payload_keys_file="${XDG_CONFIG_HOME:-$HOME/.config}/babel/payload-keys.json"
[ -f "$payload_keys_file" ] ||
  die "no payload key ring at $payload_keys_file: create one with 'babel sync --generate-key ID' first"

# Every secret this script handles lives in shell variables. umask covers
# anything created below.
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
  # Not `bw login`. This fleet's account lives on the EU cloud and the bw CLI
  # defaults to the US one, where a first login fails with a misleading
  # "invalid master password" -- so the obvious advice is the advice that
  # wastes an evening. `atyrode vault login` pins the server before logging in.
  unauthenticated) die "Bitwarden is not logged in: run 'atyrode vault login' first" ;;
  unlocked) : ;;
  locked)
    # Prompts on the terminal. The master password is never an argument and
    # never an environment variable this script sets -- and the argv goes out
    # ahead of it, because a password prompt whose provenance an operator
    # cannot establish is indistinguishable from one a hostile script raised.
    show_command bw unlock --raw
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
# checks/atyrode/babel-archive.nix fails the build if a session argument comes back:
# a redundant flag is exactly the kind of addition that reads as harmless.
export BW_SESSION

run_visible bw sync >/dev/null || die "vault sync failed"

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

# An upload is not a provisioning run and must not mint a repository password:
# without the item there is nothing to attach a ring to. The item is what a
# machine provisioned before the clan cutover created; it is never created
# here.
item_json="$(bw get item "$vault_item" 2>/dev/null)" ||
  die "vault item '$vault_item' does not exist, so there is nothing to attach a ring to"
item_id="$(printf '%s' "$item_json" | python3 -c "$read_item_id")" ||
  die "reading the id of vault item '$vault_item' failed"
[ -n "$item_id" ] || die "vault item '$vault_item' has no id, so it cannot be edited"

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
