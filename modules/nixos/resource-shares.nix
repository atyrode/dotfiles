# Memory the host guarantees to the services that keep it reachable. sshd keeps
# 1 GiB of its pages out of reclaim, so a memory-hungry workload cannot make
# the machine unreachable by squeezing out the login path.
_: {
  systemd.services.sshd.serviceConfig.MemoryMin = "1G";
}
