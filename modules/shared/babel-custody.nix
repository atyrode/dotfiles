# The custody of the retired Babel archive, kept because it is the only way to
# read what that archive holds. babel-custody is shared and prompted: the restic
# repository password, the two Clever Cloud add-on environments, and the
# deployment's payload key ring, typed once at `clan vars generate` and reused
# by every machine. The first three are never deployed: they are inputs. The
# live session archive (modules/shared/omp-session-archive.nix) derives its own
# repository coordinates from the password and the Cellar environment here.
#
# The repository password is the one value no provider can reissue: it is
# prompted for, never minted. The payload key ring is prompted for the same
# reason -- every object ever sealed under a key needs that key -- and minted
# only when the prompt is left empty. Rotation is an edit of the var, not a
# regeneration: `clan vars get`, append a key and name it active, `clan vars
# set`. No provider hostname, credential, or key ever appears here: each
# arrives through a prompt and travels only through clan's $prompts and $in
# files, which is why the generator script never echoes them.
{
  config,
  lib,
  pkgs,
  _class,
  ...
}:
let
  user = lib.head (lib.attrNames config.home-manager.users);
  group = if _class == "darwin" then "staff" else "users";

  secret = {
    secret = true;
    owner = user;
    inherit group;
    mode = "0600";
  };
in
{
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
}
