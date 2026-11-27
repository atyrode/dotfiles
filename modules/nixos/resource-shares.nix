# Memory the host guarantees to the services that keep it reachable. sshd keeps
# 1 GiB of its pages out of reclaim, so a memory-hungry workload cannot make
# the machine unreachable by squeezing out the login path.
#
# cgroup v2 caps a child's effective memory.min by every ancestor's, so the
# protection must be granted on system.slice too: with memory.min=0 there,
# sshd.service's own value would protect nothing.
_: {
  systemd.slices.system.sliceConfig.MemoryMin = "1G";
  systemd.services.sshd.serviceConfig.MemoryMin = "1G";
}
