#!/usr/bin/env bash
set -euo pipefail
umask 077
fixture=$1 hostname=$2 interface=$3 private=$4 peer=$5 wireguard_only=$6 wg_port=$7 web_port=$8 proxy_port=$9
server_public_key=${10} native_port=${11}
marker=workspace-upstream
url=https://$hostname

# Give the isolated veth pair and unrelated listener a disjoint underlay.
underlay=$(
  python3 - "$private" "$peer" "$wireguard_only" <<'PY'
from ipaddress import IPv4Address, IPv4Network
from itertools import islice
import sys

overlay = set(map(IPv4Address, sys.argv[1:]))
pool = IPv4Network(f"{sys.argv[1]}/23", strict=False)
network = next(subnet for subnet in pool.subnets() if not any(address in subnet for address in overlay))
print(*islice(network.hosts(), 3))
PY
)
read -r transport client_transport other <<<"$underlay"

tmp=$(mktemp -d /tmp/tern-ingress.XXXXXXXX)
children=()
cleanup() {
  if ((${#children[@]})); then
    kill "${children[@]}" 2>/dev/null || true
    wait || true
  fi
  ip link del external 2>/dev/null || true
  ip addr del "$other/32" dev lo 2>/dev/null || true
  rm -rf -- "$tmp"
}
trap cleanup EXIT
cd "$tmp"

unshare -n bash -c 'touch client-ready; exec sleep infinity' &
client_pid=$!
children+=("$client_pid")
for _ in {1..50}; do
  [[ ! -e client-ready ]] || break
  sleep 0.1
done
[[ -e client-ready ]]
client() { nsenter --target "$client_pid" --net -- "$@"; }
request() { client curl -q --noproxy '*' -sS --connect-timeout 1 --max-time 2 "$@"; }
https() { request --cacert "$fixture/ca.crt" --resolve "$hostname:443:$private" "$@"; }
expect() {
  local wanted=$1 actual
  shift
  local result=0
  actual=$("$@") || result=$?
  if ((result != 0)); then
    printf >&2 '%s: expected %s, command exited %d: %s\n' "$phase" "$wanted" "$result" "$*"
    if [[ $phase == 'off-tunnel traffic' || $phase == 'missing-key start' ]]; then
      ip -br link show dev external >&2
      ip neigh show dev external >&2
      client ip -br link show dev outside >&2
      client ip neigh show dev outside >&2
    elif [[ $phase == 'enrolled tunnel' ]]; then
      local latest
      read -r _ latest < <(client wg show probe-wg latest-handshakes) || true
      printf >&2 'Client WireGuard latest handshake epoch (0 means none): %s\n' "${latest:-unknown}"
    fi
    return "$result"
  fi
  if [[ $actual != "$wanted" ]]; then
    printf >&2 '%s: expected %s, got %s from %s\n' "$phase" "$wanted" "$actual" "$*"
    return 1
  fi
}
blocked() {
  local result=0
  request "$@" >/dev/null 2>&1 || result=$?
  if [[ $result != 7 && $result != 28 ]]; then
    printf >&2 '%s: expected TCP denial, got curl exit %s from %s\n' "$phase" "$result" "$*"
    return 1
  fi
}

# Give both fixture links explicit MACs before udev can apply its persistent
# address policy. A late MAC change would leave the client's ARP entry stale.
ip link add name external address 02:00:00:00:00:01 type veth \
  peer name outside address 02:00:00:00:00:02 netns "$client_pid"
ip addr add "$transport/24" dev external
ip addr add "$other/32" dev lo
ip link set external up
client ip link set lo up
client ip addr add "$client_transport/24" dev outside
client ip link set outside up

mkdir upstream public
printf '%s\n' "$marker" >upstream/index.html
cp upstream/index.html upstream/wire
printf 'public-fixture\n' >public/index.html
python3 -m http.server --bind 127.0.0.1 --directory upstream "$web_port" &
children+=("$!")
python3 -m http.server --bind 0.0.0.0 --directory public 443 &
children+=("$!")

# Bind deliberately wider than the real native service: the fixture will
# detect a firewall leak even if production's overlay-only bind would hide it.
touch udp-received
python3 - "$native_port" <<'PY' &
import socket
import sys

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener, open("udp-received", "ab", buffering=0) as received:
    listener.bind(("0.0.0.0", int(sys.argv[1])))
    while True:
        payload, sender = listener.recvfrom(1024)
        received.write(payload + b"\n")
        listener.sendto(payload, sender)
PY
children+=("$!")

cat >udp-probe.py <<'PY'
from pathlib import Path
import socket
import sys

expected, target, port, sequence, *source = sys.argv[1:]
payload = f"native-fixture-{sequence}".encode()
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.settimeout(2)
    if source:
        sock.setsockopt(socket.SOL_IP, socket.IP_TRANSPARENT, 1)
        sock.bind((source[0], 0))
    sock.sendto(payload, (target, int(port)))
    try:
        reply = sock.recv(1024)
    except (TimeoutError, ConnectionRefusedError):
        reply = None

# Measure delivery as well as the reply. A spoofed sender cannot receive
# replies normally, so a timeout alone wouldn't prove the packet was dropped.
delivered = payload in Path("udp-received").read_bytes().splitlines()
if expected == "allowed":
    assert delivered and reply == payload, f"{target}: UDP fixture did not echo"
else:
    assert not delivered and reply is None, f"{target}: blocked UDP reached the fixture"
PY

udp_sequence=0
udp_probe() {
  local expected=$1 scope=$2 target=$3
  shift 3
  local -a runner=()
  if [[ $scope == client ]]; then
    runner=(client)
  fi
  ((udp_sequence += 1))
  if ! "${runner[@]}" python3 udp-probe.py "$expected" "$target" "$native_port" "$udp_sequence" "$@"; then
    printf >&2 '%s: expected UDP %s from %s to %s:%s (source: %s)\n' \
      "$phase" "$expected" "$scope" "$target" "$native_port" "${1:-automatic}"
    return 1
  fi
}
wait_listener() {
  local address=$1 protocol=${2:-t}
  for _ in {1..50}; do
    [[ -z $(ss -Hln "-$protocol" "src $address") ]] || return 0
    sleep 0.1
  done
  printf >&2 'Listener did not start: %s\n' "$address"
  return 1
}
wait_listener "127.0.0.1:$web_port"
wait_listener "0.0.0.0:443"
wait_listener "0.0.0.0:$native_port" u

tunnel() {
  local address=$1 key=$2
  client ip link add probe-wg type wireguard
  client ip addr add "$address/32" dev probe-wg
  client wg set probe-wg private-key "$key" peer "$server_public_key" \
    endpoint "$transport:$wg_port" allowed-ips "$private/32,$other/32"
  client ip link set probe-wg up
  client ip route replace "$private/32" dev probe-wg
  client ip route replace "$other/32" dev probe-wg
}

check_traffic() {
  local plain latest
  # Compare both the fixture file and kernel identity with the known test key.
  if [[ $(wg pubkey <"$fixture/server.key") != "$server_public_key" ||
  $(wg show "$interface" public-key) != "$server_public_key" ]]; then
    printf >&2 'WireGuard did not load the guest key\n'
    return 1
  fi
  wait_listener "$private:$proxy_port"

  phase='off-tunnel traffic'
  client ip route replace "$private/32" via "$transport"
  client ip route replace "$other/32" via "$transport"
  expect public-fixture request --fail "http://$transport:443/"
  expect public-fixture request --fail "http://$other:443/"
  blocked "http://$private:443/"
  udp_probe allowed host 127.0.0.1
  udp_probe denied client "$transport"
  udp_probe denied client "$private"
  udp_probe denied client "$private" "$peer"
  udp_probe denied host "$private"
  udp_probe denied host "$private" "$peer"

  phase='enrolled tunnel'
  tunnel "$peer" "$fixture/client.key"
  # A certificate-verified upstream response proves WireGuard and DNAT both worked.
  expect "$marker" https --retry 5 --retry-connrefused --fail "$url/"
  udp_probe allowed client "$private"
  udp_probe denied client "$other"
  expect "$marker" https --fail -H "Origin: $url" "$url/wire"
  expect 403 https -o /dev/null -w '%{http_code}' -H 'Origin: https://foreign.invalid' "$url/"
  expect 403 https -o /dev/null -w '%{http_code}' -H 'Origin: https://foreign.invalid' "$url/wire"
  expect 403 https -o /dev/null -w '%{http_code}' "$url/wire"
  plain=$(request --resolve "$hostname:443:$private" -w '\n%{http_code}' "http://$hostname:443/wire") || {
    printf >&2 '%s: plaintext request to TLS listener failed\n' "$phase"
    return 1
  }
  if [[ $plain != *$'\n400' || $plain == *"$marker"* ]]; then
    printf >&2 '%s: plaintext request did not get the TLS listener rejection\n' "$phase"
    return 1
  fi
  blocked "http://$other:443/"
  blocked --cacert "$fixture/ca.crt" --connect-to "$hostname:443:$private:$proxy_port" "$url/"
  blocked --cacert "$fixture/ca.crt" --connect-to "$hostname:443:$transport:$proxy_port" "$url/"
  blocked "http://$private/"
  client ip link del probe-wg

  phase='WireGuard-only tunnel'
  tunnel "$wireguard_only" "$fixture/wireguard-only.key"
  # This peer has a working WireGuard connection and retains browser access.
  expect "$marker" https --retry 5 --retry-connrefused --fail "$url/"
  udp_probe denied client "$private"
  udp_probe denied client "$private" "$peer"
  client ip link del probe-wg

  phase='unenrolled tunnel'
  wg genkey >denied.key
  tunnel "$wireguard_only" denied.key
  blocked --cacert "$fixture/ca.crt" --resolve "$hostname:443:$private" "$url/"
  read -r _ latest < <(client wg show probe-wg latest-handshakes)
  if [[ $latest != 0 ]]; then
    printf >&2 '%s: unexpected handshake\n' "$phase"
    return 1
  fi
  client ip link del probe-wg
}

expect_stopped() {
  local unit
  for unit in "wireguard-$interface.service" tern-workspace-caddy.service; do
    if systemctl is-active --quiet "$unit"; then
      printf >&2 '%s: unit still active: %s\n' "$phase" "$unit"
      return 1
    fi
  done
  if ip link show dev "$interface" >/dev/null 2>&1; then
    printf >&2 '%s: WireGuard interface still exists\n' "$phase"
    return 1
  fi
}

printf 'Checking private ingress at boot\n'
check_traffic

# Keep the fixtures and client path alive across production unit stops so
# UDP denial can't be explained by stopping the echo server or client.
phase='tunnel stop'
printf 'Checking %s\n' "$phase"
tunnel "$peer" "$fixture/client.key"
expect "$marker" https --retry 5 --retry-connrefused --fail "$url/"
udp_probe allowed client "$private"
systemctl stop "wireguard-$interface.service"
systemctl is-active --quiet tern-workspace-ingress.service
expect_stopped
udp_probe denied client "$private"

phase='ingress stop'
printf 'Checking %s\n' "$phase"
systemctl stop tern-workspace-ingress.service
expect_stopped
if systemctl is-active --quiet tern-workspace-ingress.service; then
  printf >&2 '%s: ingress unit is still active\n' "$phase"
  exit 1
fi
udp_probe denied client "$private"
client ip link del probe-wg
client ip route replace "$private/32" via "$transport"
udp_probe denied client "$private"
udp_probe denied client "$transport"
udp_probe allowed host 127.0.0.1

phase='missing-key start'
printf 'Checking %s\n' "$phase"
rm "$fixture/server.key"
systemctl start "wireguard-$interface.service"
expect_stopped
expect public-fixture request --fail "http://$transport:443/"
tunnel "$peer" "$fixture/client.key"
blocked --cacert "$fixture/ca.crt" --resolve "$hostname:443:$private" "$url/"
udp_probe denied client "$private"
client ip link del probe-wg

printf 'Checking private ingress after restoring the guest key\n'
systemctl restart sops-install-secrets.service
systemctl start "wireguard-$interface.service"
check_traffic
printf 'Private ingress behavior passed\n'
