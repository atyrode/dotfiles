{ pkgs }:

let
  # The picker filters presets by the build platform, so the refusal
  # message names a different host per system.
  expectedPickerHost =
    {
      "aarch64-darwin" = "alex-aarch64-darwin";
      "aarch64-linux" = "alex-aarch64-linux";
      "x86_64-linux" = "alex-x86_64-linux";
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
      mkdir -p "$3/inventory"
      cp "$TMPDIR/install-stub" "$3/install.sh"
      cp "$TMPDIR/hosts.tsv" "$3/inventory/hosts.tsv"
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
  cp ${../inventory/hosts.tsv} "$TMPDIR/hosts.tsv"

  # git is absent from this build environment until the stub joins PATH.
  if bash ${../get.sh} alex-x86_64-linux >/dev/null 2>"$TMPDIR/git-err"; then
    echo 'missing git unexpectedly succeeded' >&2
    exit 1
  fi
  grep -F 'git is required' "$TMPDIR/git-err" >/dev/null
  export PATH="$TMPDIR/bin:$PATH"

  # A foreign directory at the target must never be reused or clobbered.
  mkdir -p "$HOME/nix-dotfiles"
  if bash ${../get.sh} alex-x86_64-linux --yes >/dev/null 2>"$TMPDIR/foreign-err"; then
    echo 'foreign directory unexpectedly reused' >&2
    exit 1
  fi
  grep -F 'not this repository' "$TMPDIR/foreign-err" >/dev/null
  rmdir "$HOME/nix-dotfiles"

  # Streamed like curl | bash: stdin is the script, no terminal exists, and
  # --yes hands off to the cloned install.sh with stdin detached.
  bash -s -- alex-x86_64-linux --yes < ${../get.sh} >/dev/null
  test "$(cat "$INSTALL_ARGS_FILE")" = 'apply --config alex-x86_64-linux --yes'
  test ! -s "$INSTALL_STDIN_FILE"

  # The existing correct-origin clone is reused, and without a terminal the
  # confirmation cannot be assumed: no --yes means no install.sh run.
  rm "$INSTALL_ARGS_FILE"
  if bash ${../get.sh} alex-x86_64-linux >/dev/null 2>"$TMPDIR/tty-err"; then
    echo 'missing terminal unexpectedly succeeded' >&2
    exit 1
  fi
  grep -F -- '--yes' "$TMPDIR/tty-err" >/dev/null
  test ! -e "$INSTALL_ARGS_FILE"

  # Without a host and without a terminal, the picker refuses and names the
  # presets registered for this system instead of guessing.
  if bash ${../get.sh} </dev/null >/dev/null 2>"$TMPDIR/picker-err"; then
    echo 'host-less run without a terminal unexpectedly succeeded' >&2
    exit 1
  fi
  grep -F 'pass one of:' "$TMPDIR/picker-err" >/dev/null
  grep -F '${expectedPickerHost}' "$TMPDIR/picker-err" >/dev/null
  test ! -e "$INSTALL_ARGS_FILE"

  # DOTFILES_DIR relocates the clone and forwards extra install arguments.
  DOTFILES_DIR="$TMPDIR/elsewhere" bash ${../get.sh} alex-aarch64-darwin --yes --update >/dev/null
  test -x "$TMPDIR/elsewhere/install.sh"
  test "$(cat "$INSTALL_ARGS_FILE")" = 'apply --config alex-aarch64-darwin --yes --update'

  mkdir "$out"
''
