# Agent tools

OMP, Herdr, the OMP–Herdr integration, model presets, agents, rules, and generic
skills are part of the Home Manager profile. `zconf` is the only
installation or activation command; there is no separate plugin or skill sync.

## Ownership

Nix owns:

- the pinned OMP binary and generated Zsh completion;
- the pinned Herdr flake input and generated OMP integration;
- the managed OMP defaults, enforced policy, and model presets;
- the patched bundled agents, custom deep agents, global generic skills, and
  managed-settings guard extension;
- the `omp`, `ompb`, `ompf`, `ompg`, `ompo`, and restricted `ompu` launchers; and
- mise itself, with no globally declared mise tools.

OMP and Herdr continue to own mutable runtime data such as authentication,
sessions, caches, onboarding state, and machine-local UI state. Secrets never
belong in this repository or the Nix store.

This subsystem deliberately owns neither a `pi` executable nor a `.pi`
mutable-state namespace. The bounded Pi experiment in #29 may therefore install
alongside OMP without an executable collision, shared authentication/session
state, or any parity requirement. The package check asserts the exact six OMP
launcher names and verifies that an OMP clean-home startup does not create
`.pi` state. Security boundaries and the untrusted-project launcher are
documented in [Agent security](agent-security.md).

Agents, rules, the settings guard, and the Herdr extension are assembled into
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

| Command | Intended use | Primary route |
| --- | --- | --- |
| `omp` | Balanced daily work | GPT-5.6 Terra at medium thinking |
| `ompb` | Cost-conscious routine work | GPT-5.6 Terra/Luna at lower thinking |
| `ompg` | OpenAI-only difficult work | GPT-5.6 Sol with Terra/Luna fallbacks |
| `ompo` | Expensive review and deep reasoning | GPT-5.6 with Opus fallbacks for selected roles |
| `ompf` | Fable-first work with predictable routing | Fable for primary/deliberative roles, with automatic fallback disabled |
| `ompu` | Deliberately untrusted repositories | Dedicated state, sanitized credentials, restricted integrations, and isolated writing tasks |

The balanced profile keeps cheap, fast roles on Luna or low-thinking Terra,
uses Sol for the hardest debugging and testing, and reserves Fable/Opus for
planning, design, architecture, and review where their higher cost is most
useful. The presets are policy, not provider pricing data; revisit the routes
when model quality or pricing changes.

The balanced routing rationale is:

| Role or role group | Capability and intended use | Thinking | Cost posture and fallback rationale |
| --- | --- | --- | --- |
| `default`, `task` | General implementation on Terra | Medium | Mid-cost default; Sonnet then Sol covers provider or capability failures |
| `librarian` | Repository and documentation research on Terra | Medium | Sonnet adds cross-provider depth; Luna is the economical final fallback |
| `advisor`, `smol`, `sonic`, `tiny`, `commit` | Fast review, lookup, naming, and commit-message work on Luna | Minimal–low | Cheapest recurring work; Terra is the first quality step-up |
| `explore` | Repository exploration on Terra | Low | Keeps discovery economical; Luna or Sonnet can take over when needed |
| `designer` | Product and interface design on Sonnet | Medium | Pays for stronger visual judgment; Sol and Fable provide cross-provider fallbacks |
| `reviewer` | High-scrutiny review on Sonnet | High | Higher-cost quality gate; Opus then Sol preserve depth if the primary is unavailable |
| `Tester` | Test design and adversarial verification on Terra | High | Strong reasoning without defaulting to the most expensive tier; Sonnet and Sol back it up |
| `plan`, `architect-deep`, `designer-deep` | Architecture, planning, and deep design on Fable | High | Premium reasoning is intentional for decisions with broad downstream impact; Opus or Sol are the escape routes |
| `slow`, `debugger-deep` | Hard debugging and deliberate reasoning on Sol | Xhigh | Expensive OpenAI reasoning is reserved for difficult failures; Opus and high-thinking Terra provide diversity |
| `tester-deep` | Exhaustive verification on Sol | High | Sonnet then Opus provide independent Anthropic verification if Sol is unavailable |
| `reviewer-deep` | Final deep review on Opus | Xhigh | Highest-cost route is restricted to the strongest review pass; Sol and Fable remain available |

`omp/defaults.yml` is the authoritative role map and fallback-chain definition;
the preset files intentionally change parts of this table for budget,
OpenAI-only, Fable-first, and Opus-assisted sessions.

Normal sessions load configuration in this order:

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

Later layers win. The enforced policy fixes workspace-write approval, secret
obfuscation, explicit prompts for shell/eval, browser, task spawning, and
GitHub capabilities, plus automatic task isolation with patch merging. Machine,
project, preset, and one-shot config files cannot weaken those controls. `omp
acp` receives the same layers in the same order, with the overlays placed after
the `acp` subcommand as required by OMP's parser.

Unattended yolo mode is available only through an explicit `--yolo`,
`--auto-approve`, or `--approval-mode yolo` runtime flag. The wrapper prints a
warning and applies a one-process approval overlay after the enforced policy.
There is intentionally no persistent yolo config, profile, or alias.

OMP maintenance subcommands are passed directly to OMP because their parsers do
not consistently accept interactive launch flags. Preset launchers preserve
that passthrough instead of prepending their preset to a maintenance command.
`omp setup` warns that it writes lower-priority machine state and points back to
the effective diagnostic.
`omp update` and `herdr update` are refused so they cannot shadow the
Nix-managed versions.

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
this guard together with the managed agents, rules, and Herdr integration. Use
`omp config managed`, the machine-local file, or the repository sources
instead.

The readable managed copies are linked under `~/.config/omp/`. Edit their
sources in this repository instead of editing the links.

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
file remain recognized.

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

1. Update OMP's version, asset names, and hashes in `pkgs/omp/default.nix`.
2. Update the Herdr input revision in `flake.nix`, then run
   `nix flake lock --update-input herdr`.
3. Review model identifiers and routing in `omp/defaults.yml` and
   `omp/presets/`.
4. Run `nix flake check --show-trace`.
5. Apply the profile with `zconf`.

`omp-agents` regenerates the upstream bundled agents from the pinned OMP
binary and reapplies `omp/agents/escalation.patch`, so an OMP update fails
during the build if the patch no longer applies cleanly.

GitHub Actions runs the same flake checks natively on x86_64 and aarch64 Linux
and macOS.
