{ pkgs }:

# Exercise the terminal-viewing stack from the visual-verification skill.
pkgs.runCommand "check-agent-tools-terminal-viewing"
  {
    nativeBuildInputs = [
      pkgs.charm-freeze
      pkgs.tmux
    ];
  }
  ''
    tmux -V

    # The exact font files the profile installs and freeze is pointed at.
    test -f ${pkgs.jetbrains-mono}/share/fonts/truetype/JetBrainsMono-Regular.ttf
    test -f ${pkgs.nerd-fonts.symbols-only}/share/fonts/truetype/NerdFonts/Symbols/SymbolsNerdFontMono-Regular.ttf

    # Render a truecolor frame carrying a Nerd Font PUA glyph end to end,
    # with the fonts exposed the way a user profile exposes them.
    export HOME="$TMPDIR"
    export XDG_DATA_HOME="$TMPDIR/share"
    mkdir -p "$XDG_DATA_HOME/fonts"
    ln -s ${pkgs.jetbrains-mono}/share/fonts/truetype/*.ttf "$XDG_DATA_HOME/fonts/"
    ln -s ${pkgs.nerd-fonts.symbols-only}/share/fonts/truetype/NerdFonts/Symbols/*.ttf "$XDG_DATA_HOME/fonts/"
    printf '\x1b[38;2;255;95;175mpill \xee\x82\xb6 glyph\x1b[0m\n' > frame.ansi

    # freeze is a cgo Go binary whose SVG raster path runs through an
    # embedded JIT-compiling WASM runtime, and it dies with
    # `fatal error: unsafe.Slice: len out of range` on part of the GitHub
    # runner fleet (golang/go#78976, closed unresolved): green on
    # 2026-08-06, sporadic on 2026-08-08, and consistently red on
    # 2026-08-27's runner image. This check defends wiring — tool presence,
    # nixpkgs attributes, font files — so the crashy PNG rasterizer must not
    # be load-bearing. Retry PNG bounded; when every attempt crashes, an SVG
    # render (no WASM rasterizer) must still prove the ANSI/font wiring.
    # Deterministic breakage — bad arguments, missing fonts, renamed
    # attributes — fails the SVG path too, so it still fails the flake.
    grep -m1 'model name' /proc/cpuinfo || true
    rendered=0
    for attempt in 1 2 3; do
      if freeze --version && freeze --language ansi frame.ansi -o frame.png \
        --font.family "JetBrains Mono,Symbols Nerd Font Mono" && test -s frame.png; then
        rendered=1
        break
      fi
      echo "freeze attempt $attempt crashed; retrying" >&2
    done
    if [[ "$rendered" != 1 ]]; then
      echo 'PNG rasterizer crashed on every attempt; proving wiring via SVG render' >&2
      freeze --language ansi frame.ansi -o frame.svg \
        --font.family "JetBrains Mono,Symbols Nerd Font Mono"
      test -s frame.svg
      grep -q 'pill' frame.svg
    fi

    mkdir "$out"
  ''
