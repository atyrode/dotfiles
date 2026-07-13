# Agent tools

OMP, model presets, agents, rules, and generic
skills are part of the Home Manager profile. `zconf` is the only
installation or activation command; there is no separate plugin or skill sync.

## Ownership

Nix owns:

- the pinned OMP binary and generated Zsh completion;
- the managed OMP defaults, enforced policy, and model presets;
- the curated plain-omp seed and its drift-aware activation step;
- the pinned bundled agents, global generic skills, and managed-settings guard
  extension;
- the `omp`, `ompz`, `ompb`, `omps`, `ompg`, `ompc`, `ompf`, `ompx`, and
  restricted `ompu` launchers, plus the `omph` routing view and the `code`
  launcher picker; and
- Claude Code's user-scope operator policy: the deployed `~/.claude/CLAUDE.md`
  instructions and `~/.claude/settings.json` permission rules; and
- mise itself, with no globally declared mise tools.

OMP continues to own mutable runtime data such as authentication,
sessions, caches, onboarding state, and machine-local UI state. Secrets never
belong in this repository or the Nix store.

This subsystem deliberately owns neither a `pi` executable nor a `.pi`
mutable-state namespace. The bounded Pi experiment in #29 may therefore install
alongside OMP without an executable collision, shared authentication/session
state, or any parity requirement. The package check asserts the exact managed
OMP binary set — nine launchers plus the `omph` routing view and the `code`
picker — and verifies that an OMP clean-home startup does not create `.pi`
state. Security boundaries and the untrusted-project launcher are
documented in [Agent security](agent-security.md).

Agents, rules, and the settings guard are assembled into
a read-only OMP extension-package root in the Nix store and injected explicitly
by every managed session. They are not copied into OMP's mutable agent
directory, so named profiles and custom `PI_CODING_AGENT_DIR` roots receive the
same platform assets without sharing authentication, sessions, or caches.

The package overlay lives in `flake.nix`, reusable package derivations live in
`pkgs/`, and Home Manager deployment lives in
`modules/home/agent-tools.nix`. On Linux, the OMP package preserves upstream's
binary unchanged and launches it through Nix's dynamic loader instead of
rewriting the Bun executable with `patchelf`.

## OMP launchers

The launchers form a palette: a fast mixed profile, two everyday profiles per
subscription pool (cheap and hard), specialists, and a base layer. The `code`
picker (see below) groups them softly — mixed, then gpt-led, then claude-led,
then specialists — sorted faster → smarter within each group. The design
rationale — the model catalog, the fallback principles, and the per-profile
reasoning — lives in [`omp/PROFILES.md`](../omp/PROFILES.md).

