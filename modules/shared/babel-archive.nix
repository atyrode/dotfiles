# Babel's storage document, placed by clan rather than fetched from a vault
# (ADR 0008 amendment, secrets row). Two generators, because the values have
# two lifetimes:
#
#   babel-custody is shared and holds what only the operator can supply --
#   the restic repository password and the two Clever Cloud add-on
#   environments -- typed once at `clan vars generate` and reused by every
#   machine. Its files are never deployed: they exist as inputs to the next
#   generator, so a machine only ever receives the one document it reads.
#
#   babel-archive is per machine and renders the storage document from those
#   inputs under this machine's own identity, with the repository password
#   beside it at the path the document names. sops-nix places both at
#   activation, owned by the account that runs the archive timer, and Home
#   Manager links ~/.config/babel/storage.json to the placed document, so
#   babel reads it where it always has and `babel storage configure` is never
#   run on a fleet machine.
#
# The repository password is the one value no provider can reissue: it is
# prompted for, never minted, because the repository already exists. The
# payload key ring is deliberately not part of this document; it moves in its
# own slice, and until then the ceremony's --upload-payload-keys path carries
# it. No provider hostname or credential is written here: each arrives through
# a prompt and travels only through clan's $prompts and $in files, which is
# why the generator scripts never echo them.
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

  # Where sops-nix places this generator's files on the machine. The document
  # must name the password's path at generation time, on an operator device,
  # and clan reports a file's path only once the value exists in the
  # repository -- on the first generation it does not yet, and the script
  # would bake a placeholder into a document that is never regenerated. So
  # both paths are stated here from sops-nix's fixed layout, and each is
  # asserted against clan's answer once there is one, so the two cannot
  # silently diverge.
  placed = name: "/run/secrets/vars/babel-archive/${name}";
  passwordFile = placed "repository-password";
  storageDocument = placed "storage.json";
  agrees =
    name:
    let
      reported = config.clan.core.vars.generators.babel-archive.files.${name}.path;
    in
    {
      assertion = reported == "/no-such-path" || reported == placed name;
      message = "babel-archive expects ${placed name}, but sops-nix places it at ${reported}";
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
    (agrees "repository-password")
    (agrees "storage.json")
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

    runtimeInputs = [ pkgs.jq ];

    # A bad paste fails here, on the operator's terminal, and never at an
    # activation that would then place an unreadable document. jq's own
    # diagnostics are discarded because they can quote the input; each failure
    # names the prompt and the missing key, never a value. jq is also the
    # emptiness test, because clan puts only the declared inputs and coreutils
    # on the generator's PATH.
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
      jq -R -s -e 'test("\\S")' "$prompts/repository-password" >/dev/null 2>&1 ||
        { echo "babel-custody: repository-password is empty" >&2; exit 1; }
      require cellar-env CELLAR_ADDON_HOST CELLAR_ADDON_KEY_ID CELLAR_ADDON_KEY_SECRET
      require catalog-env POSTGRESQL_ADDON_HOST POSTGRESQL_ADDON_PORT POSTGRESQL_ADDON_DB \
        POSTGRESQL_ADDON_USER POSTGRESQL_ADDON_PASSWORD
      cp "$prompts/repository-password" "$out/repository-password"
      cp "$prompts/cellar-env" "$out/cellar-env.json"
      cp "$prompts/catalog-env" "$out/catalog-env.json"
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

  # Babel reads ~/.config/babel/storage.json and nothing else; the archive
  # timer's start condition is that same path. An out-of-store link keeps the
  # document where sops-nix placed it, mode 0600 and never in the Nix store,
  # and a link to a document not yet placed is dangling, which every reader
  # (the timer's condition, the push wrapper, doctor) treats as "not
  # configured" -- the same state as before the value was generated. A shared
  # module rather than `users.<name>`, because naming the user here would
  # read the very attribute set this defines; the fleet's one home is the
  # account that owns the placed files.
  home-manager.sharedModules = [
    (
      { config, ... }:
      {
        xdg.configFile."babel/storage.json".source = config.lib.file.mkOutOfStoreSymlink storageDocument;
      }
    )
  ];
}
