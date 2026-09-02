{ lib, pkgs }:

# Ciphertext is published on purpose (ADR 0008); plaintext never is. The
# encryption guarantee covers the values that go through sops, and this lint
# covers the mistake it cannot: a private key, a token, or an unencrypted
# secrets file committed by hand. The same scanner runs as the pre-commit hook
# on every machine (modules/home/git/pre-commit); this is the backstop for a commit
# that skipped the hook, and the one place that knows what a sops file must
# look like.
pkgs.runCommand "check-secret-shapes" { repo = ../../.; } ''
  cd "$repo"
  fail=0
  if ! ${lib.getExe pkgs.gitleaks} dir . --redact --verbose --no-banner --log-level warn --exit-code 3; then
    printf 'credential-shaped text in a public artifact (above)\n' >&2
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
