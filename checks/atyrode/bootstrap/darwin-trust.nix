{ pkgs }:

let
  inherit (import ./harness.nix { inherit pkgs; }) mkScenario;
in
mkScenario "darwin-trust" ''
  # Named by the environment: a login shell started under the dead
  # generation keeps exporting the path long after the store is collected.
  trust_anchor_case darwin-trust-anchor-env
  export NIX_SSL_CERT_FILE="$anchor"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-env.out"
  grep -F "Restore the TLS trust anchor" "$TMPDIR/anchor-env.out" >/dev/null
  grep -F "$anchor (named by NIX_SSL_CERT_FILE)" "$TMPDIR/anchor-env.out" >/dev/null
  test ! -e "$anchor"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  test -L "$anchor" && test -e "$anchor"
  test "$(readlink "$anchor")" = "$bundle"
  grep -F "rm -f '$anchor'" "$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log" >/dev/null
  # Idempotent: the anchor now resolves, so a second run plans nothing.
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-again.out"
  grep -Fq 'Restore the TLS trust anchor' "$TMPDIR/anchor-again.out" && exit 1
  unset NIX_SSL_CERT_FILE

  # Named by /etc/nix/nix.conf, and still a dangling link this toolchain
  # owns: the sweep removes it and the restore puts a working file back, in
  # that order, so the machine ends with a resolving anchor.
  trust_anchor_case darwin-trust-anchor-conf
  mkdir -p "$etc/nix"
  printf 'ssl-cert-file = %s\n' "$anchor" > "$etc/nix/nix.conf"
  ln -s /nix/store/0000000000000000000000000000000-etc/ca.crt "$anchor"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-conf.out"
  grep -F "Remove links a previous nix-darwin left" "$TMPDIR/anchor-conf.out" >/dev/null
  grep -F "$anchor (named by $etc/nix/nix.conf)" "$TMPDIR/anchor-conf.out" >/dev/null
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  test "$(readlink "$anchor")" = "$bundle"

  # Named by the nix-daemon launchd plist: the daemon, not the client, is
  # what fetches from the binary cache, so its environment is authoritative
  # even when the operator's shell says nothing.
  trust_anchor_case darwin-trust-anchor-plist
  plist="$BOOTSTRAP_PROFILE_TARGET_ROOT/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
  mkdir -p "$(dirname "$plist")"
  printf '<dict><key>NIX_SSL_CERT_FILE</key><string>%s</string></dict>\n' "$anchor" > "$plist"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-plist.out"
  grep -F "$anchor (named by $plist)" "$TMPDIR/anchor-plist.out" >/dev/null
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  test "$(readlink "$anchor")" = "$bundle"

  # Three ways to be none of bootstrap's business: an anchor that is a usable
  # bundle, one kept outside /etc, and a dangling one this toolchain does not
  # own.
  trust_anchor_case darwin-trust-anchor-untouched
  printf -- '-----BEGIN CERTIFICATE-----\noperator anchors\n' > "$anchor"
  export NIX_SSL_CERT_FILE="$anchor"
  export SSL_CERT_FILE="$TMPDIR/elsewhere/ca.pem"
  mkdir -p "$etc/ssl/other"
  ln -s /opt/elsewhere/foreign.crt "$etc/ssl/other/foreign.crt"
  mkdir -p "$etc/nix"
  printf 'ssl-cert-file = %s\n' "$etc/ssl/other/foreign.crt" > "$etc/nix/nix.conf"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-untouched.out"
  grep -Fq 'Restore the TLS trust anchor' "$TMPDIR/anchor-untouched.out" && exit 1
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  grep -F 'operator anchors' "$anchor" >/dev/null
  test ! -L "$anchor"
  test -L "$etc/ssl/other/foreign.crt"
  test ! -e "$TMPDIR/elsewhere/ca.pem"
  unset NIX_SSL_CERT_FILE SSL_CERT_FILE

  # Nix does not look for this file, it loads it. A present but unparseable
  # bundle fails every download with the same error naming the same path as a
  # missing one - and nothing needs to name the path for Nix to read it, so
  # this state has no namer at all. Reported BOOT-E399 on the real machine
  # because detection asked whether the path resolved, not whether it worked.
  trust_anchor_case darwin-trust-anchor-unusable
  : > "$anchor"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-unusable.out"
  grep -F "$anchor (named by the path Nix probes by default)" \
    "$TMPDIR/anchor-unusable.out" >/dev/null
  test -f "$anchor"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  test "$(readlink "$anchor")" = "$bundle"
  # The unusable original is archived, and the undo journal puts it back.
  undo="$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log"
  grep -F "archived unusable trust anchor $anchor" "$undo" >/dev/null
  test -n "$(find "$XDG_STATE_HOME/atyrode/bootstrap/repairs" -name 'ca-bundle.*' -print -quit)"

  # A launchd plist is routinely stored as binary, where the path inside is
  # not greppable text and only plutil can read it out.
  trust_anchor_case darwin-trust-anchor-binary-plist
  plist="$BOOTSTRAP_PROFILE_TARGET_ROOT/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
  mkdir -p "$(dirname "$plist")"
  { printf 'bplist00\n'
    printf '<dict><key>NIX_SSL_CERT_FILE</key><string>%s</string></dict>\n' "$anchor" |
      ${pkgs.coreutils}/bin/base64
  } > "$plist"
  # The path is genuinely unreadable as text; only decoding finds it.
  grep -Fq "$anchor" "$plist" && exit 1
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-bplist.out"
  grep -F "$anchor (named by $plist)" "$TMPDIR/anchor-bplist.out" >/dev/null
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  test "$(readlink "$anchor")" = "$bundle"

  # A named anchor that is merely absent is classified, not shrugged at: this
  # exact state reported BOOT-E399 with a remedy that could never fire.
  trust_anchor_case darwin-trust-anchor-code
  export NIX_SSL_CERT_FILE="$anchor"
  expect_failure "$repo/bootstrap/install.sh" verify --repo "$repo" --config "$host"
  grep -F '[BOOT-E301]' "$TMPDIR/expected-failure.err" >/dev/null
  grep -F "named by NIX_SSL_CERT_FILE" "$TMPDIR/expected-failure.err" >/dev/null
  grep -F 'it restores that file' "$TMPDIR/expected-failure.err" >/dev/null
  unset NIX_SSL_CERT_FILE
''
