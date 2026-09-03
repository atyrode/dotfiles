{ pkgs }:

# Public artifacts must carry no production facts: no hosting-provider or
# datacenter identifiers, and no address literals outside the one place a
# machine's own network is declared. The rule was cultural until a deployed
# policy file named a provider (#56); now every tracked file is scanned.
# Loopback and wildcard addresses stay permitted, and this file is excluded
# because it defines the patterns it forbids.
#
# `fleet/machines/` is exempt because a machine that cannot state its own
# address cannot be rebuilt from this repository, and the address is not what
# protects it: the box answers on its port to the whole internet, its name
# resolves publicly, and the address space is scanned continuously. Key-only
# SSH, no root login and a closed firewall are the defence, and those are
# public here too. The public fleet repositories run by the authors of this
# tooling publish their servers' addresses for exactly that reason. The
# provider stays forbidden everywhere: that is a business fact, not a
# security one.
pkgs.runCommand "check-production-facts" { repo = ../../.; } ''
  cd "$repo"
  fail=0
  if matches="$(grep -rInE --exclude=production-facts.nix \
    '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' . \
    | grep -vE '^\./fleet/machines/' \
    | grep -vE '0\.0\.0\.0|127\.0\.0\.1')"; then
    printf 'address literal in a public artifact:\n%s\n' "$matches" >&2
    fail=1
  fi
  if matches="$(grep -rIinE --exclude=production-facts.nix \
    'hetzner|scaleway|ovhcloud|digitalocean|linode|vultr|nbg1|fsn1|hel1|ubuntu-[0-9]+gb' .)"; then
    printf 'provider or datacenter identifier in a public artifact:\n%s\n' "$matches" >&2
    fail=1
  fi
  test "$fail" -eq 0
  mkdir "$out"
''