| Command | Intended use | Primary route |
| --- | --- | --- |
| `omp` | Mutable daily driver; user-owned configuration | Whatever the operator's own OMP config selects; unmanaged apart from the blocked `update` |
| `ompz` | Mixed · speed — latency over depth | Luna/Spark + Sonnet/Haiku at low thinking, light single-hop crosses; nothing reaches for Sol/Fable/Opus |
| `ompn` | Mixed · regular — balanced daily driver | Claude leads judgment, GPT leads execution, at medium thinking; full same-bucket-then-cross redundancy |
| `ompm` | Mixed · smart — hardest work, best per task | Sol on GPT-strength roles, Fable/Opus on Claude-strength ones (design/plan/review); full redundancy |
| `ompl` | GPT · speed — fast Codex | Luna at low thinking, `task` drains Spark, single fast hops to Haiku |
| `ompb` | GPT · regular — routine Codex work | Terra at medium thinking, kept off premium tiers (Luna/Terra + Haiku/Sonnet, never Sol/Opus); background drains Spark |
| `ompg` | GPT · smart — difficult work, GPT-led | Sol drives; a GPT sibling absorbs a blip, then Claude is the net |
| `ompo` | GPT-only — never crosses to Anthropic | Sol → Terra → Luna internal redundancy; background drains Spark; keeps every token on Codex |
| `ompk` | Claude · speed — fast Claude | Haiku at low thinking, background drains Spark, single fast hops to Luna |
| `omps` | Claude · regular — everyday value | Sonnet 5 leads; Opus for plan/slow; background on Spark → Haiku |
| `ompc` | Claude · smart — difficult work, Claude-led | Fable drives; Opus absorbs a blip, then GPT is the net (ompg's mirror) |
| `ompe` | Claude-only — never crosses to OpenAI | Opus → Sonnet → Haiku internal redundancy, no Spark/Fable; keeps every token on the Claude plan |
| `ompf` | Fable-first work with predictable routing | Fable for primary/deliberative roles, with automatic fallback disabled |
| `ompx` | Huge-context (1M) work | Anthropic's 1M line (Fable/Opus/Sonnet) leads and is the only redundancy; no OpenAI 1M on a ChatGPT account, so no cross-net |
| `ompu` | Deliberately untrusted repositories | Dedicated state, sanitized credentials, restricted integrations, and isolated writing tasks |

Each profile commits to one subscription pool for its lead and substantive
roles, so switching launchers also switches which meter burns (Codex credits vs
the Claude plan); the fallback net is the other pool. The exception is the
fast-execution and background roles, which lead on `gpt-5.3-codex-spark` — its
5h/7d Codex quota is a separate, normally-idle bucket, so draining it costs
nothing on the main meters, and each role falls back to the per-pool cheap rung
(Luna or Haiku) the moment that bucket is exhausted. See
[`omp/PROFILES.md`](../omp/PROFILES.md) for the full rationale.

Plain `omp` executes upstream OMP directly: no extension, defaults, preset, or
policy overlay is injected, so its models, approvals, and interface belong to
the operator's mutable configuration and can change on the fly. Only
`omp update` is blocked, so nothing shadows the Nix-pinned binary. Its
starting point is not empty, though: activation seeds the curated defaults
from `omp/plain-seed.yml` into the writable configuration with local edits
always winning; see [Seeded plain-omp defaults](#seeded-plain-omp-defaults).

The managed defaults use Sol for interactive daily work, keep cheap, fast roles
on Luna, keep the text-trivial `commit`/`tiny` roles on GPT-5.6-luna, and
reserve Fable/Opus for planning and the deliberative fallback tier. Fallback
chains follow one rule: try a same-provider sibling first (it rules out a single
model at capacity for free), then make the last, load-bearing hop cross to the
other provider; trivial background roles carry no chain at all. The presets are
policy, not provider pricing data; revisit the routes when model quality or
pricing changes.

The balanced routing rationale is:

| Role or role group | Capability and intended use | Thinking | Cost posture and fallback rationale |
| --- | --- | --- | --- |
| `default` | Interactive daily work on Sol | Medium | Sol is the user-selected default; a Terra sibling absorbs a Sol blip, then Sonnet is the cross-provider net |
| `task` | General implementation on Terra | Medium | Mid-cost worker; a Luna sibling first, then Sonnet crosses providers |
| `librarian` | Repository and documentation research on Terra | Medium | A Luna sibling keeps the read-heavy role cheap, then Sonnet crosses for depth |
| `smol`, `sonic` | Fast lookup and naming on Luna | Minimal–low | Cheapest recurring work; no fallback chain — a blip is harmless and crossing them is wasteful |
| `advisor` | Per-turn peer review — a judgment role, not a drain target | Tier-dependent | Base is a budget Haiku; per launcher it follows the tiered policy — Sonnet 5 on `smart` (Terra on `gpt-only`), Haiku on `regular`, **off** on `speed`/`budget` and `ompx`. See [PROFILES.md](../omp/PROFILES.md) principle 7 |
| `tiny`, `commit` | Labels and commit messages on GPT-5.6-luna | Low | The cheapest supported Codex rung for text-trivial, always-on work; no fallback chain |
| `designer` | Product and interface design on Sonnet | Medium | Crosses straight to Terra, Sonnet's price-twin (Sonnet has no lateral Anthropic sibling) |
| `reviewer` | High-scrutiny review on Sonnet | High | Higher-cost quality gate; escalates to Opus, then Sol, if the primary is unavailable |
| `plan` | Architecture and planning on Fable | High | Premium reasoning is intentional for decisions with broad downstream impact; Opus then Sol are the escape routes |
| `slow` | Hard debugging and deliberate reasoning on Sol | Xhigh | Expensive OpenAI reasoning is reserved for difficult failures; a Terra sibling, then Opus crosses providers |

The bundled `scout` agent (upstream's rename of `explore`) is deliberately not
pinned: its frontmatter declares the `smol` model role, so repository
exploration follows the smol route and its fallback chain without a separate
entry that could go stale.

`omph` prints the effective routing as a terminal page: for each preset
launcher, every role's primary model, its fallback chain, and any diverging
task-agent override, with agent-backed roles marked. The page is rendered at
package build time from the same defaults and preset files, so it always
matches the deployed configuration. Provider is encoded as a colorblind-safe
blue/orange pair; piped or `NO_COLOR` output falls back to plain text.

`code` is an umbrella picker over the whole palette. With no arguments it opens
an `fzf` picker: arrow keys and Enter to select (type to filter), a truecolor
list with Nerd Font provider glyphs and soft group labels (mixed / gpt-led /
claude-led / specialists), the `omp usage` panel in a bottom footer (per-window
`N% used` with green→red gradient bars, `free` on an idle bucket and `tight` at
≥80%), and a preview pane showing the highlighted profile's detail and its live
role → model routing — with model names coloured by provider (blue/orange) and
brightness scaled by thinking level. It falls back to a typed menu when `fzf` is
unavailable or `CODE_NO_FZF=1`, and `code --no-usage` skips the usage fetch. A
selector can also be passed directly by name, menu number, or single suffix
letter (`code ompg`, `code 4`, `code z`), with any remaining arguments forwarded
to the chosen launcher. If the first argument is not a known profile, the picker
opens and then forwards every argument to the choice, so `code --resume` picks a
profile first, then resumes. `code --list` and `code --help` are
non-interactive. It is a thin wrapper: the chosen launcher receives the
arguments unchanged and applies its own managed overlays.

`omp/defaults.yml` is the authoritative role map and fallback-chain definition;
the preset files intentionally change parts of this table for the budget
(`ompb`), Sonnet-value (`omps`), GPT-led (`ompg`), Claude-led (`ompc`),
Fable-first (`ompf`), and huge-context (`ompx`) sessions.

Managed preset launchers load configuration in this order:

1. OMP's writable machine config at `~/.omp/agent/config.yml`, with
   `config.yaml` accepted as OMP's legacy fallback when `config.yml` is absent;
2. the Nix-managed portable defaults;
3. native project configuration from `<cwd>/.omp/settings.json` followed by
   `<cwd>/.omp/config.yml`, reapplied after the defaults so a repository can
   specialize non-security settings;
4. optional machine-local overrides at `~/.config/omp/local.yml`;
5. the selected quick-command preset or presets;
6. one-shot `--config` overlays, in command-line order;
7. the Nix-managed enforced policy; and
8. explicit runtime flags such as `--model` or `--approval-mode`.

Later layers win. The enforced policy fixes trusted-machine yolo approvals for
workspace edits, shell/eval, browser, task spawning, and GitHub capabilities,
plus secret obfuscation and automatic task isolation with patch merging.
Machine, project, preset, and one-shot config files cannot change those
controls. `omp acp` receives the same layers in the same order, with the
overlays placed after the `acp` subcommand as required by OMP's parser.

Managed preset launchers are unattended trusted-machine profiles. Explicit
`--yolo`, `--auto-approve`, and `--approval-mode yolo` flags remain supported
for compatibility, but do not grant those sessions additional tool approval.
Plain `omp` carries none of these layers: its approval posture is whatever the
operator's mutable configuration selects. Use `ompu` for deliberately
untrusted repositories.

OMP maintenance subcommands are passed directly to OMP because their parsers do
not consistently accept interactive launch flags. Preset launchers preserve
that passthrough instead of prepending their preset to a maintenance command,
and their `setup` warns that it writes lower-priority machine state and points
back to the effective diagnostic.
`omp update` is refused so it cannot shadow the
Nix-managed version.

When launched from `$HOME` without `--cwd` or `--allow-home`, the wrapper
mirrors OMP's safety chdir (`$HOME/tmp`, `/tmp`, `/var/tmp`, then the platform
temporary directory) before resolving project layers. Relative one-shot
`--config` paths are resolved from that effective project directory.

Use `omp config managed --json` to inspect the active profile and state path,
ordered source paths, ownership, and effective managed values for the selected
launcher. The diagnostic includes the writable machine layer, both native
project settings files, one-shot overlays, and supported runtime overrides,
but filters output to Nix-owned keys so credentials and unrelated private
settings are never printed. OMP-compatible migrations are applied to legacy
managed values before the diagnostic is merged. `PI_CODING_AGENT_DIR`,
`PI_CONFIG_DIR`, named profiles, the effective project directory, and the
`config.yml`/`config.yaml` fallback are reflected in the report.

`omp config set` and `omp config reset` refuse keys supplied by the managed
defaults, selected presets, or enforced policy, including parent/child paths
that overlap a managed key. `omp config get` likewise refuses managed keys
because upstream's command reads only writable machine state; `omp config list`
prints an explicit warning about that limitation. Edit the repository source,
or use `~/.config/omp/local.yml` for a machine-only override of a default.
Local overrides cannot weaken enforced policy.

The managed extension intercepts the normal `/settings` path before OMP opens
its in-session settings UI and explains the supported edit paths. It also
watches OMP's writable config and restores Nix-owned paths if another UI path,
including follow-up submission or setup, tries to persist them; unrelated
machine edits are retained and the session receives a warning. Managed root
sessions refuse `--no-extensions`, because upstream would otherwise disable
this guard together with the managed agents and rules. Use
`omp config managed`, the machine-local file, or the repository sources
instead.

The readable managed copies are linked under `~/.config/omp/`. Edit their
sources in this repository instead of editing the links.

## Seeded plain-omp defaults

`omp/plain-seed.yml` holds the operator's agreed defaults for plain `omp` —
the trusted-machine guardrails (secret obfuscation, automatic task isolation),
the bundled-role model map and fallback chains, and interface preferences. It
is deliberately not a managed layer: OMP's `--config` overlays always outrank
the writable machine configuration, so a "defaults that lose to local edits"
layer cannot exist at launch time. Instead, `atyrode-omp-seed apply` runs
during activation (after the legacy migration) and three-way merges the seed
into `~/.omp/agent/config.yml` against the last-applied seed recorded in
`~/.local/state/atyrode/omp-plain-seed/`:

- a key the operator never touched is written and later follows repository
  updates;
- a key the operator changed or deleted is left alone and reported as drift,
  including across later seed updates;
- unmanaged keys are never modified.

`atyrode apply` prints the drift report after a successful activation and, on
a terminal, offers a per-key keep-or-reset review; `atyrode-omp-seed status
[--json]` and `atyrode-omp-seed resolve [--reset-all]` are available directly.
This keeps the tinkering loop intact: change anything on the fly in plain
`omp`, then either adopt the change into `omp/plain-seed.yml` or reset it at
the next apply. `AGENT_TOOLS_DRY_RUN=1` (or a Home Manager dry run) prints the
plan without writing.

The seed may overlap keys the managed launchers own: managed sessions layer
`defaults.yml` and `policy.yml` above the machine configuration, so seeded
values never change managed behavior, and the flake check asserts that seeded
values agree with the enforced policy wherever they overlap it. One caveat:
the managed-settings guard restores managed paths in the writable file to
their session-start state, so reseeding an overlapping key while a managed
session is running can be reverted and will then surface as drift — resolve
it at the next apply, or apply while managed sessions are closed.

Known, accepted limits: the writable configuration is machine-formatted (OMP
itself rewrites it without comments, and so does the seeder); a write aborts
rather than merges when the file changed between read and write (rerun to
pick up the new state); a seed path blocked by a local scalar reports drift
instead of writing; and on the first activation of a legacy machine the v2
migration removes managed-key copies before seeding writes the repository
values — the original file survives in the migration backup receipt.
`ATYRODE_SEED_REVIEW=0` suppresses the interactive apply-time review for
pty-backed automation.

## Skills

Generic, cross-project skills belong in `agents/skills/` and Home Manager links
them to `~/.agents/skills`. OMP discovers `.agent/skills` and `.agents/skills`
from the home directory and while walking up a project tree.

Project-specific skills should be committed with the project:

```text
project/
└── .agents/
    └── skills/
        └── project-workflow/
            └── SKILL.md
```

This keeps project facts, commands, and conventions versioned with the code
that needs them while still making them available automatically when OMP runs
inside that project. The same ownership rule applies to project-specific
`.agents/AGENTS.md`, rules, prompts, and commands.

Existing project-specific auto-learned skills under
`~/.omp/agent/managed-skills` are intentionally left writable and global for
now. Move them into their owning repositories one at a time after removing
machine-specific assumptions; the first migration only relocates the generic
`ts-react-dead-code-sweep` skill.

## First activation

Before Home Manager checks link targets, the activation hook examines legacy
paths. Conflicting regular files or symlinks at the OMP and Herdr binary paths,
the standalone Bigpowers plugin tree, managed agents, managed extensions,
presets, rules, and the old generic skill are moved into a pending migration
receipt. The exact temporary `mcp.json` denylist previously used for
`bigpowers-mcp` is also retired; MCP configurations containing any custom
servers or settings are left untouched. Legacy binaries are never executed
during detection:

```text
~/.local/state/atyrode/agent-tools-migration/migration-v2.pending/
├── receipt.tsv
├── backup/
└── work/
```

The existing writable OMP `config.yml` or fallback `config.yaml` is copied into
the same backup and only the keys now owned by Nix are removed. A dual-file
state or ambiguous legacy scalar custom theme is refused for manual review.
Onboarding version, consent, unknown keys, and other machine-local values remain
writable. Invalid YAML, unsupported file types at managed binary paths, a mixed
plugin tree, or a live path that collides with an existing backup stop
activation instead of guessing. An interrupted activation reuses the pending
receipt and never creates a second backup. Once
Home Manager has installed the packages and selected the new generation, a
finalizer verifies every retired path and transformed config, then atomically
renames the pending directory to `migration-v2.complete`; the backups remain
inside it for manual recovery. Existing installations with the former
`migration-v2.complete` marker
file remain recognized. A zero-length receipt produced by an earlier blank-home
activation is also recognized only when both its backup and work trees are
empty; retained data, malformed non-empty receipts, and unsafe links still stop
activation for manual review.

Receipts, backup/work directories, lock handling, and same-directory temporary
files are validated so symlinks cannot redirect writes outside the transaction.
The retired plugin cleanup accepts only the exact Bigpowers-only manifest and
known package-manager files; mixed dependencies or any customized root state
are preserved for manual review. Stale `~/.local/bin/omp` and `herdr` symlinks
are backed up even when they target an old Nix store path, preventing them from
shadowing the Home Manager profile.

The migration is idempotent. It never restores backups automatically because
that could overwrite a new user file or a managed Home Manager link; resolve a
reported collision while preserving both copies, then run `zconf` again. Home
Manager dry-runs inspect and print the plan without creating receipts or moving
files.

## Updating

The `update-pins` workflow refreshes the repository-owned binary pins (OMP
and Codex) every six hours: `scripts/update-pins.sh` bumps versions and
hashes, a bot pull request runs the full dispatched CI, and a green run
merges itself. A red run leaves the pull request open for curation — that is
the expected outcome when upstream changes bundled content. The manual flow
below remains valid for hand-driven updates:

1. Update OMP's version, asset names, and hashes in `pkgs/omp/default.nix`
   (or run `scripts/update-pins.sh`).
2. Review model identifiers and routing in `omp/defaults.yml`,
   `omp/presets/`, and `omp/plain-seed.yml`.
3. Run `nix flake check --show-trace`.
4. Apply the profile with `zconf`.

`omp-agents` regenerates the upstream bundled agents from the pinned OMP
binary, and the `omp-agent-references` check asserts that every agent name
referenced by `task.agentModelOverrides`, `task.disabledAgents`, or an
agent-named `retry.fallbackChains` key in the managed defaults and presets
still exists in that unpacked set, so an upstream agent rename or removal
fails the build instead of silently misrouting models.

GitHub Actions runs the same flake checks natively on x86_64 and aarch64 Linux
and aarch64 macOS.
