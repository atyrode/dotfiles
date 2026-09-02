{ lib, pkgs }:

# Ciphertext is published on purpose (ADR 0008); plaintext never is. The
# encryption guarantee covers the values that go through sops, and this lint
# covers the mistake it cannot: a private key, a token, or an unencrypted
# secret committed by hand. The same scanner runs as the pre-commit hook on
# every machine (modules/home/git/pre-commit); this is the backstop for a
# commit that skipped the hook, and the one place that knows what clan's two
# directories must look like.
pkgs.runCommand "check-secret-shapes"
  {
    repo = ../../.;
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    cd "$repo"
    fail=0
    if ! ${lib.getExe pkgs.gitleaks} dir . --redact --verbose --no-banner --log-level warn --exit-code 3; then
      printf 'credential-shaped text in a public artifact (above)\n' >&2
      fail=1
    fi
    # Clan writes every encrypted value to a file named `secret`, under sops/
    # for its own secrets and under vars/ for generated ones. Such a file is
    # only allowed in the tree encrypted: it carries a `sops` metadata block
    # and its value is an ENC[...] envelope.
    while IFS= read -r file; do
      if ! grep -q '"sops"' "$file" || ! grep -q 'ENC\[' "$file"; then
        printf 'unencrypted secret in the tree: %s\n' "$file" >&2
        fail=1
      fi
    done < <(find sops vars -type f -name secret 2>/dev/null)
    # A registered identity is a public recipient and nothing else. The one
    # shape a key.json may have is what `clan secrets ... add` writes: a
    # list of {publickey, type} objects (an older single object is read the
    # same way). Any other field is something that was never meant to be
    # public, an age identity line most of all.
    while IFS= read -r file; do
      if ! jq -e '
          (if type == "array" then . else [.] end)
          | length > 0
          and all(.[]; type == "object"
            and (keys == ["publickey", "type"])
            and (.publickey | type == "string" and startswith("age1"))
            and .type == "age")
        ' "$file" >/dev/null 2>&1; then
        printf 'sops/**/key.json must hold only public age recipients: %s\n' "$file" >&2
        fail=1
      fi
    done < <(find sops -type f -name key.json 2>/dev/null)
    test "$fail" -eq 0
    mkdir "$out"
  ''
