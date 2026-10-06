# Recovery custody of the development hub on dev-01: the hub's owner key and
# the object storage its full-state checkpoints are written to, held by clan
# and placed on no machine.
#
# The hub stays unreplicated: manifold's preview receiver refuses an owner key
# or replica settings in its environment, so its recovery point is a
# checkpoint taken by an operator device -- the retained data volume,
# age-encrypted to the admins group while the hub is stopped, uploaded to a
# Cellar add-on of its own, into a bucket created with Object Lock in
# COMPLIANCE mode. The add-on's single key can write and delete everything it
# owns and the owner key is root on the hub, so neither belongs on a machine:
# every file is a secret that is never deployed (`deploy = false`) and exists
# only for `clan vars get` on an operator device. The bucket name is one of
# them because this repository is public.
#
# Per machine and prompted, never minted: the hub minted its key, and Clever
# Cloud issued the add-on's credentials. A paste that is not the expected
# shape fails here, on the operator's terminal, without being quoted; jq's
# own diagnostics are discarded for the reason babel-archive.nix gives.
{ pkgs, ... }:
{
  clan.core.vars.generators.manifold-dev-recovery = {
    prompts."owner-key" = {
      description = "the development hub's owner key (/data/owner.key of the retained manifold-dev volume; existing, never minted here)";
      type = "hidden";
    };
    prompts."cellar-env" = {
      description = "the JSON of `clever addon env <recovery add-on> --format json`, pasted whole";
      type = "multiline-hidden";
    };
    prompts."bucket" = {
      description = "the name of the Object Lock bucket in that add-on that holds the checkpoints";
      type = "line";
    };

    files."owner-key" = {
      secret = true;
      deploy = false;
    };
    files."cellar-env.json" = {
      secret = true;
      deploy = false;
    };
    files."bucket" = {
      secret = true;
      deploy = false;
    };

    runtimeInputs = [ pkgs.jq ];

    # The key is the 64 hex characters the hub mints, as in
    # manifold-custody; the bucket is an S3 bucket name.
    script = ''
      key="$(tr -d '[:space:]' <"$prompts/owner-key")"
      [[ "$key" =~ ^[0-9a-fA-F]{64}$ ]] ||
        { echo "manifold-dev-recovery: owner-key is not 64 hex characters" >&2; exit 1; }
      jq -e . "$prompts/cellar-env" >/dev/null 2>&1 ||
        { echo "manifold-dev-recovery: cellar-env is not valid JSON" >&2; exit 1; }
      for name in CELLAR_ADDON_HOST CELLAR_ADDON_KEY_ID CELLAR_ADDON_KEY_SECRET; do
        jq -e --arg name "$name" '.[$name] | strings | length > 0' "$prompts/cellar-env" >/dev/null 2>&1 ||
          { echo "manifold-dev-recovery: cellar-env lacks $name" >&2; exit 1; }
      done
      bucket="$(tr -d '[:space:]' <"$prompts/bucket")"
      [[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
        { echo "manifold-dev-recovery: bucket is not an S3 bucket name" >&2; exit 1; }
      printf '%s\n' "$key" >"$out/owner-key"
      cp "$prompts/cellar-env" "$out/cellar-env.json"
      printf '%s\n' "$bucket" >"$out/bucket"
    '';
  };
}
