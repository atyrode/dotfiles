---
name: tui-visual-verification
description: Run a Bubble Tea (or any terminal) TUI headlessly, drive it with keys, and verify the rendered output — character-exact via tmux capture-pane, pixel-level via freeze PNG renders. Use whenever building or changing TUI layout, colors, or glyphs.
---

# TUI visual verification

The owning documentation lives in the repository:
[docs/tui-verification.md](../../../docs/tui-verification.md).

Follow it whenever you build or change TUI layout, colors, or glyphs. The three
rules that prevent the historical failures:

1. Launch the app with
   `env -u NO_COLOR -u CI CLICOLOR_FORCE=1 COLORTERM=truecolor TERM=xterm-256color`
   — otherwise the harness env silently strips (`NO_COLOR`) or quantizes to 16
   colors (`CI`, verified A/B) everything you are trying to judge.
2. Verify glyphs by grepping `tmux capture-pane` output for exact PUA
   codepoints; never by eye, and never retype source lines containing them.
3. Judge pixels from `freeze --language ansi` PNG renders, and check the bottom
   of the frame for overflow.
