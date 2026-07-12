# OMP profile design

This is the *why* behind the managed OMP launchers. The *what* — the actual
role → model maps and fallback chains — lives in [`defaults.yml`](defaults.yml)
and [`presets/`](presets/); the operational reference (launcher table, config
load order, security posture) is [`docs/agent-tools.md`](../docs/agent-tools.md).
Read this file before reshaping the routing, and update it when you do.

Everything here was derived from `omp models` on 2026-07-11 and prototyped in an
interactive proposal artifact ("OMP routing proposal"). Prices are list price
per 1M tokens (input/output); with subscription auth (Codex credits / Claude
plan) they read as **relative burn rates** rather than direct dollars.

## The model catalog

Only the models actually used in routing are listed. `omp models` shows the full
registry, including previous GPT generations that are cheaper per token but
deliver less per dollar than the 5.6 tiers, so nothing routes to them today.

### OpenAI (provider `openai-codex`)

| Model | $ in/out | Context | Thinking | Role in routing |
| --- | --- | --- | --- | --- |
| `gpt-5.6-sol` | $5 / $30 | 372K | low→max | Flagship. Leads `ompg` and the base default. Out-prices Opus 4.8 per output token. |
| `gpt-5.6-terra` | $2.50 / $15 | 372K | low→max | Balanced workhorse. Leads `ompb` and the task/librarian roles. Sonnet's price-twin. |
| `gpt-5.6-luna` | $1 / $6 | 372K | low→max | Fast, high-volume. Sibling hop and cheap worker across the OpenAI-led maps. |
| `gpt-5.4` | $2.50 / $15 | **1M** | low→xhigh | The only OpenAI 1M card. `ompx`'s cross-net and librarian lead. |
| `gpt-5.4-nano` | **$0.20 / $1.25** | 272K | low→xhigh | Cheapest model on hand (~5× under Luna). Background trivia (`commit`/`tiny`, all of `ompb`'s background). No `minimal` level — floor is `low`. |

### Anthropic (provider `anthropic`)

| Model | $ in/out | Context | Thinking | Role in routing |
| --- | --- | --- | --- | --- |
| `claude-fable-5` | $10 / $50 | 1M | low→max | Most capable. Drives `ompf`/`ompc`, plans in `ompx`, holds the base `plan` role. Thinking is always on (levels are effort). |
| `claude-opus-4-8` | $5 / $25 | 1M | low→max | Top Opus tier. Leads `omps`'s plan/slow and `ompx`'s live thread; the deliberative fallback across the maps. |
| `claude-sonnet-5` | $2 / $10 † | 1M | low→max | The value pick — near-Opus quality at a fraction of the cost. Leads `omps` and the Anthropic-led worker roles. |
| `claude-haiku-4-5` | $1 / $5 | 200K | minimal→xhigh | Fastest/cheapest Anthropic tier. Background hum of the Anthropic-led maps; cross-net for `ompb`'s task. |

† Sonnet 5 is at introductory pricing through **2026-08-31**, then $3 / $15 —
dearer than Terra. See [Revisit triggers](#revisit-triggers).

Not routed: `gpt-5.4-mini` (squeezed between nano and Luna with no niche),
`gpt-5.1-codex-mini` (cheap but narrow thinking), the rest of the GPT-5.x
back-catalog, and `claude-mythos-5` (gated private program, not usable).

## Principles

1. **Every fallback chain ends by crossing providers.** A same-provider sibling
   first cheaply rules out a single model being at capacity; the last,
   load-bearing hop must reach the *other* vendor, or the chain dies with its
   provider. `Sol → Terra → Luna` is three OpenAI models — one outage takes all
   three.
2. **Sibling hops must be price-lateral.** `Sol → Terra` costs nothing extra to
   try. Sonnet has no lateral Anthropic sibling (Opus is 2.5× up, Haiku a class
   down), so Sonnet-led chains cross straight to Terra, its price-twin. No chain
   silently upgrades you. (High-stakes `reviewer` is the deliberate exception:
   escalating to Opus on failure is a feature, not a surprise.)
3. **One subscription pool per profile.** All-OpenAI columns burn Codex credits;
   all-Anthropic columns burn the Claude plan — background roles included. A
   profile is therefore also a quota lever: when one meter runs dry, switch
   columns and *everything* moves. The fallback net is the other pool.
4. **Fast-execution roles drain the free Spark bucket first.** `gpt-5.3-codex-spark`
   has a separate, normally-idle 5h/7d Codex quota (see [Separate rate
   buckets](#separate-rate-buckets--an-underused-lever)), so the execution and
   background roles — `sonic`/`advisor`/`tiny`/`commit`, plus `task` in the
   OpenAI-led profiles — lead on it. Because that bucket is free and the goal is
   to empty it, the roles that do real work (`task`/`sonic`/`advisor`) run at
   **`:xhigh`** — best output *and* faster drain — while the boilerplate
   one-liners (`tiny`/`commit`) stay at `:low`, where xhigh reasoning would only
   add latency. When the bucket is exhausted each role falls back to the cheap
   rung: `gpt-5.4-nano` ($0.20/$1.25) under OpenAI-led profiles, `claude-haiku-4-5`
   ($1/$5) under Anthropic-led ones. Spark stays off `smol`/scout (exploration
   can exceed its 128K window), the thinking roles, and `ompf`.
5. **Trivial roles carry at most one cheap fallback.** Background is never
   crossed to a premium model — it gets exactly one hop, from Spark down to the
   cheap rung, so draining the Spark allowance is transparent. The real chains
   are reserved for the live thread, the workers, and the deliberative roles.
6. **Thinking scales with stakes.** xhigh/high for `plan`, `slow`, `reviewer`,
   `designer`; medium for the interactive default and workers; low/minimal for
   background. `ompb` caps at high even for its deliberative roles.

## Separate rate buckets — an underused lever

With subscription auth the real constraint is not dollars but **quota windows**,
and the providers meter more than one bucket per account. `omp usage` shows them
(and the `code` picker renders a compact panel of them beside the palette):

- **OpenAI Codex has two independent buckets.** The main 5h/7d window is shared
  by `sol`/`terra`/`luna`/`gpt-5.4`/`nano`. But `gpt-5.3-codex-spark` draws from
  a **separate** 5h/7d "Spark" bucket that is usually sitting at 0%. That idle
  Spark allowance is effectively **free extra Codex capacity every 5h/7d** — in
  an ideal world we drain it too, rather than let it reset unused. Routing some
  work to `openai-codex/gpt-5.3-codex-spark` spends the Spark bucket instead of
  the shared main bucket, and (as a fallback) delays the cross to Anthropic.
  - *Wired in as of this revision.* The fast-execution roles lead on
    `gpt-5.3-codex-spark` — at `:xhigh` for the real-work roles
    (`task`/`sonic`/`advisor`) to drain harder and get better output, `:low` for
    the `tiny`/`commit` one-liners — and fall back the instant its bucket 429s,
    so the drain is transparent:
    - OpenAI-led (`ompb`, `ompg`): `task` **and** `sonic`/`advisor`/`tiny`/`commit`
      lead on Spark. `task` falls back to its old terra/luna worker chain (then
      crosses); background falls back to `nano`.
    - Anthropic-led (`omps`, `ompc`, `ompx`): the background roles lead on Spark.
      Because Spark is itself a Codex model, they fall back to `nano` (a regular
      Codex rung) before crossing to `haiku` — drain the free Spark bucket, then
      cheap main-Codex, then the Claude plan only if OpenAI is fully down.
      `task` stays pool-pure on Claude — draining the free Codex bucket for
      trivia is worth a small pool impurity, but the substantial worker is not.
  - *Deliberately kept off Spark:* `smol`/scout (exploration can exceed the 128K
    window — truncation risk), every thinking role (`plan`/`slow`/`reviewer`/
    `designer`/`default` — Spark is fast, not a reasoner), and all of `ompf`
    (its no-fallback contract means an exhausted Spark bucket would hard-fail).
  - *Caveats to watch:* Spark is $1.75/$14 list, so this only "wins" under
    subscription auth where quota, not dollars, is scarce; and a `task` whose
    context exceeds 128K relies on Spark erroring (not silently truncating) for
    the fallback to engage.
- **Anthropic's Fable is the mirror image — a separate but *scarce* bucket.**
  Fable draws from its own 7-day sub-limit that is frequently the binding
  Anthropic constraint (often 80%+ while the general Claude 5h/7d bucket sits
  much lower). So Fable-heavy profiles (`ompf`, and `ompc`'s default/plan/slow)
  burn that scarce bucket fastest. When the picker panel flags Fable **tight**,
  lean Sonnet/Opus (general bucket) or an OpenAI-led profile.

The picker panel is exactly there to make this a glance-and-pick decision: see
which bucket is tight before you choose a harness.

## The palette

A fast mixed profile, two everyday profiles per pool (cheap and hard), two
specialists, and a base layer. `code` (see [below](#the-code-picker)) is an
umbrella picker over all of them, grouped mixed → gpt-led → claude-led →
specialists and sorted faster → smarter within each.

| | OpenAI-led (Codex meter) | Anthropic-led (Claude meter) |
| --- | --- | --- |
| **fast (mixed)** | `ompz` — fastest tiers of both providers, low thinking, light fallbacks | *(uses both meters)* |
| **cheap** | `ompb` — routine work, nano background, features off | `omps` — everyday value, Sonnet-led, features on |
| **hard** | `ompg` — Sol drives, Claude is the net | `ompc` — Fable drives, GPT is the net |
| **specialist** | — | `ompf` deterministic Fable · `ompx` huge-context (1M) |

Base layer: [`defaults.yml`](defaults.yml) underlies every launcher and is the
entire model map for `ompu` (untrusted repos), whose real differences are
posture (approvals, secrets, isolation), not models.

## Per-profile rationale

Routing detail is in the YAML; each file's header comment states its thesis.
Summary:

- **`ompz`** ([fast-mixed.yml](presets/fast-mixed.yml)) — speed-first, mixed. The
  fastest competent tiers across both providers at low thinking (Luna/nano/Spark
  + Sonnet/Haiku), with light single-hop fallbacks (cross to Haiku, or a cheap
  sibling). Nothing reaches for Sol/Fable/Opus; plan/slow get one capped step up.
  For snappy interactive work where latency beats depth. Note: unlike the
  drain-the-bucket profiles, Spark runs at `:low` here — this profile optimises
  for latency, not for emptying the Spark quota.
- **`ompb`** ([budget.yml](presets/budget.yml)) — minimum burn. Terra/Luna lead
  the interactive and deliberative roles at low thinking. `task` and the
  background roles lead on Spark to drain the free Codex bucket, falling back to
  their old rungs (`task`→terra→luna→Haiku; background→nano). `default` keeps a
  Luna→Sonnet net; the deliberative roles keep none. Advisor, branch summaries,
  and autolearn off.
- **`omps`** ([sonnet-value.yml](presets/sonnet-value.yml)) — the profile `ompb`
  can't be: cheap *and* premium-adjacent. Sonnet leads everything but plan/slow,
  where low-volume Opus is worth the leverage. Chains cross to Terra/Luna
  (Sonnet's price-twins). All-Anthropic pool for the substantive roles; features
  stay on. Background leads on Spark (free Codex bucket) → Haiku, so trivia
  doesn't spend the Claude plan. Doubles as the "Codex credits are spent"
  everyday driver.
- **`ompg`** ([gpt56.yml](presets/gpt56.yml)) — difficult work, GPT-led. Every
  substantive role runs GPT → GPT → Claude: a sibling absorbs a single-model
  overload for free, then the last hop crosses to Fable/Opus so a full OpenAI
  outage still lands on a live vendor. `task` and the background roles lead on
  Spark (fast execution, draining the free Codex bucket), falling back to the
  terra/luna chain and nano respectively.
- **`ompc`** ([claude-hard.yml](presets/claude-hard.yml)) — `ompg`'s mirror,
  opposite pool. Fable drives, Opus is the sibling (and leads review, its
  strength), Sonnet/Haiku carry workers, every chain reaches back to Sol/Terra.
  Load it when OpenAI is dark or the Codex meter is empty and the work is still
  hard. Unlike `ompf`, nothing strands on a single model. Background leads on
  Spark (free Codex bucket) → Haiku.
- **`ompf`** ([fable-primary.yml](presets/fable-primary.yml)) — Fable-first,
  deterministic. Retry and server-side fallback **off**: the contract is "give
  me Fable, predictably, and never silently swap." Resilience is `ompc`'s job
  now, so `ompf` stays pure. Background on cheap OpenAI rungs so Fable isn't
  burned on commit messages (the mixed pool is the accepted price of
  determinism).
- **`ompx`** ([context-1m.yml](presets/context-1m.yml)) — work beyond the 372K
  ceiling of the 5.6 family. Anthropic owns 1M, so Fable/Opus/Sonnet lead;
  `gpt-5.4` is the only OpenAI 1M card, used as the universal cross-net and the
  librarian lead (putting the read-everything role on the Codex meter splits the
  burn). **Invariant: a fallback never shrinks the window mid-job** on a
  substantive role. Background trivia never sees the big context, so it leads on
  Spark (free Codex bucket) → Haiku.

## The `code` picker

`code` resolves a selector (menu number, launcher name, alias like `plain`, or a
single suffix letter — `code ompg`, `code 4`, `code z`) and execs the matching
launcher, forwarding every remaining argument. If the first argument is not a
known profile, the picker opens and then forwards all arguments to the choice,
so `code --resume` picks first, then resumes. `code --list` / `code --help` are
non-interactive. It is a thin wrapper: the chosen launcher applies its own
managed overlays unchanged.

With no (profile) argument it opens an `fzf` picker — arrow keys + Enter, fuzzy
filtering — with a truecolor list, Nerd Font provider glyphs, and soft group
labels (mixed → gpt-led → claude-led → specialists, faster → smarter within).
The preview pane shows the highlighted profile's detail and its live routing,
with model names coloured by provider (blue/orange) and shaded by thinking level
(dim `low` → bright `xhigh`). The `omp usage` panel sits in a bottom footer
(best-effort, ~2s from cache, bounded; `code --no-usage` skips it): each quota
window shows a green→red bar, `N% used`, and `free`/`tight` tags, so you see
which meter has room before you pick (see [Separate rate
buckets](#separate-rate-buckets--an-underused-lever)). It falls back to a plain
typed menu when `fzf` is absent or `CODE_NO_FZF=1`.

It is defined in [`pkgs/omp-configured/default.nix`](../pkgs/omp-configured/default.nix)
from a single `paletteProfiles` list that also feeds the `omph` route view, so
the picker, the routing page, and the launchers never drift.

## Changing the routing

1. Edit [`defaults.yml`](defaults.yml) (base map) or the relevant
   [`presets/`](presets/) file. Model selectors are `provider/model:thinking`,
   e.g. `openai-codex/gpt-5.6-terra:medium`.
2. Verify the selector and thinking level exist: `omp models --json`. A bad ID
   or level is a *runtime* error, not a build failure — the YAML is not
   validated against the registry at build time.
3. Run `zconf` (`atyrode apply`), then `omph` to see the rendered routing.
4. If you add or rename a launcher, update `paletteProfiles` in
   `pkgs/omp-configured/default.nix`, the preset set in
   `modules/home/agent-tools.nix`, and the assertions in
   `checks/agent-tools.nix` (the bin inventory and `omph` descriptions are
   pinned).

## Revisit triggers

- **The nano bet.** `commit`/`tiny` and all of `ompb`'s background run on
  `gpt-5.4-nano` — the ~5× saving is the biggest here, and the only quality
  gamble. If commit messages or labels degrade, the revert is one line back to
  Luna per role. Worth a week's trial before judging.
- **Sonnet's price cliff.** `omps` is built on introductory pricing ($2/$10). On
  **2026-08-31** it steps to $3/$15 — dearer than Terra. The profile stays
  coherent (pool separation still justifies it), but the "cheapest
  premium-adjacent" pitch expires; recheck against Terra then.
- **`ompx` librarian pool-split.** `gpt-5.4` leads `ompx`'s librarian to spread
  the read-everything burn onto the Codex meter and give the 1M card a real job.
  If a previous-gen model leading a role feels wrong, the alternative is
  all-Anthropic (Sonnet lead, `gpt-5.4` as net only).
- **How hard to push Spark.** Spark now leads the fast-execution roles (see
  [Separate rate buckets](#separate-rate-buckets--an-underused-lever)). Two dials
  remain: whether `task` should also lead on Spark in the Anthropic-led profiles
  (more drain, but the substantial worker leaves the Claude pool), and whether
  the background `:low` output holds up in practice. If a role degrades, revert
  it to its cheap rung — one line per role. Watch the Spark 5h/7d bars in the
  `code` panel: if they never approach full, push more roles onto Spark; if they
  saturate early and fall back constantly, ease off.
- **Model registry churn.** New tiers or price changes can invalidate a lead or
  a price-twin pairing. The presets are policy, not pricing data — re-derive from
  `omp models` when the catalog moves.
