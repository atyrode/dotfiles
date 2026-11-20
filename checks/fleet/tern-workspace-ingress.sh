#!/usr/bin/env bash
set -euo pipefail
umask 077
fixture=$1 hostname=$2 interface=$3 private=$4 peer=$5 denied_peer=$6 wg_port=$7 web_port=$8 proxy_port=$9
server_public_key=${10}
marker=workspace-upstream
url=https://$hostname

# Give the isolated veth pair and unrelated listener a disjoint underlay.
underlay=$(
  python3 - "$private" "$peer" "$denied_peer" <<'PY'
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
      ip neigh show dev external >&2
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

ip link add external type veth peer name outside
ip link set outside netns "$client_pid"
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
wait_listener() {
  local address=$1
  for _ in {1..50}; do
    [[ -z $(ss -Hltn "src $address") ]] || return 0
    sleep 0.1
  done
  printf >&2 'Listener did not start: %s\n' "$address"
  return 1
}
wait_listener "127.0.0.1:$web_port"
wait_listener "0.0.0.0:443"

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

  phase='enrolled tunnel'
  tunnel "$peer" "$fixture/client.key"
  # A certificate-verified upstream response proves WireGuard and DNAT both worked.
  expect "$marker" https --retry 5 --retry-connrefused --fail "$url/"
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

  phase='unenrolled tunnel'
  wg genkey >denied.key
  tunnel "$denied_peer" denied.key
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

# Only restart production services. Keep both HTTP fixtures and the veth
# underlay alive so recovery does not depend on rebuilding unrelated listeners.
phase='ingress stop'
printf 'Checking %s\n' "$phase"
systemctl stop tern-workspace-ingress.service
expect_stopped

phase='missing-key start'
printf 'Checking %s\n' "$phase"
rm "$fixture/server.key"
systemctl start "wireguard-$interface.service"
expect_stopped
expect public-fixture request --fail "http://$transport:443/"
tunnel "$peer" "$fixture/client.key"
blocked --cacert "$fixture/ca.crt" --resolve "$hostname:443:$private" "$url/"
client ip link del probe-wg

printf 'Checking private ingress after restoring the guest key\n'
systemctl restart sops-install-secrets.service
systemctl start "wireguard-$interface.service"
check_traffic
printf 'Private ingress behavior passed\n'
