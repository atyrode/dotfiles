# Babel's storage document and payload key ring, placed by clan rather than
# fetched from a vault (ADR 0008 amendment, secrets row). Two generators,
# because the values have two lifetimes:
#
#   babel-custody is shared and holds what only the operator can supply --
#   the restic repository password, the two Clever Cloud add-on environments,
#   and the deployment's payload key ring -- typed once at `clan vars generate`
#   and reused by every machine. The first three are never deployed: they
#   exist as inputs to the next generator, so a machine only ever receives
#   the one document it reads. The ring is deployed as it is, because it is
#   one value for the whole deployment and babel reads it verbatim.
#
#   babel-archive is per machine and renders the storage document from those
#   inputs under this machine's own identity, with the repository password
#   beside it at the path the document names. sops-nix places both at
#   activation, owned by the account that runs the archive timer, and Home
#   Manager links ~/.config/babel/storage.json and payload-keys.json to the
#   placed files, so babel reads them where it always has and `babel storage
#   configure` is never run on a fleet machine.
#
# The repository password is the one value no provider can reissue: it is
# prompted for, never minted, because the repository already exists. The
# payload key ring is prompted for the same reason -- every object ever
# sealed under a key needs that key, so an existing ring is carried forward
# -- and minted only when the prompt is left empty, which is a deployment
# that has sealed nothing yet. Rotation is an edit of the var, not a
# regeneration: `clan vars get`, append a key and name it active, `clan vars
# set`. No provider hostname, credential, or key ever appears here: each
# arrives through a prompt and travels only through clan's $prompts and $in
# files, which is why the generator scripts never echo them.
{
  config,
  lib,
  pkgs,
  _class,
  ...
}:
let
  user = lib.head (lib.attrNames config.home-manager.users);
  machine = config.clan.core.settings.machine.name;
  group = if _class == "darwin" then "staff" else "users";

  # Where sops-nix places a generator's files on the machine. The storage
  # document must name the password's path at generation time, on an operator
  # device, and clan reports a file's path only once the value exists in the
  # repository -- on the first generation it does not yet, and the script
  # would bake a placeholder into a document that is never regenerated. So
  # every path is stated here from sops-nix's fixed layout, and each is
  # asserted against clan's answer once there is one, so the two cannot
  # silently diverge.
  placed = generator: name: "/run/secrets/vars/${generator}/${name}";
  passwordFile = placed "babel-archive" "repository-password";
  storageDocument = placed "babel-archive" "storage.json";
  payloadKeys = placed "babel-custody" "payload-keys.json";
  agrees =
    generator: name:
    let
      reported = config.clan.core.vars.generators.${generator}.files.${name}.path;
    in
    {
      assertion = reported == "/no-such-path" || reported == placed generator name;
      message = "${generator} expects ${placed generator name}, but sops-nix places it at ${reported}";
    };

  secret = {
    secret = true;
    owner = user;
    inherit group;
    mode = "0600";
  };
