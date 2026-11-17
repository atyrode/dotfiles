# How the operator's own workloads share dev-01's twelve cores. The CI
# account is held apart as a whole slice (modules/nixos/myparcelle-ci-runners.nix:
# 900 %, weight 50); these two caps sit inside the operator's user manager,
# where everything else keeps the default weight of 100 -- above all
# myparcelle-dev.service, the surface people are looking at.
#
#   manifold-terminal-host  every agent terminal and everything started from
#                           one (builds, tests, browsers) shares its cgroup:
#                           at most four cores, half weight.
#   myparcelle-dev-follow   the follow-main rebuilds (client, gate map entry,
#                           /storybook/) are batch work nobody waits on: at
#                           most two cores, weight 20.
#
# Drop-ins rather than unit edits: myParcelle's
# `scripts/setup-hosted-dev.mjs install` renders the follow unit, and the
# terminal-host cap is this machine's arbitration, not the Manifold profile's
# (that unit runs on every Linux Manifold node). A drop-in changes neither
# unit's start behavior: the terminal host is keep-old, so activation keeps
# it running and the manager reload applies the limits to its live cgroup.
#
# A follow whose /storybook/ build ends « exit null » was not stopped by this
# cap or by a timeout (30 min against the 1.5-4 min a follow takes): earlyoom
# (modules/home/agent-tools/contract.nix) sends SIGTERM to the fattest
# preferred `node` once available memory falls below its floor, and a
# ~4.5 GiB Storybook build overlapping preview builds is that process. The
# next tick retries the refresh.
{ host, ... }:
let
  cpuShare = quota: weight: ''
    [Service]
    CPUQuota=${quota}
    CPUWeight=${toString weight}
  '';
in
{
  home-manager.users.${host.username}.xdg.configFile = {
    "systemd/user/manifold-terminal-host.service.d/cpu-share.conf".text = cpuShare "400%" 50;
    "systemd/user/myparcelle-dev-follow.service.d/cpu-share.conf".text = cpuShare "200%" 20;
  };
}
