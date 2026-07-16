# OMP v17.0.0 capability field guide

> **Scope:** built-in upstream capabilities present in the packaged `omp`
> v17.0.0, audited 2026-07-15. Wrapper policy still matters: read the
> [launcher matrix](README.md#choose-the-correct-surface-first).

This page favors discoverability over implementation detail. The release links
identify when a capability materially appeared or changed during the audited
v16 and v17 series; the immutable v17.0.0 documentation links define the
packaged behavior.

## High-value “did you know?” workflows

### Isolate a complete work identity

`omp --profile <name>` isolates authentication, sessions, settings, and caches.
`OMP_PROFILE` selects the same root through the environment, and
`omp --profile work --alias omp-work` creates a shortcut.

Inside a profile, `/login <provider>` and `/logout <provider>` manage
provider-scoped credentials. `omp usage --redact` reports every authenticated
account without exposing full account IDs; `omp dry-balance` previews OAuth
account selection. See upstream
[Providers](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/providers.md)
and [Secrets](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/secrets.md).

In these dotfiles, use `code`'s usage widget instead of typing profile names:
`a` switches the visible `mine`/`mum` combination and every trusted launch gets
that selected `--profile`. `ompu` remains fixed to `untrusted`.

### Assign models by role instead of choosing one model for everything

OMP has role routes for the main session, smol work, slow reasoning, planning,
advisor review, and task-agent specialties. Edit role assignments with `/model`
or `Alt+M`; use `/switch` or `Alt+P` for a temporary session model; and use
`Ctrl+P` / `Shift+Ctrl+P` to cycle the configured quick-switch set. `/fast`
controls provider priority service, while `/advisor` controls the reviewer
runtime. Inspect shell-visible models with `omp models`.

The session can also:

- cycle thinking depth with `Shift+Tab` or pin it with `--thinking`;
- run a passive second-model review with `--advisor` or `/advisor`; and
- use provider priority service through `/fast` where supported.

These dotfiles manage the role map and fallback chains for generated launches;
plain `omp` remains mutable. See upstream
[Models](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/models.md).

### Change the shape of the work, not only the model

- `/plan [prompt]` makes the agent propose and review a plan before mutation;
  `/plan-review` reopens the latest review.
- `--prewalk` (with `--prewalk-into`) plans on the strong active model, then
  hands off to a fast/cheap model at the first edit/write once the todo list
  exists; `--plan-yolo` (with `--plan-yolo-into`) additionally auto-approves
  the plan. These replaced the `--reasoning-slide-*` flags in v16.5.0.
- `/goal`, `/goal budget <N>`, and `/guided-goal` maintain a persistent
  autonomous objective with a token budget.
- `/vibe [prompt]` enters a read-only director mode whose dedicated `vibe_*`
  tools create and manage persistent fast/good background workers.
- `/loop [count|duration] [prompt]` repeats the next prompt after each yield.
- `/queue <message>` schedules a follow-up while the current turn runs.
- `/btw <question>` asks an ephemeral side question with current context.
- `/tan <work>` starts a full background agent for tangential work.


### Delegate real work and inspect it live

The `task` tool launches typed subagents and can isolate them in git worktrees.
The Agent Control Center (`/agents`) shows live state and allows steering,
killing, reviving, and transcript inspection. From an enabled `eval` workflow,
`output(id)` retrieves task/agent output by ID. The essential `hub` tool unifies
peer messaging, background-job control, and supervised long-running processes;
background process/job state remains visible through `/jobs`.

Useful distinctions:

- `task` is for agent work and may produce an isolated patch;
- `todo` is structured plan state, not delegation;
- `/tan` is a convenient full background-agent side path; and
- `omp worktree` inspects or dry-runs cleanup of OMP-owned worktrees.


### Branch, fork, move, hand off, and resume sessions

OMP's transcript is a navigable tree, not a flat terminal log:

- `/branch` creates a new branch from an earlier message;
- `/tree` moves among branches;
- `/fork` creates and switches to a persistent copy;
- `/handoff [focus]` summarizes context into a new session;
- `/resume` switches sessions, while `--resume` can search by ID/path;
- `/rename` changes the current session title;
- `/move` starts fresh in another directory and leaves the old session
  resumable; and
- `/fresh` resets provider stream state without discarding the local transcript.

`/export` writes browsable HTML, while `/dump` copies the full textual
transcript. See the tagged
[session-operations reference](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/session-operations-export-share-fork-resume.md).

### Share a snapshot or collaborate live—with different trust models

`/share` publishes an end-to-end encrypted snapshot. The decryption key remains
in the URL fragment. `/collab` streams the running session through an encrypted
relay; a full link permits guest prompting/interrupts while `/collab view`
creates a read-only link. Guests can use `omp join <link>` or `/join <link>`.

The host still runs the model and every tool. A full collab link is therefore a
control credential and must be handled like a secret. See the tagged
[Collab](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/collab.md)
and
[session-sharing](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/session-operations-export-share-fork-resume.md#share)
docs.

### Diagnose and reshape context before it becomes a failure

- `/context` estimates tokens by source.
- `/compact` reduces or reshapes older context using selectable modes: `soft`
  and available `remote` paths summarize, while `snapcompact` archives history
  into dense bitmap images without an LLM call.
- `/shake elide` drops heavy tool/large-block content; `/shake images` drops
  image blocks.
- `/memory view|stats|diagnose|clear|enqueue` operates the persistent memory
  backend and mental-model bank.
- `/dump` preserves the transcript for inspection before destructive context
  maintenance.

See the tagged upstream
[Memory](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/memory.md) and
[Compaction](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/compaction.md)
references for the active backend and compaction modes.

### Use rich input without leaving the terminal

| Input | Meaning |
| --- | --- |
| ordinary text | Send a normal prompt |
| `@path` | Attach a text file, document, or image to the message |
| `/...` | Run or discover an interactive slash command |
| `!...` | Run a shell command through the terminal execution surface |
| `$...` | Run Python after the optional Python backend is installed |
| `#...` | Invoke a registered prompt action |
| hold `Space` | Push-to-talk speech transcription when STT is configured |
| `Ctrl+V` | Paste an image when available, otherwise clipboard text |

Prompt actions, clipboard images, and optional speech/evaluator runtimes depend
on the active configuration. Use `omp setup --help` to discover/check optional
dependencies rather than assuming they are installed.

### Give the agent more than file and shell access

The v17.0.0 tool ecosystem includes code-aware LSP operations,
document/archive reads, images, notebooks, browser automation, web search,
structured todos, subagents, and interactive operator questions. The
discoverable `eval` tool adds persistent language kernels when its runtimes are
enabled. Extensions and MCP servers can add further tools.

Notable release-backed additions include:

- browser ARIA snapshots/references in
  [v16.1.10](https://github.com/can1357/oh-my-pi/releases/tag/v16.1.10) and
  explicit selector/navigation waits in
  [v16.1.11](https://github.com/can1357/oh-my-pi/releases/tag/v16.1.11);
- opt-in persistent Ruby and Julia evaluator kernels in
  [v16.1.14](https://github.com/can1357/oh-my-pi/releases/tag/v16.1.14), then
  shared worktree isolation for evaluator agents in
  [v16.1.16](https://github.com/can1357/oh-my-pi/releases/tag/v16.1.16);
- TinyFish, DuckDuckGo, xAI, and Firecrawl search adapters in
  [v16.2.0](https://github.com/can1357/oh-my-pi/releases/tag/v16.2.0), plus
  multiple credential-free engines and aggregate search in
  [v16.4.3](https://github.com/can1357/oh-my-pi/releases/tag/v16.4.3);
- a project-scoped supervised-process surface — readiness probes, bounded logs,
  PTY input, restart policies, and optional `detached` survival across broker
  shutdowns — introduced as `launch` in
  [v16.5.0](https://github.com/can1357/oh-my-pi/releases/tag/v16.5.0) and merged
  into the essential `hub` tool in v17.0.0; and
- tagged tool contracts for
  [image inspection](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/tools/inspect_image.md),
  [image generation](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/tools/generate_image.md),
  [speech generation](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/tools/tts.md),
  and [evaluation](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/tools/eval.md).

In v17, custom, MCP, image-generation, and TTS tools are discoverable through
the default-on `xd://` virtual-device transport rather than all being exposed
as top-level schemas. Read `xd://` to list mounted devices, read a device URL
for its contract, and write that URL to invoke it. `/tools` shows what the
current session actually exposes; wrapper policy can remove or require approval
for any capability.

### Extend OMP without editing its core

OMP v17.0.0 supports several extension boundaries:

- TypeScript/JavaScript extensions and hooks via `-e`, `--hook`, discovery, or
  plugin packages;
- project/user skills, filterable with `--skills`;
- project/user rules, disableable with `--no-rules`;
- discovery diagnostics for both skills and rules;
- MCP servers managed through `/mcp`;
- marketplace plugins through `/marketplace`, `/plugins`, and
  `/reload-plugins`;
- custom models/providers in `models.yml`; and
- custom interactive components, overlays, keybindings, tool renderers, and
  status widgets.

Start with the tagged
[Extensions](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/extensions.md),
[Skills](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/skills.md),
[Rule matching](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/rulebook-matching-pipeline.md),
[MCP](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/mcp-config.md), and
[TUI integration](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/tui.md)
docs.

### Embed or automate the same agent

The binary is not limited to the interactive TUI:

- `-p` performs a one-shot request;
- `--mode json` emits structured events;
- `--mode rpc` and `--mode rpc-ui` expose protocol-mode execution;
- `omp acp` serves Agent Client Protocol over stdio;
- `omp auth-broker` and `omp auth-gateway` separate credential custody from
  remote/headless inference; and
- hooks/extensions can observe and alter lifecycle events.

See the tagged
[RPC](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/rpc.md) and
[auth broker/gateway](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/auth-broker-gateway.md)
docs; use `omp acp --help` for the packaged ACP server surface.

### Inspect OMP itself before writing another wrapper

Use the existing diagnostics as design inputs:

```console
$ omp read <path-or-url>       # exact read-tool behavior
$ omp gallery                 # renderer lifecycle gallery
$ omp grep --help             # grep-tool test surface
$ omp search --help           # search-provider test surface
$ omp models --json           # resolved model catalog
$ omp usage --json            # provider quota state
$ omp stats --summary         # usage summary
$ omp plugin doctor           # plugin health
$ omp gc                      # storage cleanup dry-run
$ omp worktree clear --dry-run
```

Inside a session, `/debug`, `/tools`, `/context`, `/extensions`, `/agents`, and
`/jobs` expose live state. These are usually better than inferring behavior from
source or adding a duplicate diagnostic to `code`.

## Release-note radar through the pinned v17 line

This is a compact audit of operator-visible changes recorded between v16.0.0
and v17.0.0, not a replacement for the current-feature sections above. Release
notes can bundle or migrate older behavior, so an entry means “recorded in this
release,” not necessarily “first invented here.”

- [v17.0.0](https://github.com/can1357/oh-my-pi/releases/tag/v17.0.0) —
  the essential `hub` tool replaces separate `irc`, `job`, and `launch` tools;
  discoverable tools move to default-on `xd://` virtual devices; plan/preview
  resolution moves from `resolve` to `xd://propose`, `xd://resolve`, and
  `xd://reject`; BM25 tool discovery and its settings are removed; and the SSH
  agent tool is removed while the `ssh://` protocol and `omp ssh` remain.
  This release also adds opt-in per-agent prewalk and `edit.enforceSeenLines`,
  defaults `astGrep.enabled` off, and renames `dev.autoqa.consent` and
  `todo.reminders.max` to `dev.autoqaConsent` and `todo.remindersMax`.
  These dotfiles explicitly keep both `astGrep.enabled` and
  `edit.enforceSeenLines` on to preserve the prior structural-search and
  hashline-safety posture.
- [v16.5.2](https://github.com/can1357/oh-my-pi/releases/tag/v16.5.2) —
  proactive rate-limit header ingestion for all supported providers with
  multi-account rotation before 429s, a `generate_image.enabled` setting and
  whitelist gating for the image tool, duration-suffix `--max-time` values,
  and a breaking agent-tool change: the separate `selector` parameters were
  removed from `read` and `grep` (ranges/modes are appended to `path`).
- [v16.5.1](https://github.com/can1357/oh-my-pi/releases/tag/v16.5.1) —
  organization-scoped Anthropic credential and usage partitioning (visible in
  `/usage`, `/logout`, and `omp token --list`), Cursor account usage in
  `omp usage`, and `models.yaml` accepted as a custom-catalog fallback.
- [v16.5.0](https://github.com/can1357/oh-my-pi/releases/tag/v16.5.0) —
  the `--prewalk` plan-then-hand-off flow replacing the `--reasoning-slide-*`
  flags, a compact session-only model picker on `Alt+P` with `@` role search,
  a gated project-scoped `launch` tool for shared long-running services
  (including `detached` launches), redesigned Agent Hub cards, the
  `tui.scrollbackRebuild` setting, and removal of the Bing/Yahoo scraping
  search providers.
- [v16.4.8](https://github.com/can1357/oh-my-pi/releases/tag/v16.4.8) —
  Home/End navigation in the model browser and `c` to copy the edited plan from
  plan review.
- [v16.4.6](https://github.com/can1357/oh-my-pi/releases/tag/v16.4.6) —
  fallback-chain editing in the model hub, `/queue` plus `->`/`=>` shorthand,
  usage-cache invalidation, and per-model TPS/TTFT history.
- [v16.4.3](https://github.com/can1357/oh-my-pi/releases/tag/v16.4.3) —
  `/vibe`, credential-free multi-engine web search, PCRE2 grep fallback, and a
  clearer interactive-terminal hint for `omp acp`.
- [v16.4.0](https://github.com/can1357/oh-my-pi/releases/tag/v16.4.0) —
  the `max` thinking tier, Responses Lite transport, and Novita provider/login.
- [v16.3.12](https://github.com/can1357/oh-my-pi/releases/tag/v16.3.12) —
  `#<number>` PR/issue autocomplete to `pr://`/`issue://` internal URLs.
- [v16.3.0](https://github.com/can1357/oh-my-pi/releases/tag/v16.3.0) —
  Anthropic server-side fallback configuration, subagent soft-budget notices,
  and large-session performance work.
- [v16.2.0](https://github.com/can1357/oh-my-pi/releases/tag/v16.2.0) —
  `ssh://` reads/searches/writes, `/move`, debugger-adapter discovery, file
  move/delete edits, document-conversion caching, remote compaction controls,
  LiteLLM discovery, and additional search providers.
- [v16.1.16](https://github.com/can1357/oh-my-pi/releases/tag/v16.1.16) —
  evaluator-agent worktree isolation, the eval tool's single-cell contract,
  and a fullscreen resume picker.
- [v16.1.14](https://github.com/can1357/oh-my-pi/releases/tag/v16.1.14) —
  opt-in persistent Ruby and Julia evaluator kernels.
- [v16.1.10](https://github.com/can1357/oh-my-pi/releases/tag/v16.1.10) and
  [v16.1.11](https://github.com/can1357/oh-my-pi/releases/tag/v16.1.11) —
  browser accessibility snapshots/references and explicit selector/navigation
  waits.
- [v16.0.10](https://github.com/can1357/oh-my-pi/releases/tag/v16.0.10) —
  QR codes and separately hosted web-client deep links for collab.
- [v16.0.1](https://github.com/can1357/oh-my-pi/releases/tag/v16.0.1) —
  typed task-agent roles, plan-on-startup, image auto-resize, configurable
  keybindings, PR-aware review, and clipboard-image paste among a large bundle
  of carried-forward additions.

## Default keybindings worth remembering

Run `/hotkeys` for the authoritative active map: user remaps and extensions can
change it. The pinned defaults include:

| Chord | Action |
| --- | --- |
| `Ctrl+P` / `Shift+Ctrl+P` | Cycle configured quick-switch models forward/backward |
| `Alt+P` | Pick a temporary model |
| `Alt+M` | Open the role-model selector |
| `Alt+Shift+P` | Toggle plan mode |
| `Shift+Tab` | Cycle thinking level |
| `Ctrl+T` | Show/hide thinking blocks |
| `Ctrl+O` | Expand/collapse tool output |
| `Ctrl+R` | Search prompt history |
| `Ctrl+G` | Edit the draft in `$VISUAL`/`$EDITOR` |
| `Ctrl+Q` or `Ctrl+Enter` | Queue a follow-up message |
| `Alt+Up` | Return a queued message to the editor |
| `Alt+R` | Retry the last failed turn |
| `Ctrl+V` | Paste image, falling back to clipboard text |
| hold `Space` | Push-to-talk speech transcription |

Keybindings live in `~/.omp/agent/keybindings.yml`; see the tagged
[Keybindings](https://github.com/can1357/oh-my-pi/blob/v17.0.0/docs/keybindings.md)
reference.

## Built-in interactive slash-command index

This table catalogs the v17.0.0 built-ins. `/help` remains authoritative because
extensions may add commands and the active mode may restrict them.

| Area | Commands |
| --- | --- |
| Models and work mode | `/model`, `/switch`, `/fast`, `/advisor`, `/plan`, `/plan-review`, `/vibe`, `/goal`, `/guided-goal`, `/loop`, `/queue` |
| Side work | `/btw`, `/tan`, `/pause`, `/retry` |
| Sessions | `/new`, `/fresh`, `/drop`, `/session`, `/resume`, `/branch`, `/fork`, `/tree`, `/handoff`, `/rename`, `/move` |
| Context and memory | `/context`, `/compact`, `/shake`, `/memory` |
| Export and collaboration | `/copy`, `/dump`, `/export`, `/share`, `/collab`, `/join`, `/leave` |
| Authentication and usage | `/setup`, `/login`, `/logout`, `/usage`, `/stats` |
| Agent operations | `/todo`, `/jobs`, `/agents`, `/tools`, `/force` |
| Extensibility | `/extensions` (alias `/status`), `/mcp`, `/marketplace`, `/plugins`, `/reload-plugins`, `/omfg` |
| Environment and UI | `/settings`, `/browser`, `/ssh`, `/hotkeys`, `/changelog`, `/debug` |
| Lifecycle | `/exit`, `/quit` |

Less obvious semantics:

- `/fresh` changes provider stream identity but keeps the local transcript;
  `/new` starts a new session; `/drop` deletes the current session first.
- `/branch` selects a prior message as a branch point; `/fork` creates a new
  persistent file; `/handoff` starts a summarized successor.
- `/force <tool> [prompt]` makes the next turn request a specific tool.
- `/omfg <complaint>` forges a Time-Traveling Stream Rule intended to prevent a
  recurring streamed-output behavior.
- `/settings` opens upstream settings only under plain `omp`. The managed
  extension intercepts it under `omp-managed`/generated managed launches and
  points to repository-owned edit paths.

Source: tagged upstream
[built-in slash-command registry](https://github.com/can1357/oh-my-pi/blob/v17.0.0/packages/coding-agent/src/slash-commands/builtin-registry.ts).
