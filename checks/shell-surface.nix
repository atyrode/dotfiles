{
  hostConfigs,
  lib,
  pkgs,
}:

let
  baseline = hostConfigs.alex-x86_64-linux.config;
in
assert lib.assertMsg baseline.programs.zsh.enableCompletion
  "the baseline shell must keep completion enabled";
assert lib.assertMsg baseline.programs.fzf.enable "fzf must be configured through Home Manager";
assert lib.assertMsg baseline.programs.zoxide.enable
  "zoxide must be configured through Home Manager";
assert lib.assertMsg baseline.programs.direnv.nix-direnv.enable
  "nix-direnv must provide cached project environments";
pkgs.runCommand "check-shell-surface"
  {
    nativeBuildInputs = [ pkgs.zsh ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME/.config/zsh" "$TMPDIR/bin"

    cat > "$HOME/.config/zsh/local.zsh" <<'EOF'
    : > "$HOME/local-loaded"
    EOF
    cat > "$TMPDIR/bin/fastfetch" <<'EOF'
    #!${pkgs.runtimeShell}
    : > "$HOME/fastfetch-ran"
    EOF
    chmod +x "$TMPDIR/bin/fastfetch"
    export PATH="$TMPDIR/bin:$PATH"

    zsh -dfc 'source ${../home/shell/startup.zsh}; [[ ! -e "$HOME/local-loaded" ]]'
    zsh -dfi -c 'source ${../home/shell/startup.zsh}; [[ -e "$HOME/local-loaded" ]]' </dev/null
    test ! -e "$HOME/fastfetch-ran"

    COLORTERM= TERM=xterm-ghostty zsh -dfc \
      'source ${../home/shell/colorterm.zsh}; [[ "$COLORTERM" == truecolor ]]'
    COLORTERM=16color TERM=xterm-ghostty zsh -dfc \
      'source ${../home/shell/colorterm.zsh}; [[ "$COLORTERM" == 16color ]]'
    COLORTERM= TERM=vt100 zsh -dfc \
      'source ${../home/shell/colorterm.zsh}; [[ -z "$COLORTERM" ]]'

    zsh -dfc '
      source ${../home/shell/nix.zsh}
      whence -w zconf >/dev/null
      ! whence -w atmux >/dev/null
      ! whence -w codex-login-main >/dev/null
      ! alias ls >/dev/null 2>&1
      ! alias htop >/dev/null 2>&1
      ! alias cl >/dev/null 2>&1
    '

    mkdir "$out"
  ''
