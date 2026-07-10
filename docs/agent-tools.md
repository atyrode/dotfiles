# Agent tools

OMP, Bigpowers, Herdr, the OMP–Herdr integration, model presets, agents, rules,
and generic skills are part of the Home Manager profile. `zconf` is the only
installation or activation command; there is no separate plugin or skill sync.

## Ownership

Nix owns:

- the pinned OMP binary and generated Zsh completion;
- the pinned Bigpowers package loaded into interactive OMP sessions, with its
  broken optional MCP launcher disabled at package build time;
- the pinned Herdr flake input and generated OMP integration;
- the managed OMP base config and model presets;
- the patched bundled agents, custom deep agents, and global generic skills;
- the `omp`, `ompb`, `ompf`, `ompg`, and `ompo` launchers; and
- mise itself, with no globally declared mise tools.

OMP and Herdr continue to own mutable runtime data such as authentication,
sessions, caches, onboarding state, and machine-local UI state. Secrets never
belong in this repository or the Nix store.

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

The balanced profile keeps cheap, fast roles on Luna or low-thinking Terra,
uses Sol for the hardest debugging and testing, and reserves Fable/Opus for
planning, design, architecture, and review where their higher cost is most
useful. The presets are policy, not provider pricing data; revisit the routes
when model quality or pricing changes.

Interactive sessions load configuration in this order:

1. OMP's writable machine config at `~/.omp/agent/config.yml`;
2. the Nix-managed base config;
3. optional machine-local overrides at `~/.config/omp/local.yml`;
4. a quick-command preset, when used; and
5. explicit command-line flags or extra `--config` arguments.

Later layers win. OMP maintenance subcommands are passed directly to OMP
because some subcommand parsers do not accept interactive plugin flags.
`omp update`, `herdr update`, and Bigpowers mutation commands are refused so
they cannot shadow the Nix-managed versions.

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

Bigpowers stays a pinned OMP plugin rather than being copied into the global
skill directory, preserving its package structure and prompt collection.

Bigpowers 2.76.2 also ships an optional `.mcp.json` launcher for
`bigpowers-mcp`. That server cannot start from the published package because its
Node dependencies are absent. The Nix derivation validates and removes that
launcher while retaining the independently loaded skills and prompts. A future
Bigpowers update should remove this workaround only after its packaged MCP
server starts successfully.

## First activation

Before Home Manager checks link targets, the activation hook examines legacy
paths. Conflicting regular files or symlinks at the OMP and Herdr binary paths,
the standalone Bigpowers plugin tree, managed agents, the Herdr extension,
presets, rules, and the old generic skill are moved to a timestamped backup. The
exact temporary `mcp.json` denylist previously used for `bigpowers-mcp` is also
retired; MCP configurations containing any custom servers or settings are left
untouched.
Legacy binaries are never executed during detection:

```text
~/.local/state/atyrode/agent-tools-migration/<timestamp>-<pid>/
```

The existing writable OMP config is copied into the same backup and only the
keys now owned by Nix are removed. Onboarding version, consent, unknown keys,
and other machine-local values remain writable. Invalid YAML, unsupported file
types at managed binary paths, or a mixed plugin tree stop activation instead
of guessing.

The migration is idempotent and writes
`~/.local/state/atyrode/agent-tools-migration/migration-v2.complete`.
Home Manager dry-runs make the migration dry-run too.

## Updating

1. Update OMP's version, asset names, and hashes in `pkgs/omp/default.nix`.
2. Update Bigpowers' version and npm tarball hash in
   `pkgs/bigpowers/default.nix`, then re-evaluate whether its MCP launcher still
   needs to be removed.
3. Update the Herdr input revision in `flake.nix`, then run
   `nix flake lock --update-input herdr`.
4. Review model identifiers and routing in `omp/config.yml` and
   `omp/presets/`.
5. Run `nix flake check --show-trace`.
6. Apply the profile with `zconf`.

`omp-agents` regenerates the upstream bundled agents from the pinned OMP
binary and reapplies `omp/agents/escalation.patch`, so an OMP update fails
during the build if the patch no longer applies cleanly.

GitHub Actions runs the same flake checks natively on x86_64 and aarch64 Linux
and macOS.
