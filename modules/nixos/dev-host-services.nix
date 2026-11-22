# Services dev-01 does not run, and listeners it does not open.
#
# Ollama is a Home Manager default of the agent-tools contract (a general
# local-model backend); this machine has no model workload, so the user unit
# is switched off here rather than for every host.
#
# systemd-resolved's global LLMNR and mDNS responders bind 0.0.0.0 (:5355 tcp/udp,
# :5353 udp) regardless of the per-link LLMNR=false / MulticastDNS=false in
# fleet/machines/dev-01/network.nix; the global switches remove the sockets.
#
# systemd-oomd is off because the host memory guard is the user-level earlyoom
# in modules/home/agent-tools/contract.nix, which prefers expendable agent
# workers; a second, cgroup-wide killer would overlap it unpredictably.
{ host, ... }:
{
  home-manager.users.${host.username}.services.ollama.enable = false;

  services.resolved.settings.Resolve = {
    LLMNR = "no";
    MulticastDNS = "no";
  };

  systemd.oomd.enable = false;
}
