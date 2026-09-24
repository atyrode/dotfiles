# Nightly backup of Babel's store on the preview hub. Babel runs as a Manifold
# plugin, and its results live in one SQLite database on the hub it is
# installed on: today the preview compose stack on this machine, in the
# container below. Nothing else holds a copy, so this timer puts one in the
# restic repository that already keeps the session transcripts, reached
# through the storage document modules/shared/babel-archive.nix places.
#
#   snapshot   SQLite's own serialization, taken inside the container by the
#              container's Bun with bun:sqlite: every page as of one read
#              transaction, WAL frames included, while the hub keeps writing.
#              Copying the live file instead can capture a torn page or miss
#              the WAL, and a database that later refuses to open is not a
#              backup.
#   stream     restic runs the snapshot itself (--stdin-from-command), so a
#              producer that fails -- no container, no store, an empty image
#              -- leaves no snapshot instead of an empty or truncated one,
#              and no temporary file ever holds the database.
#   tag        `babel-store`, never `babel`: `--tag babel` snapshots are the
#              session transcripts, and an archive index that reads them as
#              such must not find a database among them.
#   custody    the repository, password file, object-store credential and
#              host identity come from the storage document alone. They reach
#              restic's environment and no other process's: restic hands its
#              command the environment minus those four names. jq's
#              diagnostics are discarded because they can quote the document.
#   success    stamped like the archive push, in its own file, so the
#              archive's freshness report never counts a store backup.
{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  inherit (host) username;
  container = "manifold-dev-manifold-1";
  database = "/data/plugins/atyrode.babel/data.db";
  # The container path under the stack's name: stable across nights, so every
  # snapshot of the store is one file's history.
  snapshotPath = "manifold-dev/plugins/atyrode.babel/data.db";

  serialize = ''
    import { Database } from "bun:sqlite";
    const db = new Database(${builtins.toJSON database}, { readonly: true });
    db.run("PRAGMA busy_timeout = 30000");
    const image = db.serialize();
    db.close();
    if (image.byteLength === 0) {
      console.error("babel-store-backup: the store serialized to nothing");
      process.exit(1);
    }
    await Bun.write(Bun.stdout, image);
  '';

  storeBackup = pkgs.writeShellApplication {
    name = "babel-store-backup";
    runtimeInputs = [
      config.virtualisation.docker.rootless.package
      pkgs.restic
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      config_file="''${XDG_CONFIG_HOME:-$HOME/.config}/babel/storage.json"
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/babel"
      container=${lib.escapeShellArg container}

      fail() {
        echo "babel-store-backup: $1" >&2
        exit "''${2:-1}"
      }

      [[ -f "$config_file" ]] || fail "$config_file is not placed; run 'atyrode apply' to place it"
      field() {
        jq -er "$1 | strings | select(length > 0)" "$config_file" 2>/dev/null
      }
      repository="$(field .repository)" || fail "the storage document names no repository"
      password_file="$(field .password_file)" || fail "the storage document names no password file"
      host_id="$(field .host_id)" || fail "the storage document names no host identity"
      access_key_id="$(field .repository_store.access_key_id)" || access_key_id=""
      secret_access_key="$(field .repository_store.secret_access_key)" || secret_access_key=""

      # The hub runs under the rootless engine, whose socket a user unit's
      # environment does not name.
      DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
      export DOCKER_HOST
      running="$(docker container inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" ||
        fail "container $container does not exist"
      [[ "$running" == true ]] || fail "container $container is not running"

      status=0
      result="$(
        export RESTIC_REPOSITORY="$repository" RESTIC_PASSWORD_FILE="$password_file"
        if [[ -n "$access_key_id" ]]; then
          export AWS_ACCESS_KEY_ID="$access_key_id" AWS_SECRET_ACCESS_KEY="$secret_access_key"
        fi
        restic backup --quiet --json --host "$host_id" --tag babel-store \
          --stdin-filename ${lib.escapeShellArg snapshotPath} --stdin-from-command -- \
          env -u RESTIC_REPOSITORY -u RESTIC_PASSWORD_FILE -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
          docker exec "$container" bun -e ${lib.escapeShellArg serialize}
      )" || status=$?
      if (( status != 0 )); then
        printf '%s\n' "$result" >&2
        fail "backup failed (exit $status); not recording a successful backup" "$status"
      fi

      snapshot="$(jq -r 'select(.message_type == "summary") | .snapshot_id // empty' <<<"$result")"
      bytes="$(jq -r 'select(.message_type == "summary") | .total_bytes_processed // 0' <<<"$result")"
      if [[ -z "$snapshot" || "$bytes" == 0 ]]; then
        fail "restic reported no snapshot of the store; not recording a successful backup"
      fi
      echo "babel-store-backup: snapshot $snapshot, $bytes byte(s)" >&2

      umask 077
      mkdir -p "$state_dir"
      stamp_tmp="$(mktemp "$state_dir/.store-last-success.XXXXXX")"
      date -u +%FT%TZ >"$stamp_tmp"
      mv -f "$stamp_tmp" "$state_dir/store-last-success"
    '';
    meta.description = "Nightly restic backup of the preview hub's Babel store";
  };
in
{
  home-manager.users.${username} =
    { config, ... }:
    {
      home.packages = [ storeBackup ];

      # No Install on the service, as with the archive: the timer owns
      # scheduling.
      systemd.user.services.babel-store-backup = {
        Unit = {
          Description = "Back up the preview hub's Babel store";
          After = [
            "docker.service"
            "network.target"
          ];
        };
        Service = {
          Type = "oneshot";
          ExecStart = "${storeBackup}/bin/babel-store-backup";
        };
      };

      # The archive timer's gate, for the archive's reason: nothing writes to
      # the repository on a schedule before the storage document is placed.
      # systemd reads the condition when the timer starts, and activation
      # starts a newly declared timer, so on a machine whose document is
      # already placed it arms at that activation.
      systemd.user.timers.babel-store-backup = {
        Unit = {
          Description = "Nightly backup of the preview hub's Babel store";
          ConditionPathExists = "${config.xdg.configHome}/babel/storage.json";
        };
        Timer = {
          OnCalendar = "*-*-* 03:30:00";
          RandomizedDelaySec = "30m";
          Persistent = true;
        };
        Install.WantedBy = [ "timers.target" ];
      };
    };
}
