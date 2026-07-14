---
name: tui-visual-verification
description: Run a Bubble Tea (or any terminal) TUI headlessly, drive it with keys, and verify the rendered output — character-exact via tmux capture-pane, pixel-level via freeze PNG renders. Use whenever building or changing TUI layout, colors, or glyphs.
---

# TUI visual verification (tmux capture + freeze)

Unit tests on render functions miss what actually reaches the terminal: wrapped
rows that overflow a pane, styles that reset mid-line, glyphs silently wiped to
empty strings. Verify TUI changes against the real program, headlessly.

## 0. Agent environments suppress color — undo that first

Agent harnesses commonly export `NO_COLOR=1`, `CI=1`, and `TERM=dumb`. lipgloss
honors `NO_COLOR` and renders colorless, so a naive run "proves" a color bug
that does not exist. Always launch the app under test with:

```console
$ env -u NO_COLOR CLICOLOR_FORCE=1 COLORTERM=truecolor TERM=xterm-256color <app>
```

Know the ceiling: termenv caps any `TERM` beginning with `tmux`/`screen` at
ANSI-256, so hex colors appear as approximations inside tmux. That is fine for
verification (colors present, distinguishable); do not chase truecolor there.

## 1. Character-exact verification with tmux (authoritative)

Run the TUI in a detached tmux session, drive it with `send-keys`, and read
back the exact rendered character grid:

```console
$ tmux new-session -d -s tui -x 150 -y 44 \
    "env -u NO_COLOR CLICOLOR_FORCE=1 CODE_GENERATED=… <app>; sleep 300"
$ tmux send-keys -t tui Down Down Right          # navigate and change a dial
$ tmux capture-pane -t tui -p  > /tmp/frame.txt  # plain text grid
$ tmux capture-pane -t tui -pe > /tmp/frame.ansi # with SGR color sequences
```

This is deterministic and assertable:

- **Layout / overflow**: count physical lines, check every row's width, and
  look at the *bottom* of the frame — vertical overflow from wrapped or added
  rows always lands there (pushed footers, clipped hints).
- **Glyphs**: Nerd Font icons live in the Private Use Area and are *invisible*
  in most editors and agent tooling — never eye-verify them, and never retype a
  source line containing them (that is how they get wiped). Grep the capture
  for the exact codepoints (e.g. `\uf02d`) programmatically.
- **Colors / style bleed**: inspect the SGR sequences in the `-e` capture
  around a suspect region (e.g. text that wraps and loses its dim style).

For `code` specifically: build with `nix build .#code-tui`, generate the grid
with `MODELS_YML=omp/models.yml python3 pkgs/omp-configured/generate-profiles.py`,
and point `CODE_GENERATED` at the output. No further wrapper env is required.

## 2. Pixel-level view with freeze (validated, deterministic)

To actually *look* at a frame (colors, pills, contrast), render the ANSI
capture to PNG with `freeze` — no server, no browser, no client sizing:

```console
$ nix shell nixpkgs#charm-freeze -c \
    freeze --language ansi /tmp/frame.ansi -o /tmp/frame.png \
    --font.family "JetBrains Mono,Symbols Nerd Font Mono"
```

Install the fonts once where freeze runs (`nixpkgs#jetbrains-mono`,
`nixpkgs#nerd-fonts.symbols-only` → `~/.local/share/fonts` + `fc-cache -f`).
Caveat: freeze's per-glyph font fallback is imperfect, so PUA icons may render
as boxes even when correct — the codepoint grep from step 1 stays authoritative
for glyphs; the PNG is for layout and color judgment.

## 3. Alternatives for live or scripted viewing

- **vhs** (`nixpkgs#vhs`): scripted terminal driver — `.tape` files with
  `Type`/`Down`/`Sleep`/`Screenshot`/`Set FontFamily` — good for repeatable
  demo flows. It drives ttyd + headless Chromium underneath, so it shares that
  stack's flakiness in constrained agent sandboxes; prefer tmux + freeze for
  verification.
- **ttyd** (`nixpkgs#ttyd`): serve `tmux attach -t tui` over loopback HTTP and
  screenshot from a browser tool — the only option for *watching* a session
  live. Flaky under headless browsers (stalled loads, blank canvas, scrollback
  cropping after resizes). If used: attach the browser client *before* the app
  draws so it sets the window size, reload the page after any resize, and pass
  `-t 'fontFamily=Symbols Nerd Font Mono,monospace'` for glyphs.

## 4. Cleanup

Kill the session and any server when done: `tmux kill-server`,
`kill $(cat /tmp/ttyd.pid)`.
