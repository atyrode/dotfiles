# Headless TUI verification

How to run a terminal UI (the `code` generator, or any Bubble Tea program)
without a graphical session, drive it with keys, and verify what it actually
renders — for operators debugging a TUI and for agents shipping changes to one.
Unit tests on render functions miss what reaches the terminal: wrapped rows
that overflow a pane, styles that reset mid-line, glyphs silently wiped to
empty strings.

The toolchain: **tmux** (drive + capture, authoritative), **charm-freeze**
(deterministic PNG renders), with ttyd/vhs as live-viewing alternatives.
tmux, charm-freeze, and the render fonts (JetBrains Mono + Nerd Font symbols)
ship in the managed agent tool suite — the `agent-tools` capability
([issue #163](https://github.com/atyrode/dotfiles/issues/163)); ttyd/vhs stay
on-demand `nix shell` tools because that stack is flaky in agent sandboxes.

## 0. Fix the environment first — it silently degrades color

Agent harnesses and CI export `NO_COLOR=1`, `CI=1`, and `TERM=dumb`, and each
degrades color independently:

- lipgloss honors `NO_COLOR` → fully colorless output;
- termenv treats **any `CI` env as a 16-color terminal** regardless of
  `TERM`/`COLORTERM` → hex colors quantize into 16 ANSI buckets (grays come out
  purple), which defeats color judgment entirely;
- termenv caps `TERM`s beginning with `tmux`/`screen` at ANSI-256.

A naive run therefore "proves" color bugs that do not exist. Always launch the
app under test with:

```console
$ env -u NO_COLOR -u CI CLICOLOR_FORCE=1 COLORTERM=truecolor TERM=xterm-256color <app>
```

With that exact env the app emits true 24-bit SGR (`38;2;r;g;b`) even inside a
tmux pane. Verify with `grep -c '38;2;' frame.ansi` (> 0) before judging any
color.

## 1. Character-exact verification with tmux (authoritative)

Run the TUI in a detached tmux session, drive it with `send-keys`, and read
back the exact rendered character grid:

```console
$ tmux new-session -d -s tui -x 150 -y 44 \
    "env -u NO_COLOR -u CI CLICOLOR_FORCE=1 COLORTERM=truecolor TERM=xterm-256color \
     CODE_GENERATED=… <app>; sleep 300"
$ tmux send-keys -t tui Down Down Right          # navigate and change a dial
$ tmux capture-pane -t tui -p  > /tmp/frame.txt  # plain text grid
$ tmux capture-pane -t tui -pe > /tmp/frame.ansi # with SGR color sequences
```

This is deterministic and assertable:

- **Layout / overflow** — count physical lines, check every row's width, and
  look at the *bottom* of the frame: vertical overflow from wrapped or added
  rows always lands there (pushed footers, clipped hints).
- **Glyphs** — Nerd Font icons live in the Private Use Area and are *invisible*
  in most editors and agent tooling. Never eye-verify them, and never retype a
  source line containing them (that is how they get wiped). Grep the capture
  for the exact codepoints (e.g. `\uf02d`) programmatically.
- **Colors / style bleed** — inspect the SGR sequences in the `-e` capture
  around a suspect region (e.g. text that wraps and loses its dim style).

For `code` specifically: build with `nix build .#code-tui`, generate the grid
with `MODELS_YML=omp/models.yml python3 pkgs/omp-configured/generate-profiles.py`,
and point `CODE_GENERATED` at the output. No further wrapper env is required.

## 2. Pixel-level view with freeze (deterministic screenshots)

To actually *look* at a frame (colors, pills, contrast), render the ANSI
capture to PNG with `freeze` — no server, no browser, no client sizing:

```console
$ freeze --language ansi /tmp/frame.ansi -o /tmp/frame.png \
    --font.family "JetBrains Mono,Symbols Nerd Font Mono"
```

With the truecolor env from §0, the PNG reproduces the authored hex colors
exactly (24-bit SGR bypasses freeze's ANSI theme palette). freeze and both
fonts are installed by the `agent-tools` capability with user fontconfig
enabled; on an unmanaged machine, `nix shell nixpkgs#charm-freeze` and drop
`nixpkgs#jetbrains-mono` + `nixpkgs#nerd-fonts.symbols-only` into
`~/.local/share/fonts` (then `fc-cache -f`).

Known limitations:

- freeze's per-glyph font fallback is unreliable, so PUA icons may render as
  tofu boxes even when correct — the codepoint grep from §1 stays authoritative
  for glyphs; the PNG is for layout and color judgment.
- Background color runs can smear to end-of-line (pill labels render as a
  full-width band) — a capture artifact, not an app bug.

## 3. Alternatives for live or scripted viewing

- **vhs** (`nixpkgs#vhs`) — scripted terminal driver: `.tape` files with
  `Type`/`Down`/`Sleep`/`Screenshot`/`Set FontFamily`. Best on an operator
  machine; it drives ttyd + headless Chromium underneath, so it shares that
  stack's flakiness in constrained sandboxes.
- **ttyd** (`nixpkgs#ttyd`) — serve `tmux attach -t tui` over loopback HTTP and
  view or screenshot from a browser: the only option for *watching* a session
  live. Flaky under headless browsers (stalled loads, blank canvas, scrollback
  cropping after resizes). If used: keep it loopback-bound, attach the browser
  client *before* the app draws so it sets the window size, reload the page
  after any resize, and pass `-t 'fontFamily=Symbols Nerd Font Mono,monospace'`
  for glyphs.

## 4. Cleanup

Kill the session and any server when done: `tmux kill-server`,
`kill $(cat /tmp/ttyd.pid)`.
