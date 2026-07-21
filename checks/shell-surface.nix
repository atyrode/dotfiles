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
assert lib.assertMsg (
  !baseline.programs.fzf.enableZshIntegration
) "fzf's unguarded zsh hook must stay disabled; home/zsh.nix sources it behind a TTY guard (#255)";
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


    osc_dir="$TMPDIR/osc 7#?"
    mkdir "$osc_dir"
    OSC_DIR="$osc_dir" zsh -dfc \
      'source ${../home/shell/cwd.zsh}; cd -- "$OSC_DIR"; HOST=rio-test; _atyrode_report_cwd' \
      > "$TMPDIR/osc-actual"
    printf '\033]7;file://rio-test%s\033\\' \
      "''${osc_dir//%/%25}" | sed 's/ /%20/g; s/#/%23/g; s/?/%3F/g' \
      > "$TMPDIR/osc-expected"
    cmp "$TMPDIR/osc-expected" "$TMPDIR/osc-actual"


    mkdir "$out"
  ''
