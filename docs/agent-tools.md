# Agent tools

OMP, the profile generator, agents, rules, and generic
skills are part of the Home Manager profile. `zconf` is the only
installation or activation command; there is no separate plugin or skill sync.

## Ownership

Nix owns:

- the pinned OMP binary and generated Zsh completion;
- the managed OMP defaults, enforced policy, and model catalog;
- the curated plain-omp seed and its drift-aware activation step;
- the pinned bundled agents, global generic skills, managed-settings guard
  extension, and vault-usage footer extension;
- the `omp` passthrough, the `omp-managed` managed-layering launcher, the
  restricted `ompu` launcher, and the `code` profile generator; and
- Claude Code's user-scope operator policy: the deployed `~/.claude/CLAUDE.md`
  instructions and `~/.claude/settings.json` permission rules; and
- mise itself, with no globally declared mise tools.

OMP continues to own mutable runtime data such as authentication,
sessions, caches, onboarding state, and machine-local UI state. Secrets never
belong in this repository or the Nix store.

This subsystem deliberately owns neither a `pi` executable nor a `.pi`
mutable-state namespace. The bounded Pi experiment in #29 may therefore install
alongside OMP without an executable collision, shared authentication/session
state, or any parity requirement. Security boundaries and the
untrusted-project launcher are
documented in [Agent security](agent-security.md). The package check asserts
the exact managed OMP binary set — the `omp`, `omp-managed`, and `ompu`
launchers plus the `code` generator — and verifies that an OMP clean-home
startup does not create `.pi` state.

Agents, rules, the settings guard, and the vault-usage footer are assembled
into a read-only OMP extension-package root in the Nix store and injected
explicitly by every managed session. They are not copied into OMP's mutable
agent directory, so named profiles and custom `PI_CODING_AGENT_DIR` roots
receive the same platform assets without sharing authentication, sessions, or
caches. The vault-usage footer renders one responsive below-editor row for
the launch vault with `code`-parity visuals (cli-kit palette, green→red
gradient bars, `claude`/`codex` display names, `↻︎` reset countdowns with
urgency tinting, `cached <age> ago` staleness): per broker-reported provider
it shows every distinct labeled window (the busiest per label — e.g.
`5h · 7d · 7d fable` for Claude; never an invented aggregate), provider
groups delimited by `│`, the active model's provider first, and a live
minute-granular `refresh in Xm` suffix on healthy rows. When width runs
short it deterministically sheds identity first, then the lowest-priority
windows (exhausted and high-usage windows survive longest), then trailing
providers. `/vault-usage` lists the full window/scope set with a
fetched/next-refresh status line; `/vault-usage refresh` forces a fetch. It
reads only the aggregate usage report, non-secret auth-state booleans, and
the read-only display identity (masked to `x…@domain` at capture, shown
only when the complete row fits) — never credentials, tokens, or raw report
metadata — and it hides itself instead of wrapping on narrow terminals.

The package overlay lives in `flake.nix`, reusable package derivations live in
`pkgs/`, and Home Manager deployment lives in
`modules/home/agent-tools.nix`. On Linux, the OMP package preserves upstream's
binary unchanged and launches it through Nix's dynamic loader instead of
rewriting the Bun executable with `patchelf`.

## OMP commands

Four commands make up the surface. Plain `omp` is the user-owned daily driver;
`omp-managed` is the managed-layering primitive that the generator launches;
`ompu` is the untrusted sandbox; and `code` is the profile generator that ties
them together.

| Command | Intended use | Configuration |
| --- | --- | --- |
| `omp` | Mutable daily driver; user-owned configuration | Whatever the operator's own OMP config selects; unmanaged apart from the blocked `update` and profile-aware resume lookup |
| `omp-managed` | The managed launch target: platform extensions, managed defaults, and enforced policy over a one-shot `--config`, with no preset overlay | Managed defaults and policy, plus the generated `--config` the generator passes |
| `ompu` | Deliberately untrusted repositories | Dedicated state, sanitized credentials, restricted integrations, and isolated writing tasks |
| `code` | The profile generator TUI (see below) | Always launches through `omp-managed`: Enter passes the generated profile as a one-shot `--config`; `m` runs the managed defaults with no overlay |

