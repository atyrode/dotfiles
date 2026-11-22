# Hourly, append-only restic archive of this machine's agent session history to
# a Clever Cloud Cellar bucket. restic is the whole mechanism: there is no
# archive service, catalog or analysis stage between the session files and the
# repository, so recovering a session needs only restic and the repository
# password.
#
# One shared generator, omp-session-archive, holds what a machine needs to
# reach the repository and nothing else: the repository password beside a
# restic environment file (repository locator and object-store credential).
# Both are derived from the babel-custody generator
# (modules/shared/babel-custody.nix), which still owns the restic password and
# the Cellar add-on environment typed once by the operator; the add-on
# environment itself is never deployed, so a machine receives only the one
# document it reads. sops-nix places both files at activation, owned by the
# account that runs the archive timer, and Home Manager links
# ~/.config/omp-session-archive/restic.env to the placed file.
#
# The repository is created once, by hand, by the operator (`restic init`):
# the timer never creates it, because a mistyped locator would silently become
# a second, empty archive. The archive is never pruned: sessions are kept
# forever, so no `forget` or `prune` runs here.
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

  # Where sops-nix places a generator's files on the machine. The environment
  # file names the password's path at generation time, on an operator device,
  # and clan reports a file's path only once the value exists in the
  # repository, so every path is stated here from sops-nix's fixed layout and
  # asserted against clan's answer once there is one.
  placed = generator: name: "/run/secrets/vars/${generator}/${name}";
  passwordFile = placed "omp-session-archive" "repository-password";
  resticEnv = placed "omp-session-archive" "restic.env";
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
    (agrees "omp-session-archive" "repository-password")
    (agrees "omp-session-archive" "restic.env")
  ];

  clan.core.vars.generators.omp-session-archive = {
    share = true;
    dependencies = [ "babel-custody" ];

    files."repository-password" = secret;
    files."restic.env" = secret;

    runtimeInputs = [ pkgs.jq ];

    # The Cellar environment is read as a file and rendered by jq, so no
    # credential is ever an argument. @sh quotes every value so the file can be
    # sourced by a shell as well as read as an environment file.
    script = ''
      jq -r \
        --arg password_file ${lib.escapeShellArg passwordFile} \
        '[
          "RESTIC_REPOSITORY=" + ("s3:https://\(.CELLAR_ADDON_HOST)/tyrode-archive/omp-sessions/v1" | @sh),
          "RESTIC_PASSWORD_FILE=" + ($password_file | @sh),
          "AWS_ACCESS_KEY_ID=" + (.CELLAR_ADDON_KEY_ID | @sh),
          "AWS_SECRET_ACCESS_KEY=" + (.CELLAR_ADDON_KEY_SECRET | @sh)
        ] | .[]' "$in/babel-custody/cellar-env.json" >"$out/restic.env"
      cp "$in/babel-custody/repository-password" "$out/repository-password"
    '';
  };

  # The push wrapper, its units and the link live in a shared Home Manager
  # module rather than `users.<name>`, because naming the user here would read
  # the very attribute set this defines; the fleet's one home is the account
  # that owns the placed files.
  home-manager.sharedModules = [
    (
      { config, pkgs, ... }:
      let
        envFile = "${config.xdg.configHome}/omp-session-archive/restic.env";

        push = import ./omp-session-archive-push.nix { inherit lib pkgs machine; };
      in
      {
        xdg.configFile."omp-session-archive/restic.env".source =
          config.lib.file.mkOutOfStoreSymlink resticEnv;

        # The wrapper by name so an operator can run one archive by hand.
        home.packages = [ push ];

        # No Install on the service: a first archive can move multiple GB, and
        # a startup-transaction job that long holds user-manager readiness at
        # "starting". The timer triggers it instead.
        systemd.user.services.omp-session-archive = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
          Unit = {
            Description = "Archive agent session histories with restic";
            After = [ "network.target" ];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${push}/bin/omp-session-archive-push";
          };
        };

        # ConditionPathExists gates arming on the environment file having been
        # placed; systemd leaves the unit inactive and records the unmet path
        # instead of failing it. The condition is evaluated when the timer
        # starts, not continuously, so `atyrode apply` starts the timer after
        # every activation. launchd has no equivalent, so on macOS the
        # wrapper's own check of the same file is the gate.
        #
        # Persistent: a machine that was asleep or off at the top of the hour
        # runs the missed archive once it is back.
        systemd.user.timers.omp-session-archive = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
          Unit = {
            Description = "Hourly restic archive of agent session histories";
            ConditionPathExists = envFile;
          };
          Timer = {
            OnCalendar = "hourly";
            RandomizedDelaySec = "10m";
            Persistent = true;
          };
          Install.WantedBy = [ "timers.target" ];
        };

        launchd.agents.omp-session-archive = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
          enable = true;
          config = {
            ProgramArguments = [ "${push}/bin/omp-session-archive-push" ];
            StartInterval = 3600;
            RunAtLoad = true;
            ProcessType = "Background";
          };
        };
      }
    )
  ];
}
