#!/usr/bin/env bash
set -euo pipefail
umask 077
ingress=$1 caddyfile=$2 hostname=$3 interface=$4 private=$5 peer=$6 wg_port=$7 web_port=$8 proxy_port=$9
transport=192.0.2.1 other=192.0.2.3 marker=workspace-upstream
url=https://$hostname

tmp=$(mktemp -d /tmp/tern-ingress.XXXXXXXX)
children=()
cleanup() {
  if ((${#children[@]})); then
    kill "${children[@]}" 2>/dev/null || true
    wait || true
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT
cd "$tmp"
export XDG_CONFIG_HOME=$tmp XDG_DATA_HOME=$tmp

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
https() { request --cacert ca.crt --resolve "$hostname:443:$private" "$@"; }
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
ip link set lo up
ip addr add "$transport/24" dev external
ip addr add "$other/32" dev lo
ip link set external up
client ip link set lo up
client ip addr add 192.0.2.2/24 dev outside
client ip link set outside up
client ip route add "$other/32" via "$transport"

bash -e "$ingress"
wg genkey > server.key
wg genkey > client.key
ip link add "$interface" type wireguard
ip addr add "$private/32" dev "$interface"
wg set "$interface" private-key server.key listen-port "$wg_port" peer "$(wg pubkey < client.key)" allowed-ips "$peer/32"
ip link set "$interface" up
ip route add "$peer/32" dev "$interface"

openssl req -x509 -newkey ed25519 -noenc -days 1 -subj /CN=Ingress-test-CA \
  -addext basicConstraints=critical,CA:TRUE -keyout ca.key -out ca.crt
openssl req -new -newkey ed25519 -noenc -subj "/CN=$hostname" -keyout key.pem -out leaf.csr
printf 'subjectAltName=DNS:%s\n' "$hostname" > leaf.ext
openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile leaf.ext -out fullchain.pem
sed -e "s|/var/lib/acme/[^ ]*/fullchain\.pem|$tmp/fullchain.pem|" \
  -e "s|/var/lib/acme/[^ ]*/key\.pem|$tmp/key.pem|" "$caddyfile" > Caddyfile

mkdir upstream public
printf '%s\n' "$marker" > upstream/index.html
cp upstream/index.html upstream/wire
printf 'public-fixture\n' > public/index.html
python3 -m http.server --bind 127.0.0.1 --directory upstream "$web_port" &
children+=("$!")
python3 -m http.server --bind 0.0.0.0 --directory public 443 &
children+=("$!")
caddy run --config Caddyfile --adapter caddyfile &
children+=("$!")

# The wildcard listener must be reachable except when the destination is private.
expect public-fixture request --retry 5 --retry-connrefused --fail "http://$transport:443/"
expect public-fixture request --fail "http://$other:443/"
client ip route add "$private/32" via "$transport"
blocked "http://$private:443/"

client ip link add probe-wg type wireguard
client ip addr add "$peer/32" dev probe-wg
client wg set probe-wg private-key client.key peer "$(wg pubkey < server.key)" \
  endpoint "$transport:$wg_port" allowed-ips "$private/32,$other/32"
client ip link set probe-wg up
client ip route replace "$private/32" dev probe-wg
client ip route replace "$other/32" dev probe-wg

# A certificate-verified upstream response proves WireGuard and DNAT both worked.
expect "$marker" https --retry 5 --retry-connrefused --fail "$url/"
expect "$marker" https --fail -H "Origin: $url" "$url/wire"
expect 403 https -o /dev/null -w '%{http_code}' -H 'Origin: https://foreign.invalid' "$url/"
expect 403 https -o /dev/null -w '%{http_code}' -H 'Origin: https://foreign.invalid' "$url/wire"
expect 403 https -o /dev/null -w '%{http_code}' "$url/wire"
blocked "http://$other:443/"
blocked --cacert ca.crt --connect-to "$hostname:443:$private:$proxy_port" "$url/"
blocked --cacert ca.crt --connect-to "$hostname:443:$transport:$proxy_port" "$url/"
blocked "http://$private/"
plain=$(request --resolve "$hostname:443:$private" -w '\n%{http_code}' "http://$hostname:443/wire")
[[ $plain == *$'\n400' && $plain != *"$marker"* ]]
printf 'Private ingress behavior passed\n'
