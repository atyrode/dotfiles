---
name: tui-visual-verification
description: Run a Bubble Tea (or any terminal) TUI headlessly, drive it with keys, and verify the rendered output — character-exact via tmux capture-pane, pixel-level via freeze PNG renders. Use whenever building or changing TUI layout, colors, or glyphs.
---

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

A naive run therefore "proves" color bugs that do not exist. You MUST launch
the app under test with:

```console
$ env -u NO_COLOR -u CI CLICOLOR_FORCE=1 COLORTERM=truecolor TERM=xterm-256color <app>
```

With that exact env the app emits true 24-bit SGR (`38;2;r;g;b`) even inside a
tmux pane. You MUST verify `grep -c '38;2;' frame.ansi` returns > 0 before
judging color.

## 1. Character-exact verification with tmux (authoritative)

You MUST run the TUI in a detached tmux session, drive it with `send-keys`, and
read back the exact rendered character grid:

```console
$ tmux new-session -d -s tui -x 150 -y 44 \
    "env -u NO_COLOR -u CI CLICOLOR_FORCE=1 COLORTERM=truecolor TERM=xterm-256color \
     CODE_GENERATED=… <app>; sleep 300"
$ tmux send-keys -t tui Down Down Right          # navigate and change a dial
$ tmux capture-pane -t tui -p  > /tmp/frame.txt  # plain text grid
$ tmux capture-pane -t tui -pe > /tmp/frame.ansi # with SGR color sequences
```

This is deterministic and assertable:

- **Layout / overflow** — You MUST count physical lines, check every row's
  width, and inspect the *bottom* of the frame. Vertical overflow from wrapped
  or added rows lands there (pushed footers, clipped hints).
- **Glyphs** — Nerd Font icons live in the Private Use Area and are *invisible*
  in most editors and agent tooling. NEVER eye-verify them or retype source
  lines containing them. You MUST grep captures for exact codepoints (for
  example, `\uf02d`) programmatically.
- **Colors / style bleed** — You MUST inspect SGR sequences in the `-e` capture
  around suspect regions (for example, text wrapping that loses its dim style).

For `code`, you MUST build with `nix build .#code`, generate the grid with
`MODELS_YML=omp/models.yml python3 pkgs/omp-configured/generate-profiles.py`,
and point `CODE_GENERATED` at the output. No further wrapper env is required.

## 2. Content-dependent responsive layouts

A frame can stay within the terminal and still be wrong: dynamic data may make
unrelated panes move, widen every sibling, or select a different composition
when the content would fit without that reflow. You MUST treat structural
stability as a separate contract from overflow safety.

### Measure and allocate deliberately

- You MUST measure complete styled rows in terminal cells with production's
  width function. Byte length and rune count are not terminal width; include
  labels, bars, notes, separators, borders, and padding.
- You MUST measure sibling panes or columns independently. NEVER multiply one
  child's intrinsic maximum across every sibling unless equal allocation is an
  explicit, tested product requirement.
- You MUST base horizontal-fit decisions on independently allocated widths.
  One child's extreme value MUST NOT redefine every peer's requirement.
- You SHOULD keep outer breakpoints independent of volatile runtime data.
  Runtime-dependent composition MUST define and test allowed transitions.
- You MUST define a degradation order. Preserve primary state, controls, and
  essential values before shortening notes or omitting optional identity and
  explanation; only then MAY the macro composition change.

### Test the decision, boundaries, and transitions

- You MUST pair implementation-derived breakpoints with fixed, externally
  chosen viewports below, at, and above meaningful boundaries. Fixtures derived
  entirely by production code can move with the defect.
- At one fixed viewport, you MUST vary one input at a time: balanced and
  asymmetric siblings, label lengths, optional metadata, record counts, and
  loading, ready, stale, unavailable, and error states.
- You MUST assert structural invariants and bounds: column starts, pane height,
  selected-control position, footer position, orientation, unrelated-sibling
  movement, and documented degradation order.
- You MUST exercise transitions without resize and resize without state
  changes. Focused oracles MUST fail on plausible bad allocation or unnecessary
  mode changes; representative end-to-end renders remain guards, not
  substitutes.

You MUST use character-exact tmux captures at identical dimensions as the
authoritative geometry check and compare related states together. You SHOULD
use pixel renders for changed color, contrast, glyph appearance, or visual
hierarchy when the renderer is reliable; pixels are diagnostic, not the
structural gate.

Reusable layout code SHOULD keep measurement and composition selection in a
pure internal decision. Unit tests exercise that decision; frame tests MUST
verify rendering without wrapping, clipping, or moving persistent controls.

## 3. Pixel-level view with freeze (deterministic screenshots)

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

## 4. Alternatives for live or scripted viewing

- **vhs** (`nixpkgs#vhs`) — scripted terminal driver: `.tape` files with
  `Type`/`Down`/`Sleep`/`Screenshot`/`Set FontFamily`. Best on an operator
  machine; it drives ttyd + headless Chromium underneath, so it shares that
  stack's flakiness in constrained sandboxes.
- **ttyd** (`nixpkgs#ttyd`) — serve `tmux attach -t tui` over loopback HTTP and
  view or screenshot from a browser: the only option for *watching* a session
  live. Flaky under headless browsers (stalled loads, blank canvas, scrollback
  cropping after resizes). If used, you MUST keep it loopback-bound, attach the
  browser client *before* drawing, reload after every resize, and pass
  `-t 'fontFamily=Symbols Nerd Font Mono,monospace'` for glyphs.

## 5. Cleanup

You MUST kill the session and every server when done: `tmux kill-server`,
`kill $(cat /tmp/ttyd.pid)`.