in
{
  assertions = [
    (agrees "babel-archive" "repository-password")
    (agrees "babel-archive" "storage.json")
    (agrees "babel-custody" "payload-keys.json")
  ];

  clan.core.vars.generators.babel-custody = {
    share = true;

    prompts."repository-password" = {
      description = "the restic repository password of the Babel archive (existing; never minted here)";
      type = "hidden";
    };
    prompts."cellar-env" = {
      description = "the JSON of `clever addon env <cellar add-on> --format json`, pasted whole";
      type = "multiline-hidden";
    };
    prompts."catalog-env" = {
      description = "the JSON of `clever addon env <catalog add-on> --format json`, pasted whole";
      type = "multiline-hidden";
    };
    prompts."payload-keys" = {
      description = "the payload key ring: paste ~/.config/babel/payload-keys.json from a configured machine whole, or leave empty to mint a fresh ring";
      type = "multiline-hidden";
    };

    files."repository-password" = {
      secret = true;
      deploy = false;
    };
    files."cellar-env.json" = {
      secret = true;
      deploy = false;
    };
    files."catalog-env.json" = {
      secret = true;
      deploy = false;
    };
    # The one custody file every machine holds: babel opens every record with
    # the ring, so the ring is the document, not an input to one.
    files."payload-keys.json" = secret;

    runtimeInputs = [ pkgs.jq ];

    # A bad paste fails here, on the operator's terminal, and never at an
    # activation that would then place an unreadable document. jq's own
    # diagnostics are discarded because they can quote the input; each failure
    # names the prompt and the missing key, never a value. jq is also the
    # emptiness test, because clan puts only the declared inputs and coreutils
    # on the generator's PATH.
    #
    # The ring is validated to babel's own rule set (internal/config/
    # payloadkeys.go): a key id is 1-64 of [a-z0-9._-] starting alphanumeric,
    # a key is exactly 32 bytes of standard base64 -- 43 characters and one
    # pad, which is what makes a truncated paste a refusal here rather than an
    # unopenable corpus -- and active_key_id names a key the ring carries. A
    # minted ring is one such key under a date-stamped id, its material read
    # by jq from a pipe so no key is ever an argument.
    script = ''
      require() { # prompt key...
        local prompt="$1"
        shift
        jq -e . "$prompts/$prompt" >/dev/null 2>&1 ||
          { echo "babel-custody: $prompt is not valid JSON" >&2; exit 1; }
        local key
        for key in "$@"; do
          jq -e --arg key "$key" '.[$key] | strings | length > 0' "$prompts/$prompt" >/dev/null 2>&1 ||
            { echo "babel-custody: $prompt lacks $key" >&2; exit 1; }
        done
      }
      ring_holds() { # description filter
        jq -e -s "length == 1 and (.[0] | $2)" "$prompts/payload-keys" >/dev/null 2>&1 ||
          { echo "babel-custody: payload-keys $1" >&2; exit 1; }
      }
      jq -R -s -e 'test("\\S")' "$prompts/repository-password" >/dev/null 2>&1 ||
        { echo "babel-custody: repository-password is empty" >&2; exit 1; }
      require cellar-env CELLAR_ADDON_HOST CELLAR_ADDON_KEY_ID CELLAR_ADDON_KEY_SECRET
      require catalog-env POSTGRESQL_ADDON_HOST POSTGRESQL_ADDON_PORT POSTGRESQL_ADDON_DB \
        POSTGRESQL_ADDON_USER POSTGRESQL_ADDON_PASSWORD
      cp "$prompts/repository-password" "$out/repository-password"
      cp "$prompts/cellar-env" "$out/cellar-env.json"
      cp "$prompts/catalog-env" "$out/catalog-env.json"

      if jq -R -s -e 'test("\\S")' "$prompts/payload-keys" >/dev/null 2>&1; then
        ring_holds 'is not valid JSON' '.'
        ring_holds 'is not an object naming active_key_id' \
          'type == "object" and (.active_key_id | type == "string" and length > 0)'
        ring_holds 'has an unsupported key_schema' \
          '.key_schema | if . == null then true else type == "number" and floor == . and . <= 1 end'
        ring_holds 'must carry between 1 and 64 keys' \
          '.keys | type == "array" and length > 0 and length <= 64'
        ring_holds 'has a key that is not {key_id, key} with a 32-byte standard-base64 key' \
          'all(.keys[]; type == "object"
            and (.key_id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$"))
            and (.key | type == "string" and (gsub("[\r\n]"; "") | test("^[A-Za-z0-9+/]{43}=$"))))'
        ring_holds 'names a key_id twice' '[.keys[].key_id] | length == (unique | length)'
        ring_holds 'names an active_key_id it does not carry' \
          '.active_key_id as $active | any(.keys[]; .key_id == $active)'
        cp "$prompts/payload-keys" "$out/payload-keys.json"
      else
        head -c 32 /dev/urandom | base64 | tr -d '\n' |
          jq -R --arg key_id "k-$(date -u +%Y%m%d)" \
            '{ key_schema: 1, active_key_id: $key_id, keys: [{ key_id: $key_id, key: . }] }' \
            >"$out/payload-keys.json"
      fi
    '';
  };

  clan.core.vars.generators.babel-archive = {
    dependencies = [ "babel-custody" ];

    files."storage.json" = secret;
    files."repository-password" = secret;

    runtimeInputs = [ pkgs.jq ];

    # The document exactly as babel's own `storage configure` accepted it from
    # the ceremony this replaces: schema 2, shared mode, one restic repository
    # in the Cellar bucket, the catalog over TLS. The identity is the registry
    # name, never the kernel hostname, and one Babel per machine makes the
    # instance the host. The add-on environments are read as files, so no
    # credential is ever an argument.
    script = ''
      jq -n \
        --slurpfile cellar "$in/babel-custody/cellar-env.json" \
        --slurpfile catalog "$in/babel-custody/catalog-env.json" \
        --arg host_id ${lib.escapeShellArg machine} \
        --arg password_file ${lib.escapeShellArg passwordFile} \
        '$cellar[0] as $cellar | $catalog[0] as $catalog | {
          config_schema: 2,
          mode: "shared",
          repository: "s3:https://\($cellar.CELLAR_ADDON_HOST)/tyrode-babel-archive/babel/v1",
          password_file: $password_file,
          host_id: $host_id,
          deployment_id: "babel-prod",
          instance_id: $host_id,
          repository_store: {
            access_key_id: $cellar.CELLAR_ADDON_KEY_ID,
            secret_access_key: $cellar.CELLAR_ADDON_KEY_SECRET
          },
          catalog: {
            host: $catalog.POSTGRESQL_ADDON_HOST,
            port: ($catalog.POSTGRESQL_ADDON_PORT | tonumber),
            database: $catalog.POSTGRESQL_ADDON_DB,
            user: $catalog.POSTGRESQL_ADDON_USER,
            password: $catalog.POSTGRESQL_ADDON_PASSWORD,
            tls_mode: "require"
          }
        }' >"$out/storage.json"
      cp "$in/babel-custody/repository-password" "$out/repository-password"
    '';
  };

  # Babel reads ~/.config/babel/storage.json and payload-keys.json and nothing
  # else; the archive timer's start condition is the storage document. An
  # out-of-store link keeps each where sops-nix placed it, mode 0600 and never
  # in the Nix store, and a link to a file not yet placed is dangling, which
  # every reader (the timer's condition, the push wrapper, doctor, babel's own
  # loader) treats as "not configured" -- the same state as before the value
  # was generated. A shared module rather than `users.<name>`, because naming
  # the user here would read the very attribute set this defines; the fleet's
  # one home is the account that owns the placed files.
  home-manager.sharedModules = [
    (
      { config, ... }:
      {
        xdg.configFile."babel/storage.json".source = config.lib.file.mkOutOfStoreSymlink storageDocument;
        xdg.configFile."babel/payload-keys.json".source = config.lib.file.mkOutOfStoreSymlink payloadKeys;
      }
    )
  ];
}
