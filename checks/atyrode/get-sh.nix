{ pkgs }:

let
  # The picker filters presets by the build platform, so the refusal
  # message names a different host per system.
  expectedPickerHost =
    {
      "aarch64-darwin" = "macbook";
      "aarch64-linux" = "headless-aarch64-linux";
      "x86_64-linux" = "platform-01";
    }
    .${pkgs.stdenv.hostPlatform.system};
in
pkgs.runCommand "check-get-entrypoint" { } ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME" "$TMPDIR/bin"
  export INSTALL_ARGS_FILE="$TMPDIR/install-args"
  export INSTALL_STDIN_FILE="$TMPDIR/install-stdin"

  cat > "$TMPDIR/install-stub" <<'EOF'
  #!${pkgs.runtimeShell}
  printf '%s\n' "$*" > "$INSTALL_ARGS_FILE"
  cat > "$INSTALL_STDIN_FILE"
  EOF
  chmod +x "$TMPDIR/install-stub"

  cat > "$TMPDIR/bin/git" <<'EOF'
  #!${pkgs.runtimeShell}
  case "$1" in
    clone)
      mkdir -p "$3/bootstrap" "$3/fleet"
      cp "$TMPDIR/install-stub" "$3/bootstrap/install.sh"
      cp "$TMPDIR/hosts.tsv" "$3/fleet/hosts.tsv"
      printf '%s\n' "$2" > "$3/origin"
      ;;
    -C)
      [[ "$3 $4" == 'config --get' ]] || exit 1
      cat "$2/origin"
      ;;
    *) exit 1 ;;
  esac
  EOF
  chmod +x "$TMPDIR/bin/git"
  cp ${../../fleet/hosts.tsv} "$TMPDIR/hosts.tsv"

  # git is absent from this build environment until the stub joins PATH.
  if bash ${../../get.sh} platform-01 >/dev/null 2>"$TMPDIR/git-err"; then
    echo 'missing git unexpectedly succeeded' >&2
    exit 1
  fi
  grep -F 'git is required' "$TMPDIR/git-err" >/dev/null
  export PATH="$TMPDIR/bin:$PATH"

  # A foreign directory at the target must never be reused or clobbered.
  mkdir -p "$HOME/nix-dotfiles"
  if bash ${../../get.sh} platform-01 --yes >/dev/null 2>"$TMPDIR/foreign-err"; then
    echo 'foreign directory unexpectedly reused' >&2
    exit 1
  fi
  grep -F 'not this repository' "$TMPDIR/foreign-err" >/dev/null
  rmdir "$HOME/nix-dotfiles"

  # Only registered hosts reach install.sh; unknown names fail with the
  # available registry choices and cause no mutation.
  if bash ${../../get.sh} not-a-registered-host --yes >/dev/null 2>"$TMPDIR/host-err"; then
    echo 'unregistered host unexpectedly succeeded' >&2
    exit 1
  fi
  grep -F 'unknown configuration' "$TMPDIR/host-err" >/dev/null
  grep -F 'choose one of:' "$TMPDIR/host-err" >/dev/null
  grep -F 'platform-01' "$TMPDIR/host-err" >/dev/null
  test ! -e "$INSTALL_ARGS_FILE"

  # Streamed like curl | bash: stdin is the script, no terminal exists, and
  # --yes hands off to the cloned install.sh with stdin detached. A fresh
  # clone already sits at origin/main, so it needs no source update.
  rm -rf "$HOME/nix-dotfiles"
  bash -s -- platform-01 --yes < ${../../get.sh} >/dev/null 2>"$TMPDIR/clone-err"
  test "$(cat "$INSTALL_ARGS_FILE")" = 'apply --config platform-01 --yes'
  test ! -s "$INSTALL_STDIN_FILE"
  # The two things a piped-in script does before an inspectable checkout takes
  # over: write the clone, and hand control to it. git clone names where it
  # writes but never where it reads from.
  grep -F '$ git clone https://github.com/atyrode/dotfiles.git' "$TMPDIR/clone-err" >/dev/null
  grep -F "$ $HOME/nix-dotfiles/bootstrap/install.sh apply --config platform-01 --yes" "$TMPDIR/clone-err" >/dev/null

  # A reused checkout is fast-forwarded to origin/main instead of deciding, at
  # whatever revision it happens to hold, what the fetched script means.
  bash -s -- development-x86_64-linux --yes < ${../../get.sh} >/dev/null 2>"$TMPDIR/reuse-err"
  test "$(cat "$INSTALL_ARGS_FILE")" = 'apply --config development-x86_64-linux --update --yes'
  test ! -s "$INSTALL_STDIN_FILE"
  grep -F 'it will be updated to origin/main before activation' "$TMPDIR/reuse-err" >/dev/null
  grep -F 'DOTFILES_DIR' "$TMPDIR/reuse-err" >/dev/null

  # An explicit source acknowledgement is a reviewed operator decision about
  # which revision to activate and is never overridden.
  for acknowledgement in --update --allow-dirty --allow-non-main; do
    bash -s -- platform-01 --yes "$acknowledgement" < ${../../get.sh} >/dev/null
    test "$(cat "$INSTALL_ARGS_FILE")" = "apply --config platform-01 --yes $acknowledgement"
  done

  # The existing correct-origin clone is reused, and without a terminal the
  # confirmation cannot be assumed: no --yes means no install.sh run.
  rm "$INSTALL_ARGS_FILE"
  if bash ${../../get.sh} platform-01 >/dev/null 2>"$TMPDIR/tty-err"; then
    echo 'missing terminal unexpectedly succeeded' >&2
    exit 1
  fi
  grep -F -- '--yes' "$TMPDIR/tty-err" >/dev/null
  test ! -e "$INSTALL_ARGS_FILE"

  # Without a host and without a terminal, the picker refuses and names the
  # presets registered for this system instead of guessing.
  if bash ${../../get.sh} </dev/null >/dev/null 2>"$TMPDIR/picker-err"; then
    echo 'host-less run without a terminal unexpectedly succeeded' >&2
    exit 1
  fi
  grep -F 'pass one of:' "$TMPDIR/picker-err" >/dev/null
  grep -F '${expectedPickerHost}' "$TMPDIR/picker-err" >/dev/null
  test ! -e "$INSTALL_ARGS_FILE"

  # DOTFILES_DIR relocates the clone and forwards extra install arguments.
  DOTFILES_DIR="$TMPDIR/elsewhere" bash ${../../get.sh} macbook --yes --update >/dev/null
  test -x "$TMPDIR/elsewhere/bootstrap/install.sh"
  test "$(cat "$INSTALL_ARGS_FILE")" = 'apply --config macbook --yes --update'

  mkdir "$out"
''