For discoverability beyond the wrapper contract, see the versioned
[OMP feature wiki](omp/README.md). Its CLI tables describe plain upstream OMP;
this document remains authoritative for `code`, `omp-managed`, and `ompu`.

Plain `omp` executes upstream OMP directly: no extension, defaults, or policy
overlay is injected, so its models, approvals, and interface belong to the
operator's mutable configuration and can change on the fly. `omp update` is
blocked so nothing shadows the Nix-pinned binary. For a UUID or UUID-prefix
passed to `--resume`, the launcher searches the default and named-profile
session roots and injects the sole matching profile; explicit profile/state
selection always wins, and ambiguous matches require `--profile`. This repairs
upstream's profile-free end-of-session resume hint without changing ordinary
launches. Activation seeds the curated defaults from `omp/plain-seed.yml` into
the writable configuration with local edits always winning; see
[Seeded plain-omp defaults](#seeded-plain-omp-defaults).

`omp-managed` is the managed launcher with no profile of its own. It layers the
platform extensions, the managed defaults, and the enforced policy over a
one-shot `--config`, and is the launch target the generator uses; it carries no
hand-curated preset. The managed defaults use Sol for interactive daily work,
keep cheap, fast roles on Luna, keep the text-trivial `commit`/`tiny` roles on
GPT-5.6-luna, and reserve Fable/Opus for planning and the deliberative fallback
tier. Fallback chains follow one rule: try a same-provider sibling first (it
rules out a single model at capacity for free), then make the last, load-bearing
hop cross to the other provider; trivial background roles carry no chain at all.
The fast-execution and background roles lead on `gpt-5.3-codex-spark` — its
5h/7d Codex quota is a separate, normally-idle bucket, so draining it costs
nothing on the main meters, and each role falls back to the per-pool cheap rung
(Luna or Haiku) the moment that bucket is exhausted. The managed defaults are
policy, not provider pricing data; revisit the routes when model quality or
pricing changes.

The balanced routing rationale is:

| Role or role group | Capability and intended use | Thinking | Cost posture and fallback rationale |
| --- | --- | --- | --- |
| `default` | Interactive daily work on Sol | Medium | Sol is the user-selected default; a Terra sibling absorbs a Sol blip, then Sonnet is the cross-provider net |
| `task` | General implementation on Terra | Medium | Mid-cost worker; a Luna sibling first, then Sonnet crosses providers |
| `librarian` | Repository and documentation research on Terra | Medium | A Luna sibling keeps the read-heavy role cheap, then Sonnet crosses for depth |
| `smol`, `sonic` | Fast lookup and naming on Luna | Minimal–low | Cheapest recurring work; no fallback chain — a blip is harmless and crossing them is wasteful |
| `advisor` | Per-turn peer review — a judgment role, not a drain target | Tier-dependent | Base is a budget Haiku; the generator's advisor dial can raise it (Sonnet 5), leave it, or turn it **off** for a generated profile |
| `tiny`, `commit` | Labels and commit messages on GPT-5.6-luna | Low | The cheapest supported Codex rung for text-trivial, always-on work; no fallback chain |
| `designer` | Product and interface design on Sonnet | Medium | Crosses straight to Terra, Sonnet's price-twin (Sonnet has no lateral Anthropic sibling) |
| `reviewer` | High-scrutiny review on Sonnet | High | Higher-cost quality gate; escalates to Opus, then Sol, if the primary is unavailable |
| `plan` | Architecture and planning on Fable | High | Premium reasoning is intentional for decisions with broad downstream impact; Opus then Sol are the escape routes |
| `slow` | Hard debugging and deliberate reasoning on Sol | Xhigh | Expensive OpenAI reasoning is reserved for difficult failures; a Terra sibling, then Opus crosses providers |

The bundled `scout` agent (upstream's rename of `explore`) is deliberately not
pinned: its frontmatter declares the `smol` model role, so repository
exploration follows the smol route and its fallback chain without a separate
entry that could go stale.

`code` is the profile generator. It opens a Bubble Tea TUI with a
prompt→profile classifier running on the resident Nix-managed ollama daemon
(loopback HTTP). You type a prompt and/or adjust the facet dials (lane, model
tier, thinking, spark, fable — with fable's manual-only "main" sub-dial that
promotes it to the default agent), and a preview pane shows the resulting role →
model routing — model names coloured by provider (blue/orange) and brightness
scaled by thinking level — above the `omp usage` panel (per-window `N% used`
with green→red gradient bars, `free` on an idle bucket and `tight` at ≥80%).

The usage widget names the active authentication vault. Press **`a`** to cycle
enabled vaults. Press **`v`** for the full-screen vault manager. Its compact
vault rows never duplicate quota data: the highlighted row drives the same full
Usage panel shown by the generator, including provider-only headings,
broker-reported account lists, and Codex-before-Claude ordering. Arrow keys
retarget that detail without selecting the vault. The generator's **`s`** Usage
visibility state transfers into the manager, where **`s`** toggles it too.
If restoring Usage would make the current composition too small, **`s`** opens
Usage full-screen immediately; closing it restores the exact prior Generator
and Routing composition rather than exposing a different panel.
Configured aliases are never presented as authenticated accounts. **Space**
enables or disables the highlighted vault, **Enter** selects it, and **`r`**
refreshes all summaries. The first manifest entry is the non-disableable
fallback. Selection and disabled state persist under the XDG state directory.

At startup, `code` fills a per-vault usage cache in the background. Cycling or
selecting a vault restores its own snapshot, refresh deadline, stale warning,
and in-flight indicator immediately instead of issuing another request. The
active vault refreshes when its five-minute deadline expires; **`r`** remains
the explicit whole-manager refresh. Cached data stays visible while refreshing.
When a retained Fable value is older than the latest response, its label reports
relative age (for example, `cached 4m ago`) rather than a wall-clock timestamp.

Vault definitions are machine-local, not repository data. Put a mode-0600 JSON
array at `$XDG_CONFIG_HOME/atyrode/code-auth-vaults.json`; each entry supplies a
display label, stable id and backing OMP profile, loopback broker URL, token
file, and snapshot cache. In the manager, **`n`** creates an empty vault and
**`e`** changes only the highlighted vault's display label. Enter commits the
text prompt and Escape cancels it. Creation derives a collision-safe id/profile,
unused loopback port, and XDG state/cache paths; it never creates or reads
credentials. A `CODE_AUTH_VAULTS` raw JSON override is intentionally read-only
because it has no safe machine-local persistence target.

The generic Home Manager supervisor validates the manifest and starts one
broker process per entry. It watches atomic content changes and automatically
reconciles all children after a valid edit; an invalid replacement leaves the
current brokers running. No Home Manager apply or manual service restart is
needed.

Usage and identity normally remain broker-sourced. OMP v17's broker aggregate
can omit the Anthropic Fable limit even when that same vault profile returns it.
Only when Fable is absent, `code` performs a provider-scoped, read-only usage
query against that vault's backing profile with ambient broker routing removed,
then appends only the missing Fable limit. Broker identities, Codex usage, and
all other limits remain authoritative.

Fable is different from the shared 5-hour and 7-day windows: OMP learns that
model-family limit from rate-limit headers observed during Claude requests.
With trusted launches consolidated onto shared client profile `default`, a
broker vault's backing profile can retain the correct credential identity while
no longer receiving new header observations. In that state live OMP and broker
reports for that backing profile legitimately contain only 5-hour/7-day data;
`code` must show Fable unavailable rather than invent a current value. Historical
records remain evidence that the account previously exposed the window, not a
safe source for a live quota.

Each backing OMP profile isolates provider credentials. Every trusted `code`
launch still forces shared client profile `default`; sessions, resume history,
settings, generated configuration, memory, and ordinary caches therefore do
not split when the vault changes. The selected vault supplies only
`OMP_AUTH_BROKER_*`. The `u` sandbox remains on its fixed,
credential-sanitized `untrusted` profile.

Broker bearer tokens stay in mutable mode-0600 files outside the Nix store.
The manager reads the broker's redacted snapshot to show which accounts are
actually authenticated; it never reads or mutates OMP's credential database.
Press **`c`** or **`o`** to authenticate the highlighted vault with Claude or
Codex. The footer names the provider and immutable backing profile before the
browser handoff starts. Cancelling a handoff is non-fatal, and a
second handoff cannot be queued while one is active.

Managed vault usage comes directly from the broker's read-only aggregate usage
endpoint, so an unrelated provider record cannot invalidate the display.
Anthropic's Fable row is always reserved in the loading skeleton. If a refresh
omits Fable, the last real value remains visible with its cache timestamp; when
no value has ever been observed, the row shows `unavailable` in the same status
column as `idle`, `tight`, and `maxed`.

There are three ways to leave the TUI — every trusted launch goes through
`omp-managed`; plain `omp` is reached by typing `omp` directly, never via
`code`:

- **Enter** always launches the generated routing profile for the current
  facets through `omp-managed` as a one-shot `--config`, with the selected
  vault's broker environment and any typed prompt carried into the shared
  `default` client profile. The generated profile carries
  `task.agentModelOverrides` mirroring its agent-backed roles, so spawned task
  agents follow the generated routing instead of staying pinned to the static
  managed defaults.
- **`m`** runs `omp-managed` with no overlay — the managed defaults — against
  the same selected vault and shared client profile.
- **`u`** opens the untrusted sandbox (`ompu`) for the current context; it never
  inherits a personal authentication vault.

`code --no-usage` (`-U`) skips the usage fetch, and `code --help` (`-h`) prints
help. The full facet grid of profiles is enumerated at package build time by
`generate-profiles.py` from the model catalog in `omp/models.yml`, so the TUI's
preview always matches what a launch would route.

`omp/defaults.yml` is the authoritative role map and fallback-chain definition;
the generator derives every profile from it and the `omp/models.yml` catalog,
adjusting the table by facet (lane, model tier, thinking, spark, fable, and
fable's main sub-dial) rather
than from hand-curated preset files.

`omp-managed` loads configuration in this order:

1. OMP's writable machine config at `~/.omp/agent/config.yml`, with
   `config.yaml` accepted as OMP's legacy fallback when `config.yml` is absent;
2. the Nix-managed portable defaults;
3. native project configuration from `<cwd>/.omp/settings.json` followed by
   `<cwd>/.omp/config.yml`, reapplied after the defaults so a repository can
   specialize non-security settings;
4. optional machine-local overrides at `~/.config/omp/local.yml`;
5. one-shot `--config` overlays, in command-line order — including the profile
   the generator produces;
6. the Nix-managed enforced policy; and
7. explicit runtime flags such as `--model` or `--approval-mode`.

Later layers win. The enforced policy fixes trusted-machine yolo approvals for
workspace edits, shell/eval, browser, task spawning, and GitHub capabilities,
plus secret obfuscation and automatic task isolation with patch merging.
Machine, project, and one-shot config files cannot change those
controls. `omp acp` receives the same layers in the same order, with the
overlays placed after the `acp` subcommand as required by OMP's parser.

`omp-managed` sessions are unattended trusted-machine profiles. Explicit
`--yolo`, `--auto-approve`, and `--approval-mode yolo` flags remain supported
for compatibility, but do not grant those sessions additional tool approval.
Plain `omp` carries none of these layers: its approval posture is whatever the
operator's mutable configuration selects. Use `ompu` for deliberately
untrusted repositories.

OMP maintenance subcommands are passed directly to OMP because their parsers do
not consistently accept interactive launch flags. `omp-managed` preserves
that passthrough instead of prepending its overlays to a maintenance command,
and its `setup` warns that it writes lower-priority machine state and points
back to the effective diagnostic.
`omp update` is refused so it cannot shadow the
Nix-managed version.

When launched from `$HOME` without `--cwd` or `--allow-home`, the wrapper
mirrors OMP's safety chdir (`$HOME/tmp`, `/tmp`, `/var/tmp`, then the platform
temporary directory) before resolving project layers. Relative one-shot
`--config` paths are resolved from that effective project directory.

Use `omp config managed --json` to inspect the active profile and state path,
ordered source paths, ownership, and effective managed values for the managed
session. The diagnostic includes the writable machine layer, both native
project settings files, one-shot overlays, and supported runtime overrides,
but filters output to Nix-owned keys so credentials and unrelated private
settings are never printed. OMP-compatible migrations are applied to legacy
managed values before the diagnostic is merged. `PI_CODING_AGENT_DIR`,
`PI_CONFIG_DIR`, named profiles, the effective project directory, and the
`config.yml`/`config.yaml` fallback are reflected in the report.

`omp config set` and `omp config reset` refuse keys supplied by the managed
defaults or enforced policy, including parent/child paths
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
`~/.local/state/atyrode/omp-plain-seed/`. The seeder always targets that
default state root — a caller's profile-scoped environment (for example
`atyrode apply` run from inside an omp session) never redirects it, and named
profile roots are never seeded:

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
rules, and the old generic skill are moved into a pending migration
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
   `omp/models.yml`, and `omp/plain-seed.yml`.
3. Run `nix flake check --show-trace`.
4. Apply the profile with `zconf`.

`omp-agents` regenerates the upstream bundled agents from the pinned OMP
binary, and the `omp-agent-references` check asserts that every agent name
referenced by `task.agentModelOverrides`, `task.disabledAgents`, or an
agent-named `retry.fallbackChains` key in the managed defaults
still exists in that unpacked set, so an upstream agent rename or removal
fails the build instead of silently misrouting models.

## Local CI equivalents

Run `nix fmt` for the repository formatter. It applies nixfmt, gofmt, shfmt,
deadnix, and statix. The consolidated Linux gate also enforces ShellCheck,
actionlint, and zizmor:

```bash
nix build --no-link .#checks.x86_64-linux.treefmt
```

The required matrix command is `nix flake check --show-trace`, run natively on
each supported system. Native execution matters: evaluating another system is
not a substitute for building its derivations.

| Required matrix leg | Local equivalent |
| --- | --- |
| `x86_64-linux` | On an x86_64 Linux host, `nix flake check --show-trace` |
| `aarch64-linux` | On an aarch64 Linux host, `nix flake check --show-trace` |
| `aarch64-darwin` | On an Apple Silicon macOS host, `nix flake check --show-trace` |

The `changes` job chooses that matrix or the documentation fast path. Its
classifier and regression suite can be run locally on x86_64 Linux:

```bash
printf '%s\n' docs/agent-tools.md | ./scripts/classify-ci-paths.sh
nix build --no-link .#checks.x86_64-linux.classify-ci-paths
```

For a documentation-only change, run the same two whole-tree checks as the
`docs-links` job, then compare the check derivations at the base and head
revisions:

```bash
nix build --no-link \
  .#checks.x86_64-linux.docs-links \
  .#checks.x86_64-linux.production-facts
./scripts/docs-drift-guard.sh <base-revision> <head-revision>
```

The always-reporting `ci-gate` job is only an aggregate: it succeeds when
classification succeeds and either the applicable native matrix or the
documentation fast path succeeds. It has no additional local executable beyond
the commands above.

### Flake output metadata

Nix's recognized reusable Home Manager output is `homeModules`; applications
carry `meta.description`, so those outputs pass the supported schema checks.
`inventory` and `capabilityInventory` deliberately remain public top-level
evaluation interfaces: the former is the versioned source used by `atyrode
inventory`, and both paths are documented for direct `nix eval` use. Nix 2.34
has no custom-output schema registration, so `nix flake check --no-build`
reports those two names as unknown. Relocating them under `lib` would silence
the checker by changing the public paths rather than describing the existing
contract. Those two warnings are therefore expected; app-metadata or
`homeManagerModules` warnings are not.

### CI cache strategy

The native matrix in [nix.yml](../.github/workflows/nix.yml) restores and saves
a per-system Nix store snapshot with `cache-nix-action` in GitHub Actions'
repository cache. It uses no repository secret, remains an acceleration only,
and is optional: local contributors run the commands above against their normal
Nix store and configured substituters. A fleet-wide binary substituter would
need a service, signing policy, and CI push credential; self-hosted Attic is
deliberately deferred to [#54](https://github.com/atyrode/dotfiles/issues/54)
until the managed VPS owns that security boundary.
