{ atyrode, pkgs }:

# `atyrode tunnel` decides which reviewed fleet keys may reach the machine it
# runs on, and it owns the rendered ~/.ssh/authorized_keys. Every assertion here
# is about a way that ownership could lock the operator out of a host reachable
# only over SSH, or hand out access that outlives the reason for it:
#
#   * the first mutation adopts the access the machine already had;
#   * a timed grant renders OpenSSH's own expiry-time, so sshd enforces the
#     deadline with nothing left running;
#   * the primary key is refused before the vault is even consulted;
#   * a lapsed grant stops being rendered and is pruned;
#   * an unregistered key blocks the render instead of being silently dropped;
#   * grant/revoke require a vault session and `list` requires none.
let
  fixtures = import ../lib/atyrode-fixtures.nix { inherit pkgs; };
in
pkgs.runCommand "check-atyrode-tunnel"
  {
    nativeBuildInputs = [
      atyrode
      pkgs.jq
      pkgs.openssh
    ];
  }
  ''
    ${fixtures.base}
    ${fixtures.identity}
    export HOME="$TMPDIR/tunnel-home"
    export XDG_STATE_HOME="$HOME/.local/state"
    export XDG_CONFIG_HOME="$HOME/.config"
    state="$XDG_STATE_HOME/atyrode/tunnel/grants.json"
    keys="$HOME/.ssh/authorized_keys"
    backup="$HOME/.ssh/authorized_keys.pre-atyrode"

    # A vault that reports its state from $BW_STATE and records every call, so
    # the gate can be observed rather than assumed. It never returns an item:
    # the unlock is an intentionality gate, not a secret lookup.
    mkdir -p "$TMPDIR/bin"
    cat > "$TMPDIR/bin/bw" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    printf '%s\n' "$*" >> "$BW_LOG"
    case "$1" in
      status) printf '{"status":"%s"}\n' "''${BW_STATE:-unlocked}" ;;
      unlock) printf 'fixture-session\n' ;;
      lock | sync) ;;
      *) exit 64 ;;
    esac
    EOF
    chmod +x "$TMPDIR/bin/bw"
    export ATYRODE_BW="$TMPDIR/bin/bw"
    export BW_LOG="$TMPDIR/bw.log"
    export _ATYRODE_TEST_TTY=1

    # The three keys the seeded registry names, in the shape a machine that has
    # never run atyrode has them: one line pasted twice, once split across two
    # lines that sshd discards as malformed. Rendering from the registry is what
    # stops that from silently costing a machine its access.
    primary_key="$(awk '$2 == "primary" { print $4 }' ${../../modules/home/ssh/fleet-keys})"
    macbook_key="$(awk '$1 == "alex-macbook-air" { print $4 }' ${../../modules/home/ssh/fleet-keys})"
    other_key="$(awk '$1 == "unidentified-1" { print $4 }' ${../../modules/home/ssh/fleet-keys})"
    test -n "$primary_key" && test -n "$macbook_key" && test -n "$other_key"

    seed_home() {
      rm -rf "$HOME"
      mkdir -p "$HOME/.ssh" "$XDG_CONFIG_HOME/atyrode"
      chmod 700 "$HOME/.ssh"
      printf '%s\n' '{"id":"platform-01"}' > "$XDG_CONFIG_HOME/atyrode/host.json"
      {
        printf 'ssh-ed25519 %s alext@Alex-Windows\n' "$primary_key"
        printf 'ssh-ed25519 %s alexMacBook-Air-de-Alex.local\n' "$macbook_key"
        printf 'ssh-ed25519                                     \n'
        printf ' %s\n' "$other_key"
        printf 'ssh-ed25519 %s\n' "$other_key"
      } > "$keys"
      chmod 600 "$keys"
      : > "$BW_LOG"
    }

    granted_names() {
      atyrode tunnel list --json | jq -r '[.machines[] | select(.granted) | .name] | sort | join(",")'
    }

    # --- the registry is a reviewed contract --------------------------------
    seed_home
    atyrode tunnel list --json | jq -e '
      .schemaVersion == 1
      and (.machines | length) == 3
      and ([.machines[] | select(.primary)] | length) == 1
      and (.machines[] | select(.primary) | .name) == "alex-windows"
      and all(.machines[]; .fingerprint | startswith("SHA256:"))
      and all(.machines[]; has("state") and has("granted") and has("expiresAt")
                           and has("remainingSeconds"))
      and (.registryPath | length) > 0
    ' >/dev/null || { echo 'tunnel list does not report the reviewed registry' >&2; exit 1; }
    # A read is a read: no vault, no state, no rendered file.
    test ! -s "$BW_LOG"
    test ! -e "$state"
    grep -qF 'alext@Alex-Windows' "$keys"

    # Keys already accepted by sshd are reported as such before adoption, so a
    # read never understates the access a machine currently grants.
    atyrode tunnel list --json | jq -e '
      all(.machines[] | select(.primary | not); .state == "unmanaged" and .granted)
    ' >/dev/null || { echo 'pre-adoption keys are misreported' >&2; exit 1; }

    # --- the first mutation adopts the machine's existing access -------------
    atyrode tunnel grant alex-macbook-air --for 8h 2>"$TMPDIR/first.err"
    grep -q 'adopted the existing grant for unidentified-1' "$TMPDIR/first.err"
    test "$(granted_names)" = alex-macbook-air,alex-windows,unidentified-1
    diff <(printf 'alex-macbook-air\nunidentified-1\n') \
      <(jq -r '.grants[].name' "$state")

    # The pre-management file is kept once, verbatim, and never overwritten by a
    # later render.
    test "$(stat -c %a "$backup")" = 600
    grep -qF 'alexMacBook-Air-de-Alex.local' "$backup"
    test "$(grep -c . "$backup")" = 5
    printf 'sentinel\n' >> "$backup"
    atyrode tunnel grant alex-macbook-air --for 1h >/dev/null 2>&1
    grep -q sentinel "$backup"

    # --- the render is atyrode's, whole, atomic, and 0600 -------------------
    test "$(stat -c %a "$keys")" = 600
    test "$(stat -c %a "$state")" = 600
    test -z "$(find "$HOME/.ssh" -name '.authorized_keys.*')"
    grep -q '^# Managed by atyrode tunnel' "$keys"
    # The malformed pair the operator's file carried is gone, and every rendered
    # line is one sshd accepts.
    test "$(grep -c '^ssh-ed25519\|^expiry-time' "$keys")" = 3
    ssh-keygen -l -f "$keys" >/dev/null
    test "$(ssh-keygen -l -f "$keys" | wc -l)" = 3
    # The primary key is rendered first and unconditionally, with no expiry.
    test "$(grep -v '^#' "$keys" | head -1)" = "ssh-ed25519 $primary_key alex-windows"

    # --- expiry is OpenSSH's own option, in the time zone sshd reads --------
    seed_home
    atyrode tunnel grant alex-macbook-air --for 24h >/dev/null 2>&1
    option="$(awk '/alex-macbook-air$/ { print $1 }' "$keys")"
    deadline="$(jq -r '.grants[] | select(.name == "alex-macbook-air") | .expiresAt' "$state")"
    test "$option" = "expiry-time=\"$(date -d "@$deadline" +%Y%m%d%H%M)\""
    test "$(awk '/alex-macbook-air$/ { print $1 }' "$keys" | tr -dc 0-9 | wc -c)" = 12
    atyrode tunnel list --json | jq -e '
      (.machines[] | select(.name == "alex-macbook-air"))
      | .state == "timed" and .remainingSeconds > 86000 and .remainingSeconds <= 86400
    ' >/dev/null || { echo 'a timed grant does not report its remaining time' >&2; exit 1; }

    # `until-revoked` is the only unbounded grant, and it has to be named.
    atyrode tunnel grant alex-macbook-air --for until-revoked >/dev/null 2>&1
    grep -q "^ssh-ed25519 $macbook_key alex-macbook-air$" "$keys"
    atyrode tunnel list --json | jq -e '
      (.machines[] | select(.name == "alex-macbook-air") | .state == "granted" and .expiresAt == null)
    ' >/dev/null
    if atyrode tunnel grant alex-macbook-air --for 3h 2>"$TMPDIR/duration.err"; then
      echo 'an unlisted grant duration was accepted' >&2
      exit 1
    fi
    grep -q 'unknown grant duration' "$TMPDIR/duration.err"

    # --- a lapsed grant is refused by sshd, reported, then pruned -----------
    jq --argjson past "$(( $(date -u +%s) - 60 ))" '
      .grants = [{name: "alex-macbook-air", grantedAt: 0, expiresAt: $past},
                 {name: "unidentified-1", grantedAt: 0, expiresAt: null}]
    ' "$state" > "$state.next"
    mv "$state.next" "$state"
    atyrode tunnel list --json | jq -e '
      (.machines[] | select(.name == "alex-macbook-air") | .state == "expired" and .granted == false)
    ' >/dev/null || { echo 'a lapsed grant does not report as expired' >&2; exit 1; }
    atyrode tunnel grant unidentified-1 --for 1h >/dev/null 2>&1
    diff <(printf 'unidentified-1\n') <(jq -r '.grants[].name' "$state")
    if grep -q alex-macbook-air "$keys"; then
      echo 'an expired grant is still rendered' >&2
      exit 1
    fi

    # --- revocation removes the key ------------------------------------------
    seed_home
    atyrode tunnel grant alex-macbook-air --for 8h >/dev/null 2>&1
    atyrode tunnel revoke alex-macbook-air >/dev/null 2>&1
    if grep -q alex-macbook-air "$keys"; then
      echo 'a revoked key is still rendered' >&2
      exit 1
    fi
    test "$(granted_names)" = alex-windows,unidentified-1
    atyrode tunnel list --json | jq -e '
      (.machines[] | select(.name == "alex-macbook-air") | .state == "revoked" and .granted == false)
    ' >/dev/null

    # --- the primary key is never revocable, and refused before the vault ---
    : > "$BW_LOG"
    if atyrode tunnel revoke alex-windows 2>"$TMPDIR/primary.err"; then
      echo 'the primary fleet key was revocable' >&2
      exit 1
    fi
    grep -q 'primary fleet key and can never be revoked' "$TMPDIR/primary.err"
    test ! -s "$BW_LOG"
    grep -q "^ssh-ed25519 $primary_key alex-windows$" "$keys"
    # Granting it is a no-op statement of fact, not a state change.
    atyrode tunnel grant alex-windows 2>"$TMPDIR/primary-grant.err" >/dev/null
    grep -q 'always granted' "$TMPDIR/primary-grant.err"
    jq -e '[.grants[].name] | index("alex-windows") == null' "$state" >/dev/null

    # --- the vault gate ------------------------------------------------------
    : > "$BW_LOG"
    BW_STATE=locked atyrode tunnel grant alex-macbook-air --for 1h >/dev/null 2>&1
    grep -qx 'unlock --raw' "$BW_LOG"
    grep -qx lock "$BW_LOG"
    : > "$BW_LOG"
    atyrode tunnel list >/dev/null
    test ! -s "$BW_LOG"
    : > "$BW_LOG"
    if BW_STATE=unauthenticated atyrode tunnel revoke alex-macbook-air 2>"$TMPDIR/logged-out.err"; then
      echo 'a mutation succeeded against a logged-out vault' >&2
      exit 1
    fi
    grep -q 'atyrode vault login' "$TMPDIR/logged-out.err"

    # --- an unregistered key blocks the render ------------------------------
    seed_home
    stranger=AAAAC3NzaC1lZDI1NTE5AAAAIL2vf1KaMPMg2fZEcQvfnzhkOSTQlXklzs4kUJTvvKrq
    printf 'ssh-ed25519 %s stranger\n' "$stranger" >> "$keys"
    if atyrode tunnel grant alex-macbook-air --for 1h 2>"$TMPDIR/stranger.err"; then
      echo 'atyrode rendered over an unregistered key' >&2
      exit 1
    fi
    grep -q 'unregistered key ending' "$TMPDIR/stranger.err"
    grep -q "$stranger" "$keys"

    # --- usage and refusals --------------------------------------------------
    atyrode --help | grep -qF 'atyrode tunnel grant NAME [--for 1h|8h|24h|7d|until-revoked]'
    if atyrode tunnel revoke nonesuch 2>"$TMPDIR/unknown.err"; then
      echo 'an unregistered machine name was accepted' >&2
      exit 1
    fi
    grep -q 'is not in modules/home/ssh/fleet-keys' "$TMPDIR/unknown.err"
    if atyrode tunnel sideways >/dev/null 2>&1; then
      echo 'tunnel accepted an unknown verb' >&2
      exit 1
    fi
    if atyrode tunnel revoke alex-macbook-air --for 1h >/dev/null 2>&1; then
      echo 'revoke accepted a duration' >&2
      exit 1
    fi

    mkdir "$out"
  ''
