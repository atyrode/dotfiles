# Agent tools

OMP, agents, rules and generic skills are part of the Home Manager profile.
`atyrode apply` activates them.

## Ownership

Dotfiles owns deployment and the operator's authored configuration:

- the pinned OMP package and generated Zsh completion;
- the managed OMP defaults and enforced policy;
- the curated plain-omp seed and its drift-aware activation step;
- the pinned bundled agents, global generic skills, and managed-settings
  guard;
- the `omp` passthrough, the `omp-managed` managed-layering launcher, the
  restricted `ompu` launcher;
- personal policy from `modules/home/agents/AGENTS.md`, rendered by
  `atyrode context render` into `$XDG_CONFIG_HOME/agents/AGENTS.md` (default
  `~/.config/agents/AGENTS.md`) with minimal generation provenance, not a
  machine inventory; Home Manager links the default OMP user path and optional
  Claude/Codex adapters to it (see [Instruction architecture](#instruction-architecture));
- Claude Code's user-scope `~/.claude/settings.json` permission rules; and
- mise itself, with no globally declared mise tools.

OMP owns execution: role resolution, retries, live credential selection,
compaction, terminal protocols, and mutable runtime data such as authentication,
sessions, caches, onboarding state and machine-local UI state. Dotfiles supplies
its baseline policy, not a replacement runtime. Secrets never belong in this
repository or the Nix store.


Activation does not rewrite or back up pre-existing mutable paths before Home
Manager links managed configuration and skills. If
`checkLinkTargets` reports a collision, inspect the exact path named by Home
Manager, preserve wanted content outside the managed namespace, move or remove
the collision, and rerun `atyrode apply`.

Rules and the settings guard are assembled into a read-only OMP extension-package
root in the Nix store and injected explicitly by every managed session. Agents
remain built into OMP, preserving their native source identity and inheritance.
Named profiles and custom `PI_CODING_AGENT_DIR` roots receive the same platform
assets without sharing authentication, sessions, or caches.

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
fleet/authentication inventory out of this file does not remove OMP's
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
discovery reference below documents version 18.1.14, commit
[`daf07999c2fee9b22edc7bf8fea1fb6272e0df5e`](https://github.com/can1357/oh-my-pi/commit/daf07999c2fee9b22edc7bf8fea1fb6272e0df5e).
These source links are historical; the maintained checks below exercise the
current pin. Recheck upstream source when changing discovery behavior:

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

The existing `agent-policy` action also runs this acceptance against the
repository's **current candidate** `AGENTS.md`. Runtime, common source and
personal source come from one action
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

### Publication is not activation

A source PR publishes policy and generated repository outputs. Separately
authorized Home Manager activation
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
the configured zsh, OMP and the rest of that profile, rather than
a separate container tool list. Build and exercise it locally with:

```sh
nix build .#development-image --print-build-logs
docker load --input result
image="$(nix eval --raw .#development-image.imageName):$(nix eval --raw .#development-image.imageTag)"
docker run --rm -it "$image"
nix shell --inputs-from . nixpkgs#tmux nixpkgs#python3 \
  --command python3 ci/verify-development-image.py "$image"
```

The smoke checks the genuine credential-free OMP terminal state, the runtime
contract and the offline build users. It neither creates credentials nor
launches model inference.

The default command is the real login zsh, running as `developer` (UID/GID
1000) in `/workspace`. Supplying another command retains home activation and
the same user. A project may be bind-mounted at `/workspace` when its
permissions allow UID 1000 access. Do not mount an operator home, credentials,
host Nix store or Docker socket as part of the default environment.

Every start runs Home Manager activation, including its generation management,
managed-file conflict checks, OMP and Codex seeds, migrations and context
rendering. Automatic speech-model downloads, Ollama, resource-guard and ssh-agent
services are disabled; no systemd manager or model supervisor is started.
Provider authentication is not bundled. Native tools remain
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
architectures. Before driving a multibyte cursor edit, it waits for Zsh's line
editor to enable bracketed paste; echoed text alone does not prove the editor
is reading keys. Green main publishes those tested archives, without rebuilding,
to immutable revision tags under `ghcr.io/atyrode/development` and a
multi-platform index. The publication job's summary and
`development-image-reference` artifact give the immutable digest for consumers.
Retries reuse matching platform and index digests and refuse mismatches.
Publication requires anonymous pulls and standalone startup; initial GHCR
package visibility may need to be set to public in GitHub package Settings.
It does not activate fleet hosts or redeploy consumers.

## OMP commands

Three commands make up the operator surface:

| Command | Intended use | Configuration |
| --- | --- | --- |
| `omp` | Mutable daily driver | The operator's writable OMP configuration, apart from the blocked `update` command and profile-aware resume lookup |
| `omp-managed` | Managed launch target | Platform extensions, managed defaults, enforced policy, and any generated one-shot `--config` |
| `ompu` | Deliberately untrusted repositories | Dedicated state, sanitized credentials, restricted integrations, and approval-gated shell/task use |

Use `omp --help` and `omp <command> --help` for the pinned upstream command
surface. [Upstream documentation](https://github.com/can1357/oh-my-pi/tree/main/docs)
may describe behavior newer than the repository pin. This document is
authoritative for `omp-managed` and `ompu`.

Plain `omp` executes upstream OMP directly, with no managed extension, defaults,
or policy overlay. `omp update` is blocked so it cannot shadow the Nix-pinned
binary. For a UUID or UUID prefix passed to `--resume` or `--restore`, the
launcher searches the default and named-profile session roots and injects the
sole matching profile; explicit state or profile selection wins, and ambiguous
matches require `--profile`.

`omp-managed` loads configuration in this order:

1. OMP's writable machine config at `~/.omp/agent/config.yml`, with
   `config.yaml` selected only when the canonical filename is absent;
2. the Nix-managed portable defaults;
3. native project configuration from `<cwd>/.omp/settings.json` and then
   `<cwd>/.omp/config.yml`;
4. optional machine-local overrides at `~/.config/omp/local.yml`;
5. one-shot `--config` overlays;
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
values, boolean `--flag=value` spellings and the `--` prompt boundary. Rendering
options `--motion`, `--spinner-interval` and `--max-fps` consume required values
and pass through unchanged. Native `bash`, `sh` and `zsh` subcommands bypass
launch configuration. Restricted launchers reject state/resource/approval
overrides only in flag positions.
`nix build --no-link .#checks.x86_64-linux.omp-wrapper` checks argv preservation,
restricted boundaries, native diagnostics and live CLI grammar drift; `omp-stack`
additionally exercises real RPC/ACP startup. Neither requires provider credentials.

`nix build --no-link .#checks.x86_64-linux.omp-interactive` covers the actual
terminal composer: paste a PNG and observe an image attachment through raw OMP
with explicit cwd, plain bare/no-session launches, and managed and restricted
launchers. It uses isolated homes
with `startup.setupWizard: false`; otherwise first-run onboarding correctly
intercepts input before the composer is available. This is attachment/UI proof,
not a model image-understanding turn, and does not activate a machine.

The diagnostic now reports current isolation keys (`task.isolation.enabled`
and `isolation.backend`), not the retired combined `task.isolation.mode`.
Enablement permits per-spawn requests; it is not a default to isolate every task.
The persistent plain-OMP seed writes the same current keys. It no longer seeds
the retired `task.isolation.mode` or `providers.memoryModel`: OMP migrates both
away and deletes them, so seeding them only produced `deleted-locally` drift.
OMP's migration prefers an existing `task.isolation.enabled` over a legacy
`mode`, so a machine whose config still holds an unmigrated `mode: none`
opt-out is seeded back to enabled; set `task.isolation.enabled: false` there.

Managed defaults and the plain seed disable `startup.checkUpdate`: Nix owns
upgrades and repository pin-update automation still reports release drift.
This removes the interactive upstream release reminder (and its startup network
check), not the pinned-version check or the repository's latest-release warning.
The ordinary seed merge preserves an operator's divergent local preference.

OMP 18.18.7 splits `codexResets.autoRedeem` into `autoRedeem5h` and
`autoRedeemWeekly`. Managed defaults and the plain seed set both to `"no"`,
preserving the existing no-automatic-credit-spending preference. OMP migrates
legacy values to both windows unless a window already has an explicit value.
Before its three-way merge, the plain seeder translates that owned preference
in both the live configuration and the prior seed baseline, removing the legacy
key. Custom boolean/tri-state choices and explicit window values stay local
choices instead of being shadowed by newly seeded defaults.

### Agent role identity and fallback

Managed defaults and fresh plain-OMP seeds configure only OMP's shared roles:

| Shared roles | Routine model | Effort |
| --- | --- | --- |
| `default`, `task` | Sonnet 5.5 | medium |
| `smol`, `memory` | Haiku 5.5 | medium |
| `slow`, `plan` | Sonnet 5.5 | high |
| `advisor`, `tiny`, `commit`, `widget` | Haiku 5.5 | low |
| `vision` | Sonnet 5.5 | low |

The bundled OMP 18.22.2 agents retain their upstream prompts, tools and routing:

| Bundled agent | Native model declaration | Native effort declaration |
| --- | --- | --- |
| `task` | `@task` | auto |
| `scout` | `@smol` | medium |
| `sonic` | `@smol` | medium |
| `reviewer` | `@slow` | inherited |
| `security-reviewer` | none; native inheritance | inherited |

OMP 18.22.1 removed `yield` from agents without an output schema; those
agents return their final message instead. Schema-bearing specialists retain
their structured `yield` contract.

There is no bundled `librarian`. Agent names are not additional model roles:
do not create `scout`, `sonic`, `reviewer`, `security-reviewer` or `librarian`
role rows, custom replacement agents, or per-agent model overrides to route
them. Neither source layer emits or owns `task.agentModelOverrides`.
OMP 18.20.3 [removed `seance`, `/seance`, and the task tool's `sourceSession`
parameter](https://github.com/can1357/oh-my-pi/blob/v18.22.0/packages/coding-agent/CHANGELOG.md#18203---2026-11-16);
managed profiles do not install a replacement or replay shim.

An existing explicit writable override can still take precedence; source
publication does not remove it. See [seed preservation](#seeded-plain-omp-defaults).

Role-keyed fallback chains follow native shared-role identity rather than an
agent-name alias policy. Sonnet default/task fall back to Sol 6.2 then Terra
6.1 at medium; slow/plan use the same cross-provider order at high. Haiku
`smol` falls back to Luna at medium, and advisor uses Luna at low. Managed
tiny/commit have explicit empty chains; the plain seed permits Luna-low fallback
for tiny/commit. Both sources keep Sonnet-low vision on its own empty chain,
without a GPT-quota dependency. Both sources give `widget`
and `memory` their own explicit empty chains, so neither inherits the default
chain or escalates to a utility fallback. OMP 18.20.1 widget calls use
`disableReasoning: true`: the declared low suffix is inert for those calls.
Hosted memory requests use the native `memory` role at Haiku medium, not smol
or tiny. Mnemopi consolidation is deterministic (`llm_used: false`), not an
LLM call. The memory budget does not enable a backend or learning: managed
memory stays off, the plain seed retains mnemopi, and existing
enablement/autolearn preferences are unchanged.
Empty chains prevent inheriting the default chain. No routine chain silently
promotes to Opus, Astra or Fable, and a main-role high/max choice is not a
utility-role effort setting. Advisor enablement and other local feature
preferences remain separate from model selection.

Usage-aware fallback retains the 5% reserve with confirmation, explicit account
pools and provider capability/consent checks. It does not grant access to a new
account or automatically spend either reset-credit window. A fallback entry
is not evidence that a provider is currently served or above reserve.

The standalone generator retains explicit lane, tier and effort controls and
the eight latest model families, but removes automatic deliberative tier
promotion. Routine Anthropic-capable routing uses Sonnet medium; eligible
OpenAI-only routing uses Sol 6.2 medium. The curated `sol` and `astra` shortkeys
resolve to `openai-codex/gpt-6.2-sol` (smart, tier 3) and
`openai-codex/gpt-6.2-astra` (elite, tier 4); their pool and quota bucket stay
unchanged. Explicit strong/elite selections remain visible choices, including
Opus, Astra and Fable where served. The standalone bridge's reviewed catalogs
are not upgraded by the dotfiles OMP pin.

Routine `plan`/`slow` high is not a fixed effort for every profile: the explicit
main-effort choices minimal, low, medium, high, xhigh and max map respectively
to minimal, medium, high, xhigh, xhigh and max, subject to model/local capability
clamps. This changes effort, never the selected model tier.

`omp-managed config managed --json` reports owned shared selectors and chains,
not proof of native child retries. Historical OMP 18.1.14 role-identity
failures cannot establish
current behavior. When changing routing or the OMP pin, use disposable
credential-free state and a deterministic local provider: spawn real bundled
task/scout/sonic/reviewer children, fail shared leads, and inspect child calls
and outputs for the intended role, effort and role-specific fallback,
including empty chains. Check security-reviewer native inheritance without
adding aliases. No paid provider call or host activation is required.
`omp-stack` covers managed ownership and retention of writable local overrides;
`omp-seed` covers fresh routing and three-way preservation, not live cleanup.
`omp-native-routing` automates this offline experiment for both raw and managed
launchers, including strict native specialist output schemas. It preserves the
bundle's source identity rather than installing same-name extension copies.

`atyrode runtime run local-qwen` emits only native shared `modelRoles`, all
pointing to the selected local Qwen model, including advisor if later enabled.
Widget and vision declare that local selector at low and memory at medium,
each with its own empty fallback chain; global model fallback remains disabled.
Its isolated profile disables model fallback and advisor by default, retains
the local compaction reserve, and does not forward cloud broker credentials.
It never needs named-agent roles or per-agent overrides to select local work.

### Speech models

Speech uses OMP's native first-use model downloads. Dotfiles no longer
prefetches speech models at activation or manages a separate speech cache;
existing downloaded caches remain untouched. A first use on an uncached
machine can require a download. Publishing this change does not activate any
host or download/remove its models.

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
printing the token. The broker and its clients retain their tool-owned state.

Add Anthropic/OpenAI OAuth accounts with the broker's supported flow:
`omp auth-broker login <provider> --via=alex@<broker host>`.
Add API-key providers without exposing the key in argv:

```sh
atyrode auth broker add-api-key deepseek
```

Both paths mutate the canonical broker, so authorized connected clients see
the new account on their next refresh; no credential file is copied between
machines.
Token rotation follows [the secret owner](secrets.md#declaring-a-secret), not
an independent agent-tool ceremony.

## GitHub App identity for agents

The agents on dev-01 act on GitHub as a GitHub App owned by the `tyrode-dev`
organisation, installed on `tyrode-dev/myParcelle` only, not as the operator:
their `gh` calls spend the installation's rate limit (15,000 requests an hour
on an Enterprise Cloud organisation, 5,000 otherwise) and their commits, pull
requests and comments carry the App's bot. [`fleet/github-app.json`](../fleet/github-app.json)
names the App; [`modules/nixos/gh-app-token.nix`](../modules/nixos/gh-app-token.nix)
defines nothing until its `enabled` is true, which happens in the pull request
that records the App's ids after the operator has created it.

The OMP broker above is not involved: it vaults model-provider credentials and
cannot mint GitHub tokens. The App's private key is a per-machine, prompted
clan var (`gh-app`, [secrets](secrets.md#declaring-a-secret) owns rotation),
placed `0400` for the `gh-app` system account. `gh-app-token.service` runs as
that account every thirty minutes, signs a ten-minute JWT and exchanges it for
a one-hour installation token limited to the listed repositories, written to
`/run/gh-app-token/token` for the operator account to read. The key never
leaves that account's file and no agent receives it.

Inside `~/lanes/` (and wherever `GH_IDENTITY=app`) the `gh` on PATH is a shim
that reads the token file on every call, so nothing refreshes per session; with
no token it fails rather than use the operator's `gh auth` login.
`GH_IDENTITY=operator` opts out. A Git include scoped to `~/lanes/` sets the
bot's name and noreply address, turns local signing off (the signing key says
a commit is the operator's), fetches and pushes over HTTPS and serves the same
token as its credential. Everywhere else the operator's own credentials apply
unchanged. An installation token cannot call `/user`: `gh auth status`,
`--author @me` and `--assignee @me` fail under it by design.

## State ownership

| State | Owner |
| --- | --- |
| `~/.omp/agent/` and named profile roots | OMP/operator mutable configuration, authentication, sessions, and UI state; the one exception is `~/.omp/agent/AGENTS.md`, a Home Manager symlink to the generated agent context |
| `~/.omp/auth-broker.token` | Home Manager link to the `omp-auth-broker` clan var sops-nix places; the shared bearer token the broker checks and every client sends, mode `0600` |
| `/run/gh-app-token/` | `gh-app-token.service`; the renewed installation token and its expiry, group-readable by the operator account, gone at reboot |
| `$XDG_CACHE_HOME/atyrode/omp-auth-broker/` | Broker client snapshot cache |
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

The source seed no longer emits per-agent overrides or named-agent special
roles. Fresh configurations use the native grid above. For an existing
configuration, removal from the seed retires ownership; it does not delete
the live leaf, even if that leaf matched the old seed. Existing explicit
`task.agentModelOverrides` and custom role rows therefore remain operator-owned
until a separately authorized local cleanup. Untouched still-seeded role
leaves follow the new defaults; deliberate shared-role edits and unrelated
preferences remain local and reviewable.
Fresh and untouched seeded `defaultThinkingLevel` intentionally moves from
`auto` to `medium`; a deliberate local `auto` change remains reviewable drift
under the same three-way merge. No per-agent effort declaration is rewritten.

Before explicitly removing old live routing, compare each override and custom
agent file with the intended native shared role, effort and fallback chain.
Review wanted local behavior instead of converting old agent aliases into new
custom roles or resetting unrelated preferences. Removing custom files and
writable overrides is a local migration, not an effect of publication,
catalog regeneration, or activation's ordinary three-way seed merge.

Inspect the supported whole-setting records before an approved cleanup:

```sh
omp config get modelRoles --json
omp config get retry.fallbackChains --json
omp config get task.agentModelOverrides --json
```

After confirming the intended shared roles and fallbacks, an authorized
native-routing cutover clears only the retired override record with
`omp config reset task.agentModelOverrides`. Review custom definitions under
`~/.omp/agent/agents/` (or the corresponding profile root) and migrate their
callers before retiring them; do not publish a private file inventory.

`--reset-all` intentionally resets still-seeded preferences; it is not the
native-routing cleanup command and does not delete retired unowned leaves.

The seed may overlap keys owned by managed launchers: `defaults.yml` and
`policy.yml` layer above the machine configuration, so seeded values cannot
change managed behavior. The session guard blocks `/settings` and `cfg://`
writes to Nix-owned keys (including session overrides and `/save`); `cfg://`
reads and writes to unmanaged keys remain available. It never rolls the shared
writable configuration back to a startup snapshot. Seed resets and
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

## Session archive

Home Manager configures a restic archive of available OMP, Codex and Claude
session sources under the registry's stable host identity, into one shared
Cellar-backed repository. restic is the whole mechanism: no service or catalog
sits between the session files and the repository, so recovery needs only
restic and the repository password. Actual archival requires the placed
environment and a successful push; installing a timer is not evidence of
either. The archive is append-only: nothing runs `restic forget` or `prune`,
and the repository is created once by the operator (`restic init`), never by a
timer.

[`modules/shared/omp-session-archive.nix`](../modules/shared/omp-session-archive.nix)
owns provisioning; [Secrets](secrets.md#declaring-a-secret) owns the shared
`omp-session-archive` var and its `babel-custody` inputs. Home Manager links the
placed mode-600 environment file at `~/.config/omp-session-archive/restic.env`;
the file names the repository, the repository password file and the object-store
credential, and no credential is ever an argument.

An `omp-session-archive` systemd user timer (launchd agent on macOS) runs the
`omp-session-archive-push` wrapper hourly. It archives, when they exist,
`~/.omp/agent/sessions`, `~/.omp/agent/blobs`, `~/.claude/projects`,
`~/.codex/sessions` and Codex's `history.jsonl` and `session_index.jsonl`,
tagged `omp-sessions`, skipping cache directories; auth files and databases
under those homes are not archived. The timer's start condition is
`~/.config/omp-session-archive/restic.env`, so it arms only on a configured
machine. systemd reads that condition when the timer starts, and the unit does
not change when the file appears, so `atyrode apply` starts the timer after
every activation; `systemctl --user start omp-session-archive.timer` arms one by
hand. To see why a timer is not armed, `systemctl --user status
omp-session-archive.timer` reports it inactive and names the unmet condition,
and `journalctl --user -u omp-session-archive.timer` keeps the same line.

macOS has no equivalent condition, so there the wrapper's own check is the whole
gate. With no `restic.env` the wrapper prints one line and exits 0 -- which is
also what a hand-run `omp-session-archive-push` does on any unconfigured machine
-- so an unconfigured machine is a no-op rather than a failing unit; when the
machine is configured and the push fails, a missing restic repository included,
it exits nonzero and the failure stays visible. After a successful push the
wrapper stamps `~/.local/state/omp-session-archive/last-success` with one
ISO-8601 UTC line, and `atyrode apply` reads that stamp to warn when the archive
is unconfigured, has never succeeded here, or has not succeeded within 48 hours.

To inspect the archive, source the environment file and use restic directly:
`restic snapshots --tag omp-sessions`, `restic check` for integrity, and
`restic restore` for recovery. The previous Babel-written archive remains in its
own repository path in the same bucket; reading it needs the restic password and
payload key ring still held in the `babel-custody` var.

These commands have different effects: listing/status inspect state, integrity
verification accesses the configured repository, and push writes the live
archive. Documentation of a command is not permission to run live archive
writes, destructive recovery, key rotation or activation.

## Skills

Generic cross-project skills belong in `modules/home/agents/skills/`; Home Manager
joins them with immutable package-owned skills and links the shared tree to
`~/.agents/skills`. OMP and Codex discover that user root natively. Claude Code
uses `~/.claude/skills`, so Home Manager exposes the same store tree there through
recursive symlinks, not another authored copy. Unrelated local skills remain
tool-owned; colliding managed paths stop activation rather than being overwritten.
Custom harness configuration roots and disabled discovery need separate review.

Discovery sources for the packaged versions:
[OMP 18.2.3 Agent Dirs](https://github.com/can1357/oh-my-pi/blob/v18.2.3/packages/coding-agent/src/discovery/agents.ts)
scans `.agent/skills` and `.agents/skills` at home and along project ancestors;
[Codex 0.153.4 host roots](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/ext/skills/src/host_roots.rs)
adds `~/.agents/skills` at user scope; Claude Code 2.1.245's packaged loader
resolves its user configuration directory's `skills` child, matching its
[documented personal skills route](https://code.claude.com/docs/en/skills#where-skills-live).

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
| [`update-check`](../modules/home/agents/skills/update-check/SKILL.md) | generic | repository-authored |

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
hours. `ci/update-pins.sh` updates versions and hashes, the workflow approves
the bot pull request's parked `ci-gate` and `agent-policy` runs, and a green
pair merges itself. Pass package names to narrow a manual refresh; for
example, `ci/update-pins.sh omp` changes only OMP.
A red run remains open for curation when upstream bundled content changes.
Commits pushed onto that open PR survive later refreshes that compute the same
pins; a newer upstream release replaces the branch with a fresh bump.

A manual OMP bump is `ci/update-pins.sh omp`, or the same file edited by hand
to a specific release: the four asset hashes and the version are the whole
pin. Bumps consume upstream `can1357/oh-my-pi` releases directly; there is no
fork.

When the pin PR has been open for more than a day, the workflow's
`report-stalled` job opens the issue "Pin refresh PR is not landing". The issue
names the required checks that are missing or not green on the PR head, any
parked `action_required` runs, conflicts with `main`, and a disabled
auto-merge. Each refresh rewrites the issue, and it closes once no pin PR has
been open that long.

The generic [`update-check`](../modules/home/agents/skills/update-check/SKILL.md)
skill is the agent-side counterpart. Its single read-only command compares
these pins and this machine's OMP and Codex
with the latest releases, and it reports a pending pin PR.
The personal policy runs it at most once per session. When nothing is
available it says nothing; otherwise it asks the operator before anything is
bumped.

`omp-agents` exposes the pinned binary's bundle for inspection and checks,
without fixing its size. Managed launchers use OMP's built-in agents directly,
not extension copies that would shadow native identity.
`omp-agent-references` rejects source per-agent overrides and non-native shared
role rows, validates disabled-agent references against that bundle, and checks
that role-keyed fallback chains have declared shared selectors.
