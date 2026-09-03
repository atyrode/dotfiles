{ pkgs }:

let
  inherit (import ./harness.nix { inherit pkgs; }) mkScenario;
in
mkScenario "darwin-etc" ''
  # A dead nix-darwin generation leaves /etc links resolving into a store
  # that no longer exists, at every depth: the CA bundle Nix reads for its
  # trust anchors is nested three levels down. They are removed, links this
  # toolchain does not own are left alone at every depth too, and the undo
  # journal can put every one of them back.
  darwin_fixture darwin-etc-link-repair
  export PATH="$fresh_tools:$base_path"
  ln -s /nix/store/0000000000000000000000000000000-etc "$etc/static"
  ln -s /etc/static/bashrc "$etc/bashrc"
  ln -s /Volumes/MountsLater/thing "$etc/unrelated"
  printf 'real\n' > "$etc/zshrc"
  mkdir -p "$etc/ssl/certs"
  ln -s /etc/static/ssl/certs/ca-certificates.crt "$etc/ssl/certs/ca-certificates.crt"
  ln -s /opt/elsewhere/foreign.crt "$etc/ssl/certs/foreign.crt"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/etc-link-plan.out"
  grep -F "$etc/static" "$TMPDIR/etc-link-plan.out" >/dev/null
  grep -F "$etc/bashrc" "$TMPDIR/etc-link-plan.out" >/dev/null
  grep -F "$etc/ssl/certs/ca-certificates.crt" "$TMPDIR/etc-link-plan.out" >/dev/null
  grep -Fq "$etc/unrelated" "$TMPDIR/etc-link-plan.out" && exit 1
  grep -Fq "$etc/ssl/certs/foreign.crt" "$TMPDIR/etc-link-plan.out" && exit 1
  # plan is read-only: every link is still exactly as it was.
  test -L "$etc/static"
  test -L "$etc/bashrc"
  test -L "$etc/ssl/certs/ca-certificates.crt"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  test ! -e "$etc/static" && test ! -L "$etc/static"
  test ! -e "$etc/bashrc" && test ! -L "$etc/bashrc"
  test ! -L "$etc/ssl/certs/ca-certificates.crt"
  # A dangling link bootstrap does not own survives untouched at any depth,
  # and so does a real file.
  test -L "$etc/unrelated"
  test -L "$etc/ssl/certs/foreign.crt"
  test -f "$etc/zshrc"
  undo="$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log"
  grep -F "ln -s '/etc/static/bashrc' '$etc/bashrc'" "$undo" >/dev/null
  grep -F "removed dangling $etc/static" "$undo" >/dev/null
  grep -F "ln -s '/etc/static/ssl/certs/ca-certificates.crt' '$etc/ssl/certs/ca-certificates.crt'" \
    "$undo" >/dev/null

  # The /etc sweep repairs Nix itself, not the installer, so it must run
  # when Nix is already installed. That is the machine that most needs it:
  # a dangling CA bundle stops an installed Nix from verifying TLS, and
  # gating the sweep on Nix being absent leaves it unable to repair itself.
  darwin_fixture darwin-etc-link-repair-with-nix
  export PATH="$managed_tools:$base_path"
  mkdir -p "$etc/ssl/certs"
  ln -s /nix/store/0000000000000000000000000000000-etc/ca.crt \
    "$etc/ssl/certs/ca-certificates.crt"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/etc-nix-plan.out"
  grep -F "$etc/ssl/certs/ca-certificates.crt" "$TMPDIR/etc-nix-plan.out" >/dev/null
  # The installer is not planned: Nix is present and stays present.
  grep -F 'Reuse the installed Nix command' "$TMPDIR/etc-nix-plan.out" >/dev/null
  test -L "$etc/ssl/certs/ca-certificates.crt"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  test ! -L "$etc/ssl/certs/ca-certificates.crt"
  test ! -e "$FAKE_INSTALL_EXECUTED"
  # No CA bundle in the profile, so removal is the whole repair here: there
  # is nothing to restore the path from and nothing is invented.
  test ! -e "$etc/ssl/certs/ca-certificates.crt"

  # The upstream installer appends its block to shell rc files nix-darwin
  # manages, and nix-darwin aborts activation rather than overwrite content
  # it does not recognise. Moving them aside is what nix-darwin's own etc
  # activation does to a conflicting file, so the end state is the one a
  # successful activation produces - reached before the abort, not after it.
  darwin_fixture darwin-etc-profile-conflict
  export PATH="$managed_tools:$base_path"
  # The block the upstream installer appends, marker line and all.
  nix_block='# Nix\nif [ -e "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then\n  . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"\nfi\n# End Nix\n'
  printf "stock zshrc\n$nix_block" > "$etc/zshrc"
  printf "stock bashrc\n$nix_block" > "$etc/bashrc"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/etc-profile-plan.out"
  grep -F "$etc/zshrc" "$TMPDIR/etc-profile-plan.out" >/dev/null
  grep -F 'before-nix-darwin' "$TMPDIR/etc-profile-plan.out" >/dev/null
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  test ! -e "$etc/zshrc"
  test ! -e "$etc/bashrc"
  # Moved, not rewritten: the content is the file the installer left.
  grep -F 'stock zshrc' "$etc/zshrc.before-nix-darwin" >/dev/null
  grep -F '# End Nix' "$etc/zshrc.before-nix-darwin" >/dev/null
  undo="$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log"
  grep -F "mv '$etc/zshrc.before-nix-darwin' '$etc/zshrc'" "$undo" >/dev/null

  # A path nix-darwin already owns resolves into /etc/static and is left
  # alone, and a file this toolchain did not write is not bootstrap's to
  # move however much it looks like a shell rc file.
  darwin_fixture darwin-etc-profile-untouched
  export PATH="$managed_tools:$base_path"
  mkdir -p "$etc/static"
  printf 'managed\n# End Nix\n' > "$etc/static/zshrc"
  ln -s "$etc/static/zshrc" "$etc/zshrc"
  printf 'hand written, no marker\n' > "$etc/bashrc"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/etc-untouched-plan.out"
  grep -Fq 'before-nix-darwin' "$TMPDIR/etc-untouched-plan.out" && exit 1
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  test -L "$etc/zshrc"
  test ! -e "$etc/zshrc.before-nix-darwin"
  test "$(cat "$etc/bashrc")" = 'hand written, no marker'
  test ! -e "$etc/bashrc.before-nix-darwin"

  # A backup already at that name is the one an earlier nix-darwin generation
  # made, and it holds the pre-nix-darwin original. Writing over it would
  # discard the older copy to keep the newer one, so the installer's file is
  # archived instead and the original stays where it is.
  darwin_fixture darwin-etc-profile-backup-collision
  export PATH="$managed_tools:$base_path"
  printf 'the real original\n' > "$etc/zshrc.before-nix-darwin"
  printf 'installer wrote this\n# End Nix\n' > "$etc/zshrc"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  test ! -e "$etc/zshrc"
  test "$(cat "$etc/zshrc.before-nix-darwin")" = 'the real original'
  archive="$(find "$XDG_STATE_HOME/atyrode/bootstrap/repairs" -name 'zshrc.*' -print -quit)"
  grep -F 'installer wrote this' "$archive" >/dev/null
  grep -F "cp '$archive' '$etc/zshrc'" \
    "$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log" >/dev/null

  # A file bootstrap did not write is not bootstrap's to move, so activation
  # still refuses - and the refusal names the file and the exact command
  # that clears it, rather than costing a round trip as an unclassified
  # code. The transcript arrives indented under nh's error, which is the
  # shape the parser has to survive.
  darwin_fixture darwin-etc-conflict-not-ours
  export PATH="$managed_tools:$base_path"
  printf 'a file the operator wrote\n' > "$etc/zshrc"
  FAKE_ETC_CONFLICTS="$etc/zshrc" \
    expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  grep -F '[BOOT-E303]' "$TMPDIR/expected-failure.err" >/dev/null
  grep -F "sudo mv $etc/zshrc $etc/zshrc.before-nix-darwin" \
    "$TMPDIR/expected-failure.err" >/dev/null
  # Refusing is not repairing: the file it named is still exactly there.
  test "$(cat "$etc/zshrc")" = 'a file the operator wrote'

  # A path named in a transcript is a claim; a path that is gone is not a
  # state, and reporting it as one sends the operator after a file that is
  # not there.
  darwin_fixture darwin-etc-conflict-absent
  export PATH="$managed_tools:$base_path"
  FAKE_ETC_CONFLICTS="$etc/zshrc" \
    expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  grep -F '[BOOT-E399]' "$TMPDIR/expected-failure.err" >/dev/null
''
