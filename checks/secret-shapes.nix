{ pkgs }:

# Ciphertext is published on purpose (ADR 0008); plaintext never is. The
# encryption guarantee covers the values that go through sops, and this lint
# covers the mistake it cannot: a private key, a token, or an unencrypted
# secrets file committed by hand. Every tracked file is scanned for the shapes
# real credentials take. Fixture sentinels in the checks are deliberately far
# shorter than a real key, which is why the age patterns demand a real key's
# length instead of excluding the files that plant them. This file is excluded
# because it defines the patterns it forbids.
pkgs.runCommand "check-secret-shapes" { repo = ../.; } ''
  cd "$repo"
  fail=0
  if matches="$(grep -rInE --exclude=secret-shapes.nix \
    'AGE-SECRET-KEY-1[A-Z0-9]{58,}|AGE-PLUGIN-[A-Z]+-1[A-Z0-9]{58,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|gho_[A-Za-z0-9]{36}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|glpat-[A-Za-z0-9_-]{20}|sk-(proj-)?[A-Za-z0-9]{32,}' .)"; then
    printf 'credential-shaped text in a public artifact:\n%s\n' "$matches" >&2
    fail=1
  fi
  # A sops file is only allowed in the tree encrypted: it carries a `sops:`
  # metadata block and every value is an ENC[...] envelope.
  while IFS= read -r file; do
    if ! grep -q '^sops:' "$file" || ! grep -q 'ENC\[' "$file"; then
      printf 'unencrypted file under secrets/: %s\n' "$file" >&2
      fail=1
    fi
  done < <(find secrets -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) 2>/dev/null)
  test "$fail" -eq 0
  mkdir "$out"
''
