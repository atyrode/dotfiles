{
  appimageTools,
  coreutils,
  fetchurl,
  lib,
  procps,
  stdenv,
  stdenvNoCC,
  undmg,
  writeShellScript,
}:

# Orca is repository-owned because nixpkgs' `orca` is the GNOME screen reader,
# not stablyai/orca. Package the official release artifacts unchanged. Linux
# exposes the AppImage CLI; macOS leaves CLI registration to the signed app.
let
  pname = "orca-ide";
  version = "1.4.180";
  sources = {
    "x86_64-linux" = {
      asset = "orca-linux.AppImage";
      hash = "sha256-rztuamf8w80DTKRp/47h0iSxpuLfYhX9hFKv0P2Okqs=";
    };
    "aarch64-linux" = {
      asset = "orca-linux-arm64.AppImage";
      hash = "sha256-nECNc6/U0TK/dLVXQaWqDjD7FmcJzRsRsyNHvyNTYxg=";
    };
    "x86_64-darwin" = {
      asset = "orca-macos-x64.dmg";
      hash = "sha256-rMBFc1FK2FufhUIf1U618VTgbNJ2ENDAmFphWWcOi6E=";
    };
    "aarch64-darwin" = {
      asset = "orca-macos-arm64.dmg";
      hash = "sha256-+ODtEpnLLwr4b8vzGPXN3vNaa1MKrMJ7biZOvsfDxR8=";
    };
  };
  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "Unsupported Orca platform: ${stdenv.hostPlatform.system}");
  src = fetchurl {
    url = "https://github.com/stablyai/orca/releases/download/v${version}/${source.asset}";
    inherit (source) hash;
  };
  meta = {
    description = "Worktree IDE for AI coding agents (official release binary)";
    homepage = "https://github.com/stablyai/orca";
    changelog = "https://github.com/stablyai/orca/releases/tag/v${version}";
    license = lib.licenses.mit;
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
in
if stdenv.hostPlatform.isLinux then
  let
    contents = appimageTools.extractType2 {
      inherit pname src version;
    };

    # Matches upstream's VIRTUAL_DISPLAY_NUMBER: the display `orca serve` starts
    # Xvfb on when DISPLAY is unset.
    virtualDisplayNumber = 99;

    # Upstream already recovers from a leaked virtual display: it checks whether
    # /tmp/.X11-unix/X<n> exists and, when the PID in /tmp/.X<n>-lock is dead,
    # deletes both before respawning Xvfb. That recovery cannot fire under this
    # package. buildFHSEnv mounts a private tmpfs over /tmp/.X11-unix, so the
    # socket Orca's own Xvfb creates is invisible to the next launch, while the
    # lock lands on the shared host /tmp and outlives it. The two halves of the
    # check end up in different visibility domains, the existsSync guard never
    # passes, and the cleanup it gates never runs.
    #
    # So a serve that dies without reaping its child - OOM kill, SIGKILL, or a
    # dying tmux server - strands a live Xvfb holding the display, and every
    # later `orca serve` fails with "Xvfb did not become ready in time" and a
    # Chromium SIGSEGV until someone clears it by hand.
    #
    # Xvfb itself discards a lock whose PID is dead, so that case needs nothing.
    # The only unrecoverable state is a *live* Xvfb, and the trigger for
    # reclaiming one is narrow: the lock holder must still be running, be Xvfb,
    # and have been reparented to init. An Xvfb whose launcher is still alive is
    # a live instance and is deliberately left alone.
    #
    # Reparenting to init means the launcher died, not that nothing is attached:
    # a daemon that outlived its serve can still hold panes on that display, and
    # they go down with it. That is intentional. The display is unreachable to
    # the launch being attempted - the orphan keeps its own /tmp/.X11-unix
    # tmpfs alive, and a new sandbox gets a fresh empty one instead of that
    # socket - so the alternative to taking it is leaving the host wedged,
    # which is the failure this exists to remove.
    reapOrphanedDisplay = writeShellScript "orca-reap-orphaned-display" ''
      set -u
      lock=/tmp/.X${toString virtualDisplayNumber}-lock
      [ -e "$lock" ] || exit 0

      pid=$(${coreutils}/bin/tr -cd '0-9' < "$lock" 2>/dev/null || :)
      [ -n "$pid" ] || exit 0
      kill -0 "$pid" 2>/dev/null || exit 0
      [ "$(${procps}/bin/ps -o comm= -p "$pid" 2>/dev/null)" = Xvfb ] || exit 0
      [ "$(${procps}/bin/ps -o ppid= -p "$pid" 2>/dev/null | ${coreutils}/bin/tr -cd '0-9')" = 1 ] || exit 0

      echo "[orca] display :${toString virtualDisplayNumber} held by orphaned Xvfb $pid; reclaiming it" >&2
      kill -s TERM "$pid" 2>/dev/null || exit 0

      # Xvfb removes its own lock on SIGTERM. Escalate only if it wedges, and
      # never unlink the lock on a PID that has not actually exited: the reason
      # the display is unusable is that a second server must not race the first.
      waited=0
      while [ "$waited" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
        ${coreutils}/bin/sleep 0.1
        waited=$((waited + 1))
      done

      if kill -0 "$pid" 2>/dev/null; then
        kill -s KILL "$pid" 2>/dev/null || :
        waited=0
        while [ "$waited" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
          ${coreutils}/bin/sleep 0.1
          waited=$((waited + 1))
        done
      fi

      if kill -0 "$pid" 2>/dev/null; then
        echo "[orca] display :${toString virtualDisplayNumber} is held by Xvfb $pid, which did not exit." >&2
        echo "[orca] Starting serve now would fail to initialise a display and abort on SIGSEGV." >&2
        echo "[orca] Investigate that process, then remove /tmp/.X${toString virtualDisplayNumber}-lock once it is gone." >&2
        exit 1
      fi

      ${coreutils}/bin/rm -f "$lock"
    '';

    # `orca` is the documented headless entry point, so the reclaim hangs off
    # it rather than the app binary. It is a no-op unless this invocation is the
    # one that would start Xvfb: serve mode with no DISPLAY already provided.
    orcaDispatcher = writeShellScript "orca" ''
      for arg in "$@"; do
        if [ "$arg" = serve ]; then
          [ -n "''${DISPLAY:-}" ] || ${reapOrphanedDisplay} || exit $?
          break
        fi
      done
      exec @orcaIde@ "$@"
    '';
  in
  appimageTools.wrapType2 {
    inherit pname src version;

    # `orca serve` starts Xvfb when DISPLAY is unset, and Git inside Orca's FHS
    # runtime shells out to OpenSSH for SSH remotes. Carry both dependencies so
    # a manually started VPS trial needs no host package or service setup.
    extraPkgs = pkgs: [
      pkgs.openssh
      pkgs.xorg-server
    ];

    extraInstallCommands = ''
      substitute ${orcaDispatcher} "$out/bin/orca" \
        --replace-fail '@orcaIde@' "$out/bin/${pname}"
      chmod +x "$out/bin/orca"

      install -Dm444 ${contents}/orca-ide.desktop "$out/share/applications/orca-ide.desktop"
      substituteInPlace "$out/share/applications/orca-ide.desktop" \
        --replace-fail 'Exec=AppRun' 'Exec=orca'

      cp -R ${contents}/usr/share/icons "$out/share/icons"
    '';

    meta = meta // {
      mainProgram = "orca";
    };
  }
else
  stdenvNoCC.mkDerivation {
    inherit pname src version;

    nativeBuildInputs = [ undmg ];
    sourceRoot = ".";

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/Applications"
      cp -R Orca.app "$out/Applications/Orca.app"
      runHook postInstall
    '';

    # Never mutate the signed and notarized upstream app bundle.
    dontFixup = true;

    inherit meta;
  }
