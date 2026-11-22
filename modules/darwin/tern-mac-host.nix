# Makes the Mac a Tern host for the native Windows desktop, over the fleet
# overlay. It reuses the Tern the operator already installed and the user's
# existing local Tern daemon: nothing is downloaded, copied, replaced or
# restarted here. Only a login-scoped `remote serve` frontend is added, so a
# stopped or absent Tern simply leaves the listener off.
#
# Exposure is closed by construction: one unprivileged UDP port (the
# non-root user agent cannot bind below 1024) bound to the Mac's own
# fleet ULA (never a wildcard), authentication by one explicit Tern public
# key, no relay. This adds no SSH access and does not touch the PF ruleset;
# which peers can reach the port is the fleet's own policy.
{
  homeDirectory,
  lib,
  pkgs,
  username,
  ...
}:
let
  topology = import ../../fleet/mac-tern-host.nix;
  port = toString topology.port;

  # Tern's documented, fixed install location. A copy anywhere else is not
  # this host's Tern.
  app = "/Applications/Tern.app";
  # Keep the frontend's host key separate from Tern's desktop configuration.
  stateDirectory = "${homeDirectory}/.local/state/tern-mac-host";
  retrySeconds = 20;

  authorizedKeys = pkgs.writeText "tern-mac-host-authorized-keys" "${topology.clientPublicKey}\n";

  serve = pkgs.writeShellScript "tern-mac-host" ''
    set -eu
    umask 077
    PATH=/usr/bin:/bin:/usr/sbin:/sbin

    say() { /usr/bin/logger -t tern-mac-host -- "$*"; }

    # Launch agents are installed for every login; only the owner hosts.
    [ "$(/usr/bin/id -un)" = ${lib.escapeShellArg username} ] || exit 0

    # Read the executable the bundle itself declares and accept it only as a
    # plain, executable file inside the bundle that macOS still verifies.
    # Nothing is repaired or replaced; failure just reports and retries.
    plist=${app}/Contents/Info.plist
    if ! declared="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null)" \
      || [ -z "$declared" ]; then
      say "Tern.app is missing or its bundle declares no executable; host stays off"
      exit 1
    fi
    case "$declared" in
      */* | . | .. )
        say "Tern.app declares an unsafe executable name; host stays off"
        exit 1
        ;;
    esac
    tern=${app}/Contents/MacOS/$declared
    if [ -L "$tern" ] || [ ! -f "$tern" ] || [ ! -x "$tern" ]; then
      say "Tern.app declared executable is not a regular executable; host stays off"
      exit 1
    fi
    if ! /usr/bin/codesign --verify --strict ${app} >/dev/null 2>&1; then
      say "Tern.app failed code signature verification; host stays off"
      exit 1
    fi

    /bin/mkdir -p ${lib.escapeShellArg stateDirectory}
    /bin/chmod 0700 ${lib.escapeShellArg stateDirectory}

    # The fleet address appears only once the overlay tunnel is up (and may
    # not be at login). Wait here rather than exiting, so launchd is not
    # asked to respawn the job. Comparison is on the expanded form, so any
    # compression of the address matches.
    have_address() {
      /sbin/ifconfig -a 2>/dev/null | /usr/bin/awk -v want=${lib.escapeShellArg topology.address} '
        function expand(a,    halves, left, right, nl, nr, i, out, g, parts) {
          a = tolower(a)
          if (index(a, "::") == 0) {
            nl = split(a, left, ":"); nr = 0
          } else {
            split(a, halves, "::")
            nl = (halves[1] == "") ? 0 : split(halves[1], left, ":")
            nr = (halves[2] == "") ? 0 : split(halves[2], right, ":")
          }
          out = ""
          for (i = 1; i <= nl; i++) out = out sprintf("%s:", pad(left[i]))
          if (index(a, "::") != 0)
            for (i = 0; i < 8 - nl - nr; i++) out = out "0000:"
          for (i = 1; i <= nr; i++) out = out sprintf("%s:", pad(right[i]))
          return out
        }
        function pad(g) { return substr("0000" g, length(g) + 1) }
        BEGIN { target = expand(want) }
        $1 == "inet6" && index($2, "%") == 0 && expand($2) == target { found = 1 }
        END { exit found ? 0 : 1 }
      '
    }
    until have_address; do
      /bin/sleep ${toString retrySeconds}
    done

    # Foreground, so launchd supervises it. Relay none: reachable only through
    # the fleet, and only by the one authorized key.
    exec "$tern" remote serve --user \
      --listen "[${topology.address}]:${port}" \
      --state-dir ${lib.escapeShellArg stateDirectory} \
      --relay none \
      --authorized-keys ${authorizedKeys}
  '';
in
{
  assertions = [
    {
      assertion =
        builtins.match "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-P][A-Za-z0-9+/]{42}" topology.clientPublicKey
        != null;
      message = "The Mac Tern host authorizes only the native Windows Tern Ed25519 public key";
    }
    {
      assertion = topology.port >= 1024 && topology.port <= 65535 && topology.interface == "fleet";
      message = "The Mac Tern host listens only on one unprivileged UDP port (1024-65535) of the fleet overlay";
    }
  ];

  launchd.user.agents.tern-mac-host = {
    serviceConfig = {
      Label = "dev.atyrode.tern-mac-host";
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "/bin/wait4path ${lib.escapeShellArg (toString serve)} && exec ${lib.escapeShellArg (toString serve)}"
      ];
      RunAtLoad = true;
      # Retries happen inside the script. A real failure (absent or invalid
      # app) is retried slowly; a clean exit stays down.
      KeepAlive.SuccessfulExit = false;
      ThrottleInterval = 120;
      ProcessType = "Background";
      LimitLoadToSessionType = "Aqua";
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };
}
