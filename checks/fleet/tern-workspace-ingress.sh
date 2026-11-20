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
  actual=$("$@")
  if [[ $actual != "$wanted" ]]; then
    printf >&2 'Expected %s, got %s from %s\n' "$wanted" "$actual" "$*"
    return 1
  fi
}
blocked() {
  local result=0
  request "$@" >/dev/null 2>&1 || result=$?
  if [[ $result != 7 && $result != 28 ]]; then
    printf >&2 'Expected TCP denial, got curl exit %s from %s\n' "$result" "$*"
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
client ip route add "$other/32" via "$transport"

# Compare both the fixture file and kernel identity with the published test key.
[[ $(wg pubkey <"$fixture/server.key") == "$server_public_key" ]]
[[ $(wg show "$interface" public-key) == "$server_public_key" ]]

mkdir upstream public
printf '%s\n' "$marker" >upstream/index.html
cp upstream/index.html upstream/wire
printf 'public-fixture\n' >public/index.html
python3 -m http.server --bind 127.0.0.1 --directory upstream "$web_port" &
children+=("$!")
python3 -m http.server --bind 0.0.0.0 --directory public 443 &
children+=("$!")
# Caddy is already running as the production unit, with the guest CA's cert.
for _ in {1..50}; do
  [[ -z $(ss -Hltn "src $private:$proxy_port") ]] || break
  sleep 0.1
done
[[ -n $(ss -Hltn "src $private:$proxy_port") ]] || {
  echo 'Private Caddy listener did not start' >&2
  exit 1
}

# The wildcard listener must be reachable except when the destination is private.
expect public-fixture request --retry 5 --retry-connrefused --fail "http://$transport:443/"
expect public-fixture request --fail "http://$other:443/"
client ip route add "$private/32" via "$transport"
blocked "http://$private:443/"

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

tunnel "$peer" "$fixture/client.key"
# A certificate-verified upstream response proves WireGuard and DNAT both worked.
expect "$marker" https --retry 5 --retry-connrefused --fail "$url/"
expect "$marker" https --fail -H "Origin: $url" "$url/wire"
expect 403 https -o /dev/null -w '%{http_code}' -H 'Origin: https://foreign.invalid' "$url/"
expect 403 https -o /dev/null -w '%{http_code}' -H 'Origin: https://foreign.invalid' "$url/wire"
expect 403 https -o /dev/null -w '%{http_code}' "$url/wire"
plain=$(request --resolve "$hostname:443:$private" -w '\n%{http_code}' "http://$hostname:443/wire")
[[ $plain == *$'\n400' && $plain != *"$marker"* ]]
blocked "http://$other:443/"
blocked --cacert "$fixture/ca.crt" --connect-to "$hostname:443:$private:$proxy_port" "$url/"
blocked --cacert "$fixture/ca.crt" --connect-to "$hostname:443:$transport:$proxy_port" "$url/"
blocked "http://$private/"

# The unenrolled address with an unknown key must not establish a tunnel.
client ip link del probe-wg
wg genkey >denied.key
tunnel "$denied_peer" denied.key
blocked --cacert "$fixture/ca.crt" --resolve "$hostname:443:$private" "$url/"
read -r _ latest < <(client wg show probe-wg latest-handshakes)
[[ $latest == 0 ]]
printf 'Private ingress behavior passed\n'
