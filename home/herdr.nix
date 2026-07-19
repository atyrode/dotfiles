{ lib, pkgs, ... }:

{
  # herdr trial (#269): the agent multiplexer whose server runs where the
  # agents run. On the Linux hosts `herdr` is the server the Mac attaches to
  # (`herdr --remote tyrode.dev --session agents`); on the Mac the same pinned
  # binary is the thin client. Remote attach reuses a matching server binary
  # from ~/.nix-profile/bin/herdr (in herdr's candidate list), so the single
  # pin keeps client and server in lockstep and no mutable ~/.local/bin copy
  # is ever installed. Nix owns the binary, this config, and the vendored
  # skill (agents/skills/herdr); herdr owns its state (~/.local/state/herdr),
  # worktrees (~/.herdr/worktrees), and the version-stamped OMP integration
  # file seeded below. OMP auth, sessions, and caches stay OMP-owned.
  home.packages = [ pkgs.herdr ];

  # Usage publication belongs beside herdr itself; the agent-tools profile
  # that imports this module is the single capability gate. The publisher is
  # the pinned code binary's `code herdr-usage` daemon (atyrode/code; the
  # repository bash script is retired), but the Linux-only unit stays
  # dormant: it is wanted by no target and must be started explicitly.
  # No Darwin launchd agent.

  systemd.user.services.atyrode-herdr-usage-publisher = lib.mkIf pkgs.stdenv.isLinux {
    Unit = {
      Description = "Publish OMP vault usage to Herdr sidebars";
      After = [
        "network.target"
        "atyrode-omp-auth-brokers.service"
      ];
    };
    Service = {
      Type = "simple";
      ExecStart = ''${lib.getExe pkgs.code} herdr-usage --refresh-hint "^a u"'';
      Restart = "on-failure";
    };
  };

  # Schema verified against herdr v0.7.4 (src/config/model.rs). Partial TOML
  # is supported and unknown nested keys are ignored, but a parse error makes
  # herdr fall back to ALL defaults with only a startup diagnostic —
  # checks/herdr.nix therefore parses this rendered file and re-asserts the
  # keys below. Ownership matches Claude's settings.json: durable operator
  # policy lives in the store; the settings UI (prefix+s) cannot write
  # through the read-only link, so machine-local experiments go through a
  # temporary HERDR_CONFIG_PATH instead.
  xdg.configFile."herdr/config.toml".text = ''
    # Managed by Nix (home/herdr.nix); edits here do not survive activation.

    # A missing (or true) value runs the first-run wizard, which writes back
    # to this file; that write must never happen against the store link.
    onboarding = false

    [session]
    # Trial contract (#269): after a herdr server restart, integrated OMP
    # panes relaunch as `omp --resume=<session path or id>`.
    resume_agents_on_restore = true

    [update]
    # The pin is the only update path: herdr already hard-disables its
    # self-updater for /nix/store binaries, so version polling would only
    # nag. Agent-detection manifest fetches stay off for store purity — the
    # OMP integration is socket-authoritative and never consults them.
    version_check = false
    manifest_check = false

    [experimental]
    # Keep pane scrollback off disk: terminal output routinely carries
    # secrets and this path has no obfuscation guard.
    pane_history = false
    # Repaint pane-emitted Kitty graphics onto the host terminal — the
    # herdr-side link OMP inline images depend on under the Rio trial
    # (#278 trial gate 1). Experimental upstream; the flag flip is itself
    # part of the trial.
    kitty_graphics = true

    [remote]
    # Not an ~/.ssh/config edit: herdr generates a private config that
    # Includes the user's own (whose values win), adds Host * keepalive
    # fallbacks, and dials through a private ControlMaster socket. Client
    # side only.
    manage_ssh_config = true

    # prefix+u pulls the usage publisher's next broker fetch forward
    # (SIGUSR1 into the daemon's event loop; the section's status row
    # advertises the chord as "^a u"). The binding runs where keys are
    # parsed: natively in VPS-side sessions; Mac remote attaches must use
    # `--remote-keybindings server`, because default local mode strips
    # client custom-command bindings server-side.
    [[keys.command]]
    key = "prefix+u"
    command = "systemctl --user kill --signal=SIGUSR1 atyrode-herdr-usage-publisher.service"
    description = "Refresh vault usage now"

    [ui]
    # The settings UI cannot persist changes through the read-only store
    # link, so make the operator's preferred agent ordering the startup default.
    agent_panel_sort = "priority"
    sidebar_sections_height = 18

    # Dormant owner atyrode:usage feeds one bar per reported account window:
    # the account/window title stays left and percent/reset info stays right.
    [[ui.sidebar.sections]]
    id = "usage"
    title = "usage"
    highlight_token = "vault_broker"
    max_rows = 18
    placement = "below_agents"

    [ui.toast]
    # In-TUI toasts render inside the server's TUI and therefore reach the
    # Mac thin client; "system" would fire on the headless VPS and the
    # default "off" hides agent completion entirely.
    delivery = "herdr"
  '';

  # The integration file is herdr-managed, version-stamped mutable state
  # (same machine-local stance as #65): the installer overwrites exactly
  # <agent dir>/extensions/herdr-omp-agent-state.ts and nothing else, and
  # the extension is a no-op outside herdr panes (env-gated on
  # HERDR_ENV/HERDR_SOCKET_PATH/HERDR_PANE_ID), so installing on every
  # platform is safe and lets Mac-local herdr sessions report too. The
  # installer resolves PI_CODING_AGENT_DIR exactly like OMP does (with a
  # leading ~ expanded), requires the agent dir to exist, and creates
  # extensions/ itself; the mkdir mirrors that resolution so a fresh
  # machine's first activation and later manual installs both work.
  home.activation.seedHerdrOmpIntegration =
    lib.hm.dag.entryAfter
      [
        "installPackages"
        "linkGeneration"
      ]
      ''
        herdrAgentDir="''${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
        case "$herdrAgentDir" in
          "~") herdrAgentDir="$HOME" ;;
          "~/"*) herdrAgentDir="$HOME/''${herdrAgentDir#\~/}" ;;
        esac
        if [[ -v DRY_RUN ]]; then
          echo "(dry run) would install the herdr OMP integration into $herdrAgentDir/extensions"
        else
          mkdir -p "$herdrAgentDir/extensions"
          if ! ${lib.getExe pkgs.herdr} integration install omp; then
            echo "warning: herdr OMP integration install failed; run 'herdr integration install omp' manually" >&2
          fi
        fi
      '';
}
