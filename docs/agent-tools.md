# Agent tools

OMP, the profile generator, agents, rules, and generic skills are part of the
Home Manager profile. `atyrode apply` activates them; there is no separate
plugin or skill sync.

## Ownership

Nix owns:

- the pinned OMP binary and generated Zsh completion;
- the managed OMP defaults, enforced policy, and model catalog;
- the curated plain-omp seed and its drift-aware activation step;
- the pinned bundled agents, global generic skills, and managed-settings
  guard;
- the `omp` passthrough, the `omp-managed` managed-layering launcher, the
  restricted `ompu` launcher, and the `code` profile generator;
- personal policy from `modules/home/agents/AGENTS.md`, rendered by
  `atyrode context render` into `$XDG_CONFIG_HOME/agents/AGENTS.md` (default
  `~/.config/agents/AGENTS.md`) with minimal generation provenance, not a
  machine inventory; Home Manager links the default OMP user path and optional
  Claude/Codex adapters to it (see [Instruction architecture](#instruction-architecture));
- Claude Code's user-scope `~/.claude/settings.json` permission rules; and
- mise itself, with no globally declared mise tools.

OMP owns mutable runtime data such as authentication, sessions, caches,
onboarding state, and machine-local UI state. Secrets never belong in this
repository or the Nix store.

Activation does not rewrite or back up pre-existing mutable paths before Home
Manager links the managed agents, rules, extensions, and skills. If
`checkLinkTargets` reports a collision, inspect the exact path named by Home
Manager, preserve wanted content outside the managed namespace, move or remove
the collision, and rerun `atyrode apply`.

Agents, rules, and the settings guard are assembled into
a read-only OMP extension-package root in the Nix store and injected explicitly
by every managed session. They are not copied into OMP's mutable agent
directory, so named profiles and custom `PI_CODING_AGENT_DIR` roots receive the
same platform assets without sharing authentication, sessions, or caches.

Reusable package derivations live in `pkgs/`, Home Manager deployment lives in
`modules/home/agent-tools/contract.nix`, and the package overlay is assembled by
`lib/packages.nix`. On Linux, the OMP package patches only the ELF interpreter
(`PT_INTERP`), preserving the appended Bun payload and the binary's self-reexec
path for subprocess workers; it does not run the binary through a loader command.

## Instruction architecture

Keep three readers separate:

| Reader | Authored owner | Delivery |
| --- | --- | --- |
| Personal defaults and bounded personal authority | [`modules/home/agents/AGENTS.md`](../modules/home/agents/AGENTS.md) | Packaged into `atyrode`; activation and `atyrode apply` render the personal document and provenance for automatic harness loading |
| Repository contributors | Root `AGENTS.md`: local purpose, commands, boundaries, task routes and delivery | Repository revision, with one generated common block |
| Reusable repository engineering | [`modules/home/agents/engineering.md`](../modules/home/agents/engineering.md) | Renderer inserts exact bytes into repository roots and the neutral template, not personal context |

The template source is
[`modules/home/agents/templates/repo-AGENTS.md`](../modules/home/agents/templates/repo-AGENTS.md),
deployed by the agents module at
`$XDG_CONFIG_HOME/agents/templates/repo-AGENTS.md`. Fill applicable local
prompts and delete irrelevant ones. It requires neither Codex nor OMP and
does not enroll the recipient in automation or grant authority.

For a default OMP session, the normal sequence is automatic: `atyrode apply`
activates the managed environment, the activation hook renders personal policy,
Home Manager supplies the OMP user-file link, and OMP loads that file plus the
applicable repository instructions when a session starts. An agent does not
prepare its instructions by running `context render`, and the operator does not
need to paste them. Apply also performs a final render using the activated
generation's CLI. Rendering and loading are separate operations; neither
rendering nor diagnostics refreshes an already-running session's loaded policy.

Personal guidance contains durable preferences and safety/authority boundaries,
not a fleet handbook or a second copy of repository engineering. Machine state
is evidence, not permission. `atyrode context render` performs no host,
authentication or network inventory probes. When machine facts matter, an agent
can run `atyrode context show` or `atyrode context show --json` directly, without
asking the operator to fetch them. Neither command needs a previous render or
reads an inventory from the generated file: each gathers current diagnostics,
including bounded GitHub authentication status (10 seconds) and Clever status
probing (15 seconds).
They can contact services and expose account/secret-path metadata, never secret
values; do not copy their output wholesale into public artifacts or instructions.
An undeclared checkout remains unknown/null rather than inferred from a
conventional directory. [Agent context](atyrode.md#agent-context) owns the
command contract; the provisioning probe compares policy/revision, not age alone.
OMP's own workstation/environment block is separate and unchanged; moving the
fleet/authentication/cache inventory out of this file does not remove OMP's
basic platform information.

Home Manager links `~/.omp/agent/AGENTS.md`, `~/.claude/CLAUDE.md` and
`~/.codex/AGENTS.md` to the rendered file. These are cross-tool adapters, not
three independently injected OMP copies. The OMP link covers its default agent
directory; named profiles or custom `PI_CODING_AGENT_DIR` roots are not covered
merely because the default link exists. Codex configuration/authentication
seeding remains separate and optional; see [Codex state](codex-state.md).
Durable Claude permission rules belong in the Nix-managed user settings
[`modules/home/claude/default.nix`](../modules/home/claude/default.nix).
Project-local exceptions belong in that project's appropriate local settings,
not in a generated global file or committed as machine-specific policy.

### Guidance and loader limits

[OpenAI's AGENTS.md guide](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
describes Codex's startup chain, one file per directory, override/fallback
selection and configurable combined-size limit.
[Anthropic's memory guidance](https://code.claude.com/docs/en/memory#write-effective-instructions)
recommends concise, concrete persistent instructions and moving multi-step or
conditional guidance to skills/rules; its imports still consume startup context.
These are useful authoring guidance, not descriptions of OMP. Selecting an
OpenAI or Anthropic model does not select that vendor's instruction loader.

The loading checks exercise the repository's current OMP package pin. The
discovery reference below is pinned to version 18.1.14, commit
[`daf07999c2fee9b22edc7bf8fea1fb6272e0df5e`](https://github.com/can1357/oh-my-pi/commit/daf07999c2fee9b22edc7bf8fea1fb6272e0df5e).
Recheck the source when changing the OMP pin:

- Native user `AGENTS.md` follows the active profile or explicit agent directory.
  Foreign user adapters require opt-in; when enabled, native context wins the
  single user scope over Claude and Codex (priorities 100, 80 and 70).
- Context deduplication can omit a farther file whose entire normalized paragraph
  sequence occurs contiguously in a closer file. It does not remove arbitrary
  overlapping spans or paraphrases from retained documents. Keep personal and
  shared repository policy separate rather than relying on deduplication.
- Standalone project `AGENTS.md`/`CLAUDE.md` discovery walks ancestors, retaining
  multiple depths root-first. Native discovery selects the nearest non-empty
  `.omp` directory and only its non-empty `AGENTS.md`; a missing file there
  does not resume the search farther up. Same-depth provider priority can
  shadow a standalone file. Claude/Gemini/GitHub adapter project paths are
  cwd-only; OMP's Codex adapter has no project `.codex/AGENTS.md` reader.
- Loaded context bodies are fully injected, not lazy. Deeper files beneath cwd
  are discovery pointers requiring an explicit read. `@path` expands inline,
  relative to its importer, up to five recursive levels; it is not a deferred
  link. Use ordinary Markdown task links and explicit read conditions.
- Described rulebook rules without `alwaysApply` or accepted TTSR conditions
  expose discovery metadata and `rule://` content. Their globs are advisory,
  not automatic body loading. `RULES.md` and `alwaysApply` rules inject bodies;
  TTSR is conditional intervention, not general-purpose background loading.
- `SYSTEM.md` changes the bundled prompt template, retaining generated context
  while replacing default role/tool/workflow guidance; it is not a lightweight
  routing mechanism. The pinned native loader searches the nearest non-empty
  ancestor `.omp` for it, despite documentation describing cwd-only discovery.
  `APPEND_SYSTEM.md` adds startup content, not laziness.

Owning pinned sources:
[native discovery](https://github.com/can1357/oh-my-pi/blob/daf07999c2fee9b22edc7bf8fea1fb6272e0df5e/packages/coding-agent/src/discovery/builtin.ts),
[user-path resolution](https://github.com/can1357/oh-my-pi/blob/daf07999c2fee9b22edc7bf8fea1fb6272e0df5e/packages/coding-agent/src/discovery/helpers.ts),
[Claude adapter](https://github.com/can1357/oh-my-pi/blob/daf07999c2fee9b22edc7bf8fea1fb6272e0df5e/packages/coding-agent/src/discovery/claude.ts),
[Codex adapter](https://github.com/can1357/oh-my-pi/blob/daf07999c2fee9b22edc7bf8fea1fb6272e0df5e/packages/coding-agent/src/discovery/codex.ts),
[context capability](https://github.com/can1357/oh-my-pi/blob/daf07999c2fee9b22edc7bf8fea1fb6272e0df5e/packages/coding-agent/src/capability/context-file.ts),
[capability resolution](https://github.com/can1357/oh-my-pi/blob/daf07999c2fee9b22edc7bf8fea1fb6272e0df5e/packages/coding-agent/src/capability/index.ts),
[imports](https://github.com/can1357/oh-my-pi/blob/daf07999c2fee9b22edc7bf8fea1fb6272e0df5e/packages/coding-agent/src/discovery/at-imports.ts),
[prompt composition](https://github.com/can1357/oh-my-pi/blob/daf07999c2fee9b22edc7bf8fea1fb6272e0df5e/packages/coding-agent/src/system-prompt.ts).
No normal-context byte/token cap is established by these OMP sources; do not
apply Codex's cap to OMP. Managed configuration layers do not replace this
loader. Verify the selected profile/overlays when diagnosing a particular
session rather than assuming its effective discovery configuration.

### Maintained loading checks

`nix build --no-link .#checks.x86_64-linux.omp-context` exercises the packaged
`atyrode context render`, the evaluated Home Manager render hook and its actual
adapter sources, relocated into disposable homes. It checks first activation
and replacement of stale policy, source content/provenance and permissions, then
inspects real raw and managed OMP prompts through the deployed links. The same
check runs on the native CI platforms, including portable Linux configuration.

[`ci/check-agent-context.py`](../ci/check-agent-context.py) drives real OMP's
ready/negotiation/`get_state` protocol without a model turn. It checks complete
rendered documents, accounting for OMP's trailing-whitespace, table-padding and
blank-line formatting without discarding directive text or meaningful indentation;
negative cases reject changed directives and code indentation. It checks single copies and ordering; root versus nested
cwd; default, named and explicitly selected agent directories; opted-in adapter precedence;
portable/outside-repository contexts; and loaded snapshots versus a changed file
in a new process.

The existing `agent-policy` action also runs this acceptance against each
repository's **current candidate** `AGENTS.md` in dotfiles, Code, Babel and
Manifold. Runtime, common source and personal source come from one action
snapshot; there is no second OMP pin or frozen copy of another repository's
instructions. Consumer fixtures use the authored personal document; the native
check separately proves its actual rendering and deployment.

Only instruction documents enter the fixture: caller credentials, local
configuration and project extensions are excluded. Therefore this proves the
maintained default loading contract, not every machine-local override, import
layout or model's compliance with the instructions. The command regressions in
`atyrode-apply` separately prove that text/JSON diagnostics work with absent,
stale or corrupt startup files without changing them.

## Instruction authoring and distribution

Edit local repository guidance outside the marked common envelope. For a shared
rule, edit `modules/home/agents/engineering.md` and regenerate in a deliberately
selected dotfiles worktree:

```sh
python3 ci/agent-policy.py render --source modules/home/agents/engineering.md --root . --layout dotfiles
python3 ci/agent-policy.py check --source modules/home/agents/engineering.md --root . --layout dotfiles
```

The `dotfiles` layout is exactly root `AGENTS.md` plus
`modules/home/agents/templates/repo-AGENTS.md`. Publish those outputs with the
source change; the static personal policy is not a renderer target.
The source is UTF-8/LF with exactly one final newline and no envelope sentinels.
The digest identifies exact payload bytes, not unrelated source commits.
Never hand-edit managed bytes or their Prettier guards. For a new document,
`block` emits the complete envelope to insert after its introduction; `render`
refuses missing/corrupt envelopes and preserves bytes outside them.

For a deliberately adopted, unenrolled repository, run from a reviewed dotfiles
worktree, substituting the recipient path:

```sh
python3 ci/agent-policy.py block --source modules/home/agents/engineering.md
python3 ci/agent-policy.py render --source modules/home/agents/engineering.md --root <repository> --layout repository
python3 ci/agent-policy.py check --source modules/home/agents/engineering.md --root <repository> --layout repository
```

The `repository` layout updates only root `AGENTS.md`.
[`ci/agent-policy.py`](../ci/agent-policy.py) owns the byte/path contract;
the [read-only workflow](../.github/workflows/agent-policy.yml), local composite
action and offline Nix `agent-policy` check enforce it. CI catches byte drift,
not every semantic contradiction. Review local and shared text together.

### Optional automation enrollment

Copying the template is not enrollment. An authorized enrollment change must
add reviewed support to the
[reusable synchronizer allowlist](../.github/workflows/sync-agent-policy.yml)
and [`ci/agent-policy-sync.py`](../ci/agent-policy-sync.py) core-check mapping.
Use the existing
[consumer workflow pattern](https://github.com/atyrode/code/blob/main/.github/workflows/agent-policy.yml):
PR/push checks invoke reviewed dotfiles `main` read-only; hourly/manual
synchronization calls the reusable workflow with repository-scoped
contents/pull-requests/actions write permission. Preserve read-only defaults,
enable Actions PR creation and provide core CI `workflow_dispatch`. Preserve
existing classic core checks, their GitHub Actions application bindings,
strict/up-to-date enforcement, admin/review settings and other rulesets.
Enroll `agent-policy`, bound to GitHub Actions app ID `15368`, in a dedicated
active, main-only, strict required-status-check ruleset with no bypass actors.
Create and verify that rule before removing only a duplicate classic
`agent-policy` requirement introduced during enrollment. These settings require
their own authority; the synchronizer never mutates them or acquires credentials
to make enrollment possible.

The repository token reads main's exact SHA, protected state and classic
app-bound checks from the public branch endpoint. The bounded effective-branch
rules endpoint supplies active strict policy requirements; evaluate/disabled
rules do not count. Core check bindings may be supplied by applicable classic
or active ruleset requirements, but `agent-policy` itself must be app-bound in
a strict active rule. The PR GraphQL query separately confirms the tested
head/base, readiness, mergeability and successful current-head status rollup,
without requesting administrative branch-protection fields. Missing evidence
blocks merge; no operator-token fallback or permission expansion is used.

The Code, Babel and Manifold consumers receive generated-only draft PRs,
exact-head core/policy CI, guarded squash merge, and separately observed main
CI. Maintainer holds remain effective; the bot neither reviews its PR nor uses
cross-repository write credentials. Following reviewed dotfiles `main` trusts
its automation code as well as its Markdown. Delivery is eventual convergence
through scheduling and CI, not an exact-time promise. Existing green runs are
not retroactively invalidated when the source changes.

Replacement publication first records a prepared candidate in the existing
bot-owned `agent-policy-sync-status:v1` comment. Its optional `prepared` field
binds the previous and candidate head/base/source/digest, the observed base and
the commit timestamp; canonical `agent-policy-sync:v1` PR metadata is unchanged.
After interruption, a later attempt reconstructs the exact generated candidate
and accepts only the recorded old or prepared branch head. It keeps the record
until PR metadata and status agree, without relying on a discarded commit
remaining fetchable. Holds still stop publication, and recovery does not approve
or merge without fresh applicable CI and protection checks. Missing, ambiguous or
mutated ownership evidence remains a refusal, not permission to infer a repair.

### Publication is not activation

A source PR publishes policy and generated repository outputs. Consumer PRs
deliver repository copies. Separately authorized Home Manager activation
deploys the personal policy/template through the packaged CLI and agents
module; normal `atyrode apply` consumes a published revision without requiring
a checkout. Authoring operations require an explicit `--repo PATH`, never a
particular machine or directory name. Rendering does not activate a generation.
Neither a source merge nor a bot merge authorizes apply, fleet deployment,
secret migration, provider/archive mutation or any other live operation.
Historical checkouts and already-running sessions retain their loaded snapshot;
publication and activation do not silently rewrite it.

## Standalone Linux development image

`packages.<linux-system>.development-image` packages the existing portable
`development-*` Home Manager environment for Linux amd64 and arm64. It includes
the configured zsh, OMP, Code catalog and the rest of that profile, rather than
a separate container tool list. Build and exercise it locally with:

```sh
nix build .#development-image --print-build-logs
docker load --input result
image="$(nix eval --raw .#development-image.imageName):$(nix eval --raw .#development-image.imageTag)"
docker run --rm -it "$image"
nix shell --inputs-from . nixpkgs#tmux nixpkgs#python3 \
  --command python3 ci/verify-development-image.py "$image"
```

The default command is the real login zsh, running as `developer` (UID/GID
1000) in `/workspace`. Supplying another command retains home activation and
the same user. A project may be bind-mounted at `/workspace` when its
permissions allow UID 1000 access. Do not mount an operator home, credentials,
host Nix store or Docker socket as part of the default environment.

Every start runs Home Manager activation, including its generation management,
managed-file conflict checks, OMP and Codex seeds, migrations and context
rendering. Automatic speech-model downloads and the classifier, resource-guard
and ssh-agent services are disabled; no systemd manager or model supervisor
is started. Provider authentication is not bundled. Native tools remain
responsible for their sign-in flow and current model availability.

The image supplies the daemon boundary declared in
[`fleet/system-boundary.json`](../fleet/system-boundary.json): root owns the
store and Nix daemon, while the developer is an untrusted client. The daemon
does not inherit the developer's Nix configuration or cache paths, and builds
run under separate `nixbld` users. Builds use `sandbox = false` inside the OCI
boundary; this is not a sandbox for hostile builds. The Linux bootstrap's
existing `--no-daemon` installation is a different runtime contract and is
neither invoked nor changed by this image.

Home and mutable Nix state belong to the container writable layer. They
survive stop/start of that container, not deletion or recreation. Home Manager
refuses unmanaged files that conflict with its links. Startup also refuses a
home not owned by UID 1000 rather than recursively changing a possible host
mount. Application exit status is preserved; unexpected daemon loss ends the
session instead of leaving a shell with broken Nix access.

CI verifies real offline containers and terminal interaction on both native
architectures. Green main publishes those tested archives, without rebuilding,
to immutable revision tags under `ghcr.io/atyrode/development` and a
multi-platform index. The publication job's summary and
`development-image-reference` artifact give the immutable digest for consumers.
Retries reuse matching platform and index digests and refuse mismatches.
Publication requires anonymous pulls and standalone startup; initial GHCR
package visibility may need to be set to public in GitHub package Settings.
It does not activate fleet hosts or redeploy consumers.

## OMP commands

Four commands make up the operator surface:

| Command | Intended use | Configuration |
| --- | --- | --- |
| `omp` | Mutable daily driver | The operator's writable OMP configuration, apart from the blocked `update` command and profile-aware resume lookup |
| `omp-managed` | Managed launch target | Platform extensions, managed defaults, enforced policy, and any generated one-shot `--config` |
| `ompu` | Deliberately untrusted repositories | Dedicated state, sanitized credentials, restricted integrations, and approval-gated shell/task use |
| `code` | Profile generator and launcher | Generated profiles launched through `omp-managed`, the managed defaults, or the `ompu` sandbox |

Use `omp --help` and `omp <command> --help` for the pinned upstream command
surface. [Upstream documentation](https://github.com/can1357/oh-my-pi/tree/main/docs)
may describe behavior newer than the repository pin. This document is
authoritative for `code`, `omp-managed`, and `ompu`.

Plain `omp` executes upstream OMP directly, with no managed extension, defaults,
or policy overlay. `omp update` is blocked so it cannot shadow the Nix-pinned
binary. For a UUID or UUID prefix passed to `--resume`, the launcher searches
the default and named-profile session roots and injects the sole matching
profile; explicit state or profile selection wins, and ambiguous matches require
`--profile`.

`omp-managed` is the managed-layering primitive used by `code`. It loads
configuration in this order:

1. OMP's writable machine config at `~/.omp/agent/config.yml`, with
   `config.yaml` selected only when the canonical filename is absent;
2. the Nix-managed portable defaults;
3. native project configuration from `<cwd>/.omp/settings.json` and then
   `<cwd>/.omp/config.yml`;
4. optional machine-local overrides at `~/.config/omp/local.yml`;
5. one-shot `--config` overlays, including the profile generated by `code`;
6. the Nix-managed enforced policy; and
7. explicit runtime flags such as `--model` or `--approval-mode`.

Native `PI_CONFIG_FILES` overlays, when inherited, precede the managed
defaults (after writable/native project configuration).

Later layers win. Explicit `launch` and `acp` receive the same layers in the
same order, with overlays placed after the subcommand as required by OMP's
parser. Maintenance subcommands pass directly to OMP because their parsers
do not consistently accept interactive launch flags.

When launched from `$HOME` without `--cwd` or `--allow-home`, the wrapper
mirrors OMP's safety change of directory before resolving project layers.
Relative one-shot `--config` paths resolve from that effective project
directory.

Use `omp-managed config managed --json` to inspect the managed profile, state path,
ordered configuration sources, ownership, and effective Nix-owned values. Use
`~/.config/omp/local.yml` for machine-only overrides of defaults; it cannot
weaken enforced policy. The readable managed copies under `~/.config/omp/` are
links—edit their repository sources instead.

The diagnostic delegates migration, merging and schema-default resolution to
the pinned binary's `config list --json`, with the same ordered layers supplied
through native `PI_CONFIG_FILES`. That command opens mutable storage, so it runs
in disposable private state, outside the project, and reads source files only
as overlays. Only Nix-owned keys are returned; arbitrary local settings and
credential values are not dumped. Schema defaults now appear for Nix-owned keys
that no layer sets. Runtime model/thinking/approval flags are reported separately
and applied to the selected values; this is not a model turn or an extension
startup and does not resolve extension-registered flags.

The shared launcher grammar in `pkgs/omp-configured/argv.sh` follows the pinned
CLI's value consumption, including flag-shaped string values, optional session
values, boolean `--flag=value` spellings and the `--` prompt boundary. Restricted
launchers reject state/resource/approval overrides only in flag positions.
`nix build --no-link .#checks.x86_64-linux.omp-wrapper` checks argv preservation,
restricted boundaries, native diagnostics and live CLI grammar drift; `omp-stack`
additionally exercises real RPC/ACP startup. Neither requires provider credentials.

`nix build --no-link .#checks.x86_64-linux.omp-interactive` covers the actual
terminal composer: paste a PNG and observe an image attachment through raw OMP
with explicit cwd, plain bare/no-session launches, managed and restricted
launchers, and packaged Code's Enter/`m` launch paths. It uses isolated homes
with `startup.setupWizard: false`; otherwise first-run onboarding correctly
intercepts input before the composer is available. This is attachment/UI proof,
not a model image-understanding turn, and does not activate a machine.

The diagnostic now reports current isolation keys (`task.isolation.enabled`
and `isolation.backend`), not the retired combined `task.isolation.mode`.
Enablement permits per-spawn requests; it is not a default to isolate every task.
The persistent plain-OMP seed retains its legacy key because upstream still
migrates it and changing seeded keys could override a local opt-out on reseed.

Managed defaults and the plain seed disable `startup.checkUpdate`: Nix owns
upgrades and repository pin-update automation still reports release drift.
This removes the interactive upstream release reminder (and its startup network
check), not the pinned-version check or the repository's latest-release warning.
The ordinary seed merge preserves an operator's divergent local preference.

### Agent role identity and fallback

Managed `task.agentModelOverrides` values are native aliases (`@task`,
`@reviewer`, `@scout`, `@sonic`); `modelRoles` owns each selector and its
thinking suffix. The pinned OMP accepts settings-defined roles as well as
built-ins. Merely naming an agent `task` does not retain the `task` model role
when its override is a concrete selector: the child loses that identity and
cannot select the intended role-keyed `retry.fallbackChains.task`.
Declaring the role and selecting it through `@task` preserves dispatch identity.

Do not duplicate chains under concrete selectors to compensate. Two roles may
share the same lead model but need different fallback chains; a selector-keyed
map cannot express that distinction. Existing managed lead selectors/thinking
levels and non-empty chains are unchanged. The additional `scout` role carries
its existing override selector. Explicit empty `tiny`, `commit` and `sonic`
chains express those utility roles' lead-only intent; other omitted role chains
inherit the native `default` chain.

The pinned OMP 18.1.14 still drops that identity when initializing a child
session. Actual retry experiments show a shared lead can borrow the parent's
or a sibling's chain, including for an explicitly empty chain. Aliases fix the
configuration boundary but need an upstream runtime repair for complete
enforcement ([Code #142](https://github.com/atyrode/code/issues/142)); effective
config and constructor-only checks cannot certify that behavior.

`omp-managed config managed --json` exposes effective aliases, selectors and
chains, but is not proof of a child's fallback behavior. For an offline native
regression check when changing the OMP pin or routing:

1. Use disposable HOME/state/configuration with no operator credentials,
   project extensions or network model access. Register a deterministic local
   test provider with a failing lead and distinct successful fallback models.
2. Configure two declared roles with the same lead and thinking level, native
   `@role` agent overrides, and different role-keyed chains. Exercise one
   built-in role and one settings-defined role.
3. Spawn real task children through the pinned OMP. Make the lead return a
   retry-eligible failure, then inspect provider calls and child output: each
   child must use its own role's fallback, with the configured thinking level,
   rather than the parent's/default chain or the other role's fallback.
4. Repeat with a direct-selector override to reproduce the lost-role defect.
   Resolving an alias or inspecting generated YAML alone is insufficient.
5. Remove disposable state. No paid provider calls or host activation are
   required. `omp-stack` separately checks that a persistent direct override
   cannot displace the managed alias and that the writable preference survives.

### Speech and model-fact freshness

Speech uses OMP's native first-use model downloads. Dotfiles no longer
prefetches speech models at activation or manages a separate speech cache;
existing downloaded caches remain untouched. A first use on an uncached
machine can require a download. Publishing this change does not activate any
host or download/remove its models.

`pkgs/omp-configured/config/models.yml` stores curated routing facts.
`nix run .#refresh-model-facts` refreshes metadata and runs paid chat benchmarks;
it requires separately authorized model use. `--skip-bench` updates metadata
without model turns, and `--bench-json <path>` can consume a saved native chat
benchmark payload instead of making new benchmark calls.
The `refreshed` stamp advances only when every catalog model has complete
valid metadata and chat speed/TTFT measurements. Partial or failed runs retain
unavailable values and the previous stamp while saving valid updates; partial
failures exit nonzero. A successful metadata-only run still leaves the stamp
unchanged. `refreshed: null` honestly means no complete refresh is attested,
not that the facts were freshly measured or that every retained value is wrong.

### Code launch choices

`code` classifies a prompt and selected facets into a generated routing profile.
Its trusted launches always use `omp-managed`; plain `omp` is invoked directly,
never through `code`. The launch choices are:

- launch the generated profile through `omp-managed`;
- launch `omp-managed` without an overlay to use the managed defaults; or
- launch the current context through the credential-sanitized `ompu` sandbox.

`code --no-usage` skips the usage fetch, `code --help` prints help, `code ls`
lists live managed sessions, `code session reap` previews or retires selected
session process trees, and `code generate` regenerates the profile catalog.
Sessions are recorded under `$XDG_STATE_HOME/code/sessions` while they run; a
session locks its record so crashed sessions can be pruned.

On an applicable x86_64 WSL2 host with NVIDIA CUDA passthrough, `code` can
discover the `local-qwen` runtime through `CODE_RUNTIME_BROKER=atyrode`.
Selecting it delegates lifecycle to `atyrode runtime run local-qwen`; model
data, generated API keys, container state, and the selected storage path remain
machine-local and outside the Nix store. Unsupported hosts remain hosted-only.

## Security boundaries

Decision records: [ADR-0004](adr/0004-agent-trust-tiers.md) for the trust
tiers; tool credentials stay owned by their tools, and fleet secrets travel
through sops-nix ([secrets.md](secrets.md)) since ADR 0008 superseded
[ADR-0005](adr/0005-no-declarative-secret-manager.md).

Use `ompu --cwd <project>` for deliberately untrusted repositories.
[Agent security](agent-security.md) owns the trust tiers, enforced controls,
credential isolation and sandbox limits. Plain `omp` uses mutable operator
policy; managed launchers apply the layering described above.

Trusted authentication uses the canonical OMP broker backed by the `default`
profile on the machine [`fleet/auth-broker.json`](../fleet/auth-broker.json)
names. [`modules/shared/omp-auth-broker.nix`](../modules/shared/omp-auth-broker.nix)
owns the loopback service and other machines' SSH forwarding target.
[Secrets](secrets.md#declaring-a-secret) owns bearer-token generation, placement,
audiences and rotation. Until the token is placed the service does not start;
`atyrode doctor provisioning` reports the owed generation.
`atyrode auth broker status` reports mode, host, service and placement without
printing the token. `code` uses the same token and stores encrypted snapshots
under `$XDG_CACHE_HOME/atyrode/omp-auth-broker/`.

Add Anthropic/OpenAI OAuth accounts from `code` with `v`, then `a` -- on a
tunnel machine the login runs on the broker host over the same SSH target,
which Home Manager exports as `CODE_AUTH_LOGIN_VIA` -- or directly with
`omp auth-broker login <provider> --via=alex@<broker host>`. Add API-key
providers without exposing the key in argv:

```sh
atyrode auth broker add-api-key deepseek
```

Both paths mutate the canonical broker, so every connected machine sees the new
account on its next automatic or manual (`r`) refresh; no credential file is
copied between machines. Account-selection presets remain non-secret state in
`$XDG_STATE_HOME/atyrode/code-auth-account-state.json`. The `code` account
manager reads only redacted broker data and never reads OAuth material.
Token rotation follows [the secret owner](secrets.md#declaring-a-secret), not
an independent agent-tool ceremony.

## State ownership

| State | Owner |
| --- | --- |
| `~/.omp/agent/` and named profile roots | OMP/operator mutable configuration, authentication, sessions, and UI state; the one exception is `~/.omp/agent/AGENTS.md`, a Home Manager symlink to the generated agent context |
| `~/.omp/auth-broker.token` | Home Manager link to the `omp-auth-broker` clan var sops-nix places; the shared bearer token the broker checks and every client sends, mode `0600` |
| `$XDG_CACHE_HOME/atyrode/omp-auth-broker/` | Broker client snapshot cache |
| `$XDG_STATE_HOME/atyrode/code-auth-account-state.json` | `code`; non-secret account-selection presets |
| `$XDG_STATE_HOME/code/sessions` | `code`; live session records |
| `$XDG_STATE_HOME/atyrode/omp-untrusted/` | `ompu`; isolated mutable sandbox state |
| `~/.local/state/atyrode/omp-plain-seed/` | Plain-OMP seeder; last-applied seed and drift state |
| `~/.omp/agent/managed-skills` | OMP; project-specific auto-learned mutable skills |

## Seeded plain-omp defaults

`pkgs/omp-configured/config/plain-seed.yml` holds the repository's defaults for plain `omp`: trusted-machine
guardrails, the bundled-role model map and fallback chains, and interface
preferences. It is deliberately not a managed launch layer. During activation,
`atyrode-omp-seed apply` three-way merges it into OMP's selected writable
machine configuration against the last-applied seed stored at the fixed seed
state root `~/.local/state/atyrode/omp-plain-seed/`. A caller's profile-scoped
environment never redirects that root, and named profile roots are never
seeded.

- A key the operator never touched is written and follows repository updates.
- A key the operator changed or deleted is left alone and reported until reviewed.
- Unmanaged keys are never modified.

`atyrode apply` reports drift after activation and, on a terminal, offers a
per-key keep-or-reset review. Direct commands are `atyrode-omp-seed status
[--json]` and `atyrode-omp-seed resolve [--reset-all]`.
Keeping a value records that exact local choice and default privately in
`kept.json` beside the last-applied seed; it does not make the local value
follow future repository updates. Unchanged choices appear under `accepted`
in JSON status and do not prompt again. A changed local value or default
requires another review. Quit and EOF leave remaining choices unreviewed;
`--reset-all` also resets previously accepted choices.
`AGENT_TOOLS_DRY_RUN=1` prints the plan without writing, and
`ATYRODE_SEED_REVIEW=0` suppresses apply-time interactive review for
PTY-backed automation.

The persistent seed intentionally retains direct `task.agentModelOverrides`
selectors and supported legacy migration keys (including `task.isolation.mode`).
Unlike immutable managed defaults, a seed has per-leaf ownership history:
changing an untouched override to `@task` can silently switch its model to an
independently customized `modelRoles.task`. Adding new role leaves can likewise
conflict with existing local routing. The current seeder has one seed for both
fresh and existing state, not a separate fresh-only alias path; this change does
not introduce a second seed or migration engine. Consequently even a fresh
plain-OMP seed retains the direct-selector limitation described above.

For plain OMP, an operator-reviewed conversion must compare each live override,
the desired role selector/thinking level, and its fallback chain together;
declare any custom role and select `@role` only after preserving that intended
routing. Keep the resulting differences during seed drift review rather than
using `--reset-all`, which deliberately restores the legacy seeded values.
Managed aliases preserve managed dispatch identity without rewriting any
plain-OMP preference or changing old migration-key ownership.

The seed may overlap keys owned by managed launchers: `defaults.yml` and
`policy.yml` layer above the machine configuration, so seeded values cannot
change managed behavior. The session guard blocks `/settings`; it never rolls
the shared writable configuration back to a startup snapshot. Seed resets and
edits by other sessions must survive while managed sessions are running and
when they shut down. The flake check asserts agreement wherever seeded and
enforced values overlap. Writes abort if the machine configuration changes
between read and write; rerun to evaluate the new state.

After upgrading from the startup-snapshot guard, restart existing managed
sessions before reviewing drift: an already-running session still has the old
extension loaded and can undo a reset. The replacement guard does not require
further reset/restart cycles.
Apply re-reads the state after review and names any remaining keys. If a reset
summary is followed by renewed drift, restart those older sessions before
resolving again rather than repeatedly resetting under the old watcher.

## Babel analysis profile migration

The managed `code` launcher forwards `code engine` headlessly to Code's native
RPC engine and keeps its sessions on the restricted `omp-analysis` launcher.
The explicit `--configure` ceremony retains the interactive managed launcher.

Home Manager's `migrateBabelAnalysisRuntime` activation runs after `installPackages`
and `linkGeneration`, using the activating generation's Code and Babel
executables even when an older `atyrode` invoked apply. It first runs
`code engine --import-profiles` on
`${CODE_BABEL_PROFILE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/code/babel/profiles}`
when that source exists, retaining the original store. It then runs
`babel analysis migrate`, which removes only the trailing legacy `babel`
worker mode argument and validates configured immutable profile references
offline through the configured workers before saving settings.

Custom worker wrappers, profile IDs and revisions, account choices, and
unrelated settings remain unchanged. Unconfigured analysis creates no settings.
The owner commands neither contact providers nor start analysis or restart
services; retained wrappers keep their normal environment setup. A dry-run
only announces the operations. Import conflicts or invalid settings stop
activation with the owning command's error rather than being hidden or
replaced with a new profile selection.

`atyrode doctor provisioning` reports the `babel-analysis` surface using
`babel analysis migrate --check --json`: unconfigured workers are
`not-applicable`, pending migration or unresolved references are `degraded`,
and canonical launches whose references resolve offline are `ok`. The probe
does not migrate anything; `atyrode apply` owns convergence. To inspect a
failure directly, run the same read-only Babel command, resolve its reported
conflict, and apply again.

## Session archive

Home Manager configures [Babel](https://github.com/atyrode/babel) to archive
available OMP, Codex and Claude session sources under the registry's stable
host identity. Actual archival requires configured custody and a successful
push; installing a timer is not evidence of either. Babel owns snapshot,
catalog, browsing and recovery behavior; consult its documentation and
`babel --help` for product workflows. This section owns dotfiles deployment
and the managed-state boundary.

[`modules/shared/babel-archive.nix`](../modules/shared/babel-archive.nix) owns
provisioning; [Secrets](secrets.md#declaring-a-secret) owns the shared
`babel-custody` inputs, per-machine storage, whole append-only payload key
ring, validation and rotation. Home Manager links placed mode-600 files at
`~/.config/babel/storage.json` and `~/.config/babel/payload-keys.json`; do not
run `babel storage configure` on a fleet machine to replace that ownership.

For migration from plain local files, Home Manager refuses to replace them.
Before removing any file, import the full existing ring into encrypted custody
and verify it retains every key held by any configured machine or the old vault
item; refuse conflicting material under the same key ID. Only then remove the
old plain files (including `~/.config/babel/repository-password`) before the
authorized apply that places the links. Never leave the ring prompt empty for
an existing archive: minting a fresh ring would lose access to sealed content.
Keep all prior keys when rotating through the secret owner's procedure.

Do not run `babel sync --generate-key` on a managed machine: Babel's atomic
rotation replaces the Home Manager symlink with a local file and does not
update fleet custody. Rotate the shared var instead, retaining all prior keys.

A `babel-archive` systemd user timer (launchd agent on macOS) then runs the
`babel-archive-push` wrapper unattended. The timer's start condition is
`~/.config/babel/storage.json`, so it arms only on a configured machine —
storage is placed and verified first, and only then does anything push on a
schedule. systemd reads that condition when the timer starts, and the unit does
not change when the document appears, so `atyrode apply` starts the timer
after every activation and a machine whose document was placed today does not
wait for its next login; `systemctl --user start babel-archive.timer` arms one
by hand. To see why a timer is not armed,
`systemctl --user status babel-archive.timer` reports it inactive and names the
condition that was not met, `journalctl --user -u babel-archive.timer` keeps the
same line, and the presence or absence of `~/.config/babel/storage.json` is that
answer read directly.

macOS has no equivalent condition, so there the wrapper's own check is the whole
gate. With no `~/.config/babel/storage.json` the wrapper prints one line and
exits 0 — which is also what a hand-run `babel-archive-push` does on any
unconfigured machine — so an unconfigured machine is a no-op rather than a
failing unit; when the machine is configured and the push fails, a missing
restic repository included, it exits nonzero and the failure stays visible.
After a successful push the wrapper stamps
`~/.local/state/babel/last-success` with one ISO-8601 UTC line, and
`atyrode apply` reads that stamp to warn when the archive is unconfigured, has
never succeeded here, or has not succeeded within 48 hours.

Operator surfaces are Babel's own: `babel archive push` runs a snapshot in the
foreground, `babel archive status [--json]` reports repository and stamp health,
`babel archive verify [--deep]` checks repository integrity (`--deep` reads
the pack data, not just the index), and `babel sessions list` browses the
catalog.

These commands have different effects: listing/status inspect state, integrity
verification accesses the configured repository, and push writes the live
archive. Documentation of a command is not permission to run live archive
writes, destructive recovery, key rotation or activation.

## Skills

Generic cross-project skills belong in `modules/home/agents/skills/`, which Home Manager
links to `~/.agents/skills`. OMP discovers `.agent/skills` and
`.agents/skills` from the home directory and while walking up a project tree.
Project-specific skills and other project instructions belong in the owning
repository:

```text
project/
└── .agents/
    └── skills/
        └── project-workflow/
            └── SKILL.md
```

Project-specific auto-learned skills under
`~/.omp/agent/managed-skills` remain OMP-owned mutable state. Move each useful
one into its owning repository after removing machine-specific assumptions.
Generic skills such as `ts-react-dead-code-sweep` live under
`modules/home/agents/skills/`.

### Installed skills

`docs-links` resolves every path below, so a renamed or deleted skill fails CI
instead of leaving a stale list.

| Skill | Tree | Origin |
|---|---|---|
| [`ts-react-dead-code-sweep`](../modules/home/agents/skills/ts-react-dead-code-sweep/SKILL.md) | generic | repository-authored |
| [`tui-visual-verification`](../modules/home/agents/skills/tui-visual-verification/SKILL.md) | generic | repository-authored |

`ts-react-dead-code-sweep` has no surface in this repository — it is a
cross-project skill, deployed to the global `~/.agents/skills` so it is
available whenever these machines work on a TypeScript project.

### Vendoring a third-party skill

Public skill text becomes trusted agent instructions when it lands in
`~/.agents/skills`. A vendored skill therefore carries a provenance marker
directly below its frontmatter naming the upstream repository, exact commit,
license, and every local change. Refresh by reviewing the upstream diff, never
by copying blindly.

### Turning a skill off

OMP owns skill selection. `skills.ignoredSkills` mutes matching skills,
`skills.includeSkills` makes an allowlist, `skills.enabled` is the global
switch, and `--skills=<comma-separated globs>` narrows one launch. Bare
`--no-skills` disables them for one launch. `ompu` refuses `--skills`, so an
untrusted session cannot widen its skill set.

Put a durable mutable-machine choice in `pkgs/omp-configured/config/plain-seed.yml`; put a
managed-session choice in `pkgs/omp-configured/config/defaults.yml`. A skill that should never fire
unprompted should set `disable-model-invocation: true`, leaving
`/skill:<name>` as its explicit entry point.

## Updating

The `update-pins` workflow refreshes repository-owned binary pins every six
hours. `ci/update-pins.sh` updates versions and hashes, a bot pull request
runs dispatched CI, and a green run merges itself. Pass package names to narrow
a manual refresh; for example, `ci/update-pins.sh omp` changes only OMP.
A red run remains open for curation when upstream bundled content changes.

A manual OMP bump is `ci/update-pins.sh omp`, or the same file edited by hand
to a specific release: the four asset hashes and the version are the whole
pin. Bumps consume upstream `can1357/oh-my-pi` releases directly; there is no
fork.

`omp-agents` regenerates the bundled agents from the pinned OMP binary. The
`omp-agent-references` check ensures every agent name referenced by managed
defaults still exists, so an upstream rename or removal fails the build rather
than silently misrouting a role.
