# The signer set is reviewed data: a machine may mint its own signing key,
# but a commit it signs is trusted only once modules/home/git/allowed-signers
# names that key. Generation happens on the operator's device and commits the
# public half here, so the moment a key exists and the signer file does not
# name it is a moment this check must fail -- otherwise the fleet would grow a
# key nobody reviewed and every machine would still verify its commits as
# unknown.
#
# Before the first `clan vars generate` there is nothing to compare and the
# check passes on the empty set, which is the only honest verdict then.
{
  lib,
  pkgs,
  system,
  clanConfigs,
}:
let
  signingKeys = lib.mapAttrsToList (
    name: config:
    let
      file = config.clan.core.vars.generators.git-identity.files."signing-key.pub";
    in
    {
      inherit name;
      inherit (file) exists;
      value = if file.exists then file.value else "";
    }
  ) clanConfigs;
  generated = builtins.filter (key: key.exists) signingKeys;
in
pkgs.runCommand "check-git-identity-${system}"
  {
    signers = ../../modules/home/git/allowed-signers;
    keys = builtins.toJSON (map (key: { inherit (key) name value; }) generated);
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    fail=0
    while IFS=$'\t' read -r machine blob; do
      [ -n "$blob" ] || continue
      if ! grep -qF " $blob" "$signers"; then
        echo "$machine's generated signing key is not in modules/home/git/allowed-signers" >&2
        echo "add it through a reviewed commit: alex@tyrode.dev ssh-ed25519 $blob" >&2
        fail=1
      fi
    done < <(jq -r '.[] | [.name, (.value | split(" ")[1] // "")] | @tsv' <<<"$keys")
    test "$fail" -eq 0
    mkdir "$out"
  ''
