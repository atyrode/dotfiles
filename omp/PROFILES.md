# OMP profile design

This is the *why* behind the managed OMP launchers. The *what* — the actual
role → model maps and fallback chains — lives in [`defaults.yml`](defaults.yml)
and [`presets/`](presets/); the operational reference (launcher table, config
load order, security posture) is [`docs/agent-tools.md`](../docs/agent-tools.md).
Read this file before reshaping the routing, and update it when you do.

Everything here was derived from `omp models` on 2026-07-11. Prices are list
price per 1M tokens (input/output); with subscription auth (Codex credits /
Claude plan) they read as **relative burn rates** rather than direct dollars.

## The model catalog

Only the models actually used in routing matter here. The catalog — short key,
pool, tier, quota bucket, cost ($ per 1M in / out), context, thinking range, and
role — is structured data in [`models.yml`](models.yml), the single source the
tooling reads; its cost figures mirror `omp models` (the authority). Browse it
**sorted and filterable in the profiles wiki** (`code --wiki`), which also renders
every launcher's routing and rationale. `omp models` shows the full registry,
including previous GPT generations that cost less per token but deliver less per
dollar than the 5.6 tiers, so nothing routes to them today.

† **Sonnet 5** is at introductory pricing through **2026-08-31**, then $3 / $15 —
dearer than Terra. See [Revisit triggers](#revisit-triggers).

**Availability on a ChatGPT/Codex account:** `gpt-5.4` and `gpt-5.4-nano` return
`invalid_request` ("not supported when using Codex with a ChatGPT account"), so
they're out. `gpt-5.4-mini` *is* usable and slightly cheaper than Luna, but it's
a previous-gen small model with a smaller window, so **Luna is the chosen cheap
floor** and nothing routes to mini. There is **no OpenAI 1M model** on this
account, which is why `ompx` is Anthropic-1M-only for its substantive roles.
Also not routed: the GPT-5.x back-catalog and the `-codex`-tuned variants.

## Principles

1. **Redundancy first: every lead is backed by a same-bucket sibling.** Before a
   chain crosses providers it tries another model *from the same quota bucket*,
   so a single model being down or overloaded is absorbed without leaving the
   bucket you meant to use. The shape is `A → A → B → B`: lead, its same-bucket
   sibling, then the capability-matched model on the other provider and *its*
   sibling. `gpt → gpt → claude → claude`, not `gpt → claude`.
2. **Spark and Fable are their own bucket.** They draw separate quota, so a hop
   *off* Spark (`spark → luna`) or *off* Fable (`fable → opus`) is a real
   fallback to a different rate — never a redundancy sibling. They are never an
   automatic net: Fable-led chains fall to main-plan Opus, and Spark-led roles
   fall to a main-Codex rung.
3. **Sibling direction follows the profile's job.** The `smart`/`regular` (quality)
   profiles escalate to the *capable* neighbour, so a chain never routes below the
   lead's tier. The `speed` profiles stay lean — a single fast cross, no slower
   same-bucket detour (that would defeat latency). The pure-pool profiles never
   cross at all (see 4). The 1M profile can't cross (no OpenAI 1M exists), so its
   redundancy is Anthropic-internal.
4. **A profile is a quota lever.** Each lane commits its leads to one pool, so
   switching launchers switches which meter burns — the *other* pool is the net.
   The two **pure-pool** profiles (`ompo` gpt-only, `ompe` claude-only) take this
   to the limit: they never cross, keeping every token on one provider for
   draining a bucket, or for when the other provider is down or off-limits.
5. **Speed and cost are the same axis.** The fast models are the cheap ones
   (Luna/Haiku, low thinking) and the smart models are the dear ones (Sol/Fable/
   Opus, high thinking). There is no useful "cheap-but-slow" model, so there is no
   separate "budget" tier — the `speed` lane *is* the cheap option.
6. **Fast-execution roles drain the free Spark bucket first.** `gpt-5.3-codex-spark`
   has a separate, normally-idle 5h/7d Codex quota (see [Separate rate
   buckets](#separate-rate-buckets)), so execution/background roles lead on it.
   Because the bucket is free and the goal is to empty it, the real-work coding
   roles (`task`/`sonic`) run at **`:xhigh`** — best output *and* faster drain —
   while boilerplate (`tiny`/`commit`) stays `:low`. The `speed` profiles are the
   exception: they run Spark at `:low`, optimising latency over drain. Spark stays
   off `smol`/scout (exploration can exceed its 128K window), the thinking roles,
   `ompf`, the claude-only pure pool, and the `advisor` (principle 7).
7. **The advisor is a judge, not a drain target.** It shadows every turn as a peer
   reviewer, so it is a *judgment* role — matched to a model that reviews well,
   never to whatever is cheap or idle (Spark is "coding-tuned and fast," a poor
   reviewer). It scales with stakes: `smart` profiles run **Sonnet 5** (best
   judgment-per-token, cheaper than their premium main; `gpt-only` stays on Terra
   to remain single-auth), `regular` profiles a lighter **Haiku 4.5** at lower
   cadence, and `speed`/`budget` turn it **off** — its ~2× token cost rivals their
   cheap main, so those tokens buy a better main instead. `ompx` (1M context) also
   runs it off: mirroring a million-token transcript every turn would cost more
   than the work it shadows. Never the main model itself; cadence
   (`advisor.syncBacklog`/`immuneTurns`) tightens on `smart`, loosens on `regular`.
8. **Trivial roles stay lean.** Background gets at most a short cheap chain
   (Spark → a cheap rung → Haiku); a blip on a commit message is harmless. The
   full `A → A → B → B` redundancy is reserved for the substantive roles.
9. **Thinking scales with stakes.** high/xhigh for `plan`/`slow`/`reviewer`/
   `designer` and the `smart` leads; medium for the `regular` interactive default
   and workers; low/minimal for the `speed` leads and background.

## Separate rate buckets

With subscription auth the real constraint is not dollars but **quota windows**,
and the providers meter more than one bucket per account. `omp usage` shows them,
and the `code` picker renders a compact live panel of them (see
[The `code` picker](#the-code-picker)):

- **OpenAI Codex has two independent buckets.** The main 5h/7d window is shared
  by `sol`/`terra`/`luna`. But `gpt-5.3-codex-spark` draws a **separate** 5h/7d
  "Spark" bucket that usually sits at 0% — effectively **free extra Codex
  capacity every window**. In an ideal world we drain it rather than let it
  reset unused, so the execution/background roles lead on Spark and fall back the
  instant it 429s (transparent drain). It's `$1.75/$14` list, so this only
  "wins" under subscription auth where quota, not dollars, is scarce.
- **Fable is the mirror image — a separate but *scarce* bucket.** Fable draws its
  own 7-day sub-limit that is frequently the binding Anthropic constraint (often
  80%+ while the general Claude bucket sits much lower). So it is spent
  *deliberately* (as an elite lead) and **never** as an automatic net — the
  redundancy pairs are built from main-plan models. When the picker panel flags
  Fable **tight**, lean on a Sonnet/Opus profile or an OpenAI-led one.

The picker panel exists to make this a glance-and-pick decision: see which bucket
is tight before you choose a harness.

## The palette — a lane × tier matrix

Three **lanes** (which pool leads) × three **tiers** (`speed`/`regular`/`smart`),
plus a pure-pool per provider and a few specials. `code` (see
[below](#the-code-picker)) is an umbrella picker over all of them.

| | speed | regular | smart | pure |
| --- | --- | --- | --- | --- |
| **mixed** (both meters) | `ompz` | `ompn` | `ompm` | — |
| **gpt** (Codex meter) | `ompl` | `ompb` | `ompg` | `ompo` (gpt-only) |
| **claude** (Claude meter) | `ompk` | `omps` | `ompc` | `ompe` (claude-only) |

Specials: `ompf` (deterministic Fable) · `ompx` (huge-context 1M). Base layer:
[`defaults.yml`](defaults.yml) underlies every launcher and is the entire model
map for `ompu` (untrusted repos), whose real differences are posture (approvals,
secrets, isolation), not models. `omp` is the operator's own unmanaged config.

## Per-profile rationale

Routing detail is in the YAML; each file's header comment states its thesis. By
tier:

- **`speed`** (`ompz` mixed · `ompl` gpt · `ompk` claude) — fastest competent
  tiers at low thinking, latency over depth. Leads on Luna/Haiku (and Spark for
  `task`/background); fallbacks are single fast hops across to the other pool's
  cheap tier, with no slower same-bucket sibling. Nothing reaches for
  Sol/Fable/Opus. `ompk` is where Haiku lives as a lead rather than just
  background.
- **`regular`** (`ompn` mixed · `ompb` gpt · `omps` claude) — the balanced daily
  drivers at medium thinking, with full `A → A → B → B` redundancy on every
  substantive role. `ompn` splits the work by strength (Claude leads judgment,
  GPT leads execution); `ompb` is routine Codex work kept off the premium tiers
  (failovers stay on Luna/Terra + Haiku/Sonnet, never Sol/Opus); `omps` is
  Sonnet-led everyday value, Opus for plan/slow.
- **`smart`** (`ompm` mixed · `ompg` gpt · `ompc` claude) — hardest work at high
  thinking, full redundancy. `ompg` runs GPT → GPT → Claude; `ompc` is its mirror
  (Fable drives, Opus is the sibling and leads review, reaches back to Sol/Terra);
  `ompm` picks the **best model per task** — Sol on GPT-strength roles, Fable/Opus
  on the Claude-strength ones (design, planning, review).
- **`ompo`** (gpt-only) / **`ompe`** (claude-only) — pure pools that **never
  cross**. Redundancy stays inside one provider (`Sol → Terra → Luna` /
  `Opus → Sonnet → Haiku`). `ompe` also avoids the separate Spark/Fable buckets
  entirely. Load them to keep every token on one meter — draining it, or when the
  other provider is down or off-limits.
- **`ompf`** ([fable-primary.yml](presets/fable-primary.yml)) — Fable-first,
  deterministic. Retry and server-side fallback **off**: the contract is "give me
  Fable, predictably, never silently swap." Resilience is `ompc`'s job, so `ompf`
  stays pure; background rides cheap OpenAI rungs so Fable isn't burned on commit
  messages (the mixed pool is the accepted price of determinism).
- **`ompx`** ([context-1m.yml](presets/context-1m.yml)) — work beyond the 372K
  ceiling. Anthropic owns 1M and no OpenAI 1M runs on this account, so every
  substantive role — lead *and* fallback — stays on Anthropic's 1M line
  (Fable/Opus/Sonnet); there is no cross-net, so if Anthropic is down, huge-context
  work waits. Background trivia never sees the big context, so it drains Spark →
  Luna → Haiku.

## The `code` picker

`code` resolves a selector (menu number, launcher name, alias like `plain`, or a
single suffix letter — `code ompg`, `code 7`, `code z`) and execs the matching
launcher, forwarding every remaining argument. A first argument that is not a
known profile opens the picker, then forwards all arguments to the choice, so
`code --resume` picks first, then resumes. `code --list` / `code --help` are
non-interactive. It is a thin wrapper: the chosen launcher applies its own
managed overlays unchanged.

With no profile argument it opens an `fzf` picker — arrow keys + Enter, fuzzy
filtering, truecolor. Its encoding:

- **Colour = lane.** mixed → purple, gpt → blue, claude → orange, bare → green,
  special → teal (`ompu` keeps a red warning tint). A quiet category label
  (`mixed`, `gpt-led`, `claude-led`, `special`) marks the first row of each
  group on the left, and the lane colour rides the glyph beside it.
- **Glyph = intended use.** speed → bolt, regular → cogs, smart → lightbulb,
  pure-pool → broken-link (never crosses), plus per-special icons (deterministic
  → pin, 1M → book, untrusted → lock). The icon reflects what a profile is *for*,
  not just its provider — so the `smart` profiles carry a lightbulb, not the bolt
  they used to inherit from being GPT-led.
- **Preview.** The highlighted profile's detail (with provider/model mentions
  tinted) and its routing, model names coloured by provider and shaded by
  thinking level. `ctrl-f` cycles the routing depth: hidden → the
  cross-provider net (redundancy siblings collapsed) → the full chain plus the
  rationale. `ompu` inherits the managed defaults routing and shows it like any
  preset. The bare `omp` is unmanaged, so it resolves and shows your *own*
  `~/.omp` role→model routing (cached from `omp config list`, refreshed in the
  background since that call is ~0.9 s); until the first resolve lands it lists
  the bundled subagents.
- **Keys.** The picker is keyboard-driven (`--no-mouse`): arrows or typing
  filter, Enter selects, `ctrl-f` toggles routing depth, and `shift-↑/↓` (line)
  or `alt-↑/↓` (half-page) scroll the preview when it overflows a short terminal.
  Mouse is off entirely — fzf couples wheel-scroll and hover on a trackpad, so
  the only way to guarantee the right pane never scrolls under the cursor is to
  disable mouse input and scroll it by key instead.
- **Usage panel** in the footer: each quota window's green→red bar, `N% used`,
  time-to-reset (brighter as it nears, relative to the window), and `idle`/`tight`
  tags — so you see which meter has room before you pick. It reads the
  tyrode.dev collector snapshot when present (instant, always fresh) or a
  background-refreshed local cache, and **never blocks the picker**.

Previews render lazily (only the focused profile) with a background pre-warm on
open, so the picker itself opens in tens of milliseconds. It falls back to a
plain typed menu (with text group headers) when `fzf` is absent or
`CODE_NO_FZF=1`.

Picking a launcher holds a full-screen **starting card** — the profile, its
description, and its lead-only model list (no fallback chains) with a loading
mark — across omp's ~0.6 s cold start, so the picker never flashes back to a
bare terminal before omp paints over it.

It is defined in [`pkgs/omp-configured/default.nix`](../pkgs/omp-configured/default.nix)
from a single `paletteProfiles` list that also feeds the `omph` route view, so
the picker, the routing page, and the launchers never drift.

## Changing the routing

1. Edit [`defaults.yml`](defaults.yml) (base map) or the relevant
   [`presets/`](presets/) file. Model selectors are `provider/model:thinking`,
   e.g. `openai-codex/gpt-5.6-terra:medium`.
2. Verify the selector and thinking level exist: `omp models --json`. A bad ID
   or level is a *runtime* error, not a build failure — the YAML is not validated
   against the registry at build time.
3. Run `zconf` (`atyrode apply`), then `omph` to see the rendered routing.
4. If you add or rename a launcher, update `paletteProfiles` (and the `lane_color`
   / `icon_glyph` maps) in `pkgs/omp-configured/default.nix`, the preset set in
   `modules/home/agent-tools.nix`, and the assertions in `checks/agent-tools.nix`
   (the bin inventory and `omph` descriptions are pinned).

## Revisit triggers

- **The 5.4 family.** `gpt-5.4`/`-nano` aren't usable on a ChatGPT/Codex account;
  `gpt-5.4-mini` works but is left unused in favour of Luna (current-gen, wider
  window). There is no ChatGPT-usable OpenAI 1M tier, so `ompx` stays
  Anthropic-1M-only. If OpenAI ships a usable cheap-and-current or 1M tier,
  revisit the cheap floor and `ompx`.
- **Sonnet's price cliff.** `omps` (and the mixed regular/smart judgment roles)
  ride Sonnet's introductory pricing ($2/$10). On **2026-08-31** it steps to
  $3/$15 — dearer than Terra. Pool separation still justifies the profiles, but
  recheck the "cheapest premium-adjacent" pitch against Terra then.
- **How hard to push Spark.** Spark leads the fast-execution roles. Watch the
  Spark 5h/7d bars in the `code` panel: if they never approach full, push more
  roles onto Spark; if they saturate early and fall back constantly, ease off.
  If a background `:low` output degrades in practice, revert that role to its
  cheap rung — one line per role.
- **Model registry churn.** New tiers or price changes can invalidate a lead or a
  price-twin pairing. The presets are policy, not pricing data — re-derive from
  `omp models` when the catalog moves.
