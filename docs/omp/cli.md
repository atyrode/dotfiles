# Plain OMP v17.0.1 CLI reference

> **Scope:** this page is a snapshot of the packaged **upstream `omp` v17.0.1**
> executable, audited 2026-07-16. It is not a promise that `code`,
> `omp-managed`, or `ompu` preserve every flag unchanged. See the
> [launcher matrix](README.md#choose-the-correct-surface-first) first.

## Launch shape

```text
omp [COMMAND]
omp [FLAGS] [MESSAGES...]
```

A message may contain ordinary text or an `@path` file/image mention. With no
shell command, OMP starts the coding-agent session. Use `-p` for one-shot
non-interactive execution.

### Model and routing

| Flag | Effect |
| --- | --- |
| `--model <selector>` | Select a model by fuzzy name or `provider/model`; this is preferred over legacy `--provider` |
| `--models <a,b,...>` | Restrict the models available to `Ctrl+P` cycling |
| `--smol <selector>` | Override the lightweight/smol role for this process |
| `--slow <selector>` | Override the thorough/reasoning role for this process |
| `--plan <selector>` | Override the planning role for this process |
| `--prewalk` | Start on the active model, then hand off to a fast/cheap model at the first edit/write after the plan's todo list exists (default off; `prewalk.enabled`) |
| `--no-prewalk` | Disable prewalk even when `prewalk.enabled` is set |
| `--prewalk-into <selector>` | Target model for the prewalk handoff (defaults to the `smol` role) |
| `--plan-yolo` | Force read-only plan mode at start, auto-approve the first plan proposal, then implement it on the `--plan-yolo-into` model |
| `--plan-yolo-into <selector>` | Target model for plan-yolo execution (defaults to the `smol` role) |
| `--provider <id>` | Legacy provider selector; prefer `--model` |
| `--api-key <value>` | Supply a process-local credential override |
| `--thinking <level>` | `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, or `auto` |
| `--advisor` | Enable the second-model reviewer that injects notes into the main session |

### Session, state, and prompt

| Flag | Effect |
| --- | --- |
| `--profile <name>` | Use an isolated root for auth, sessions, settings, and caches |
| `--alias <command>` | Create a shell shortcut for the selected profile and exit |
| `--cwd <path>` | Set the launch working directory |
| `-c`, `--continue` | Continue the terminal breadcrumb or most recent session |
| `-r`, `--resume [id-or-path]` | Resume by prefix/path, or open the picker when no value is supplied |
| `--session-dir <path>` | Override session storage and lookup |
| `--no-session` | Run ephemerally without saving the session |
| `--system-prompt <text-or-file>` | Replace the default coding-agent system prompt |
| `--append-system-prompt <text-or-file>` | Append to the system prompt |
| `--config <file>` | Add a one-run `config.yml`-style overlay; repeatable and later overlays win |
| `--allow-home` | Permit launch directly in the home directory |
| `--max-time <duration>` | Stop the session after the given wall-clock duration (`600`, `10m`, `1h`) |
| `--no-title` | Disable session-title generation |

An OMP profile isolates the **entire** state root, not just one provider's OAuth
record. Authentication in one profile is independent of authentication in
another. `code` therefore reads machine-local vault definitions that name
complete Claude + Codex combinations instead of swapping providers implicitly.

### Tools and extensibility

| Flag | Effect |
| --- | --- |
| `--no-tools` | Disable all built-in tools |
| `--tools <a,b,...>` | Enable only the named built-in tools |
| `--no-lsp` | Disable LSP tools, formatting, and diagnostics |
| `--no-pty` | Disable PTY-backed interactive shell execution |
| `-e`, `--extension <file>` | Load an extension file; repeatable |
| `--hook <file>` | Load a hook/extension file; repeatable |
| `--plugin-dir <path>` | Load a plugin directory; repeatable |
| `--no-extensions` | Disable discovered extensions; explicit `-e` files still load |
| `--no-skills` | Disable skill discovery and loading |
| `--skills <globs>` | Filter loaded skills with comma-separated globs |
| `--no-rules` | Disable rule discovery and loading |

`omp-managed` refuses `--no-extensions` for managed root sessions because that
would also disable the settings guard, managed agents, and managed rules. Plain
`omp` has no repository-owned interception.

### Output and approval

| Flag | Effect |
| --- | --- |
| `-p`, `--print` | Process the prompt non-interactively and exit |
| `--mode <mode>` | Select `text` (default), `json`, `rpc`, or `rpc-ui` |
| `--print-thoughts` | Include thinking blocks in print-mode text output |
| `--hide-thinking` | Hide thinking in the TUI without changing model reasoning |
| `--export <session.jsonl>` | Export an existing session file to HTML and exit |
| `--approval-mode <mode>` | Override approval behavior with `always-ask`, `write`, or `yolo` |
| `--auto-approve` | Skip all tool approval prompts for this process |

Treat `--auto-approve` and `--approval-mode yolo` as trust-boundary changes, not
convenience switches. The managed policy may deliberately prevent them from
weakening enforced rules.

## Shell command catalog

These are `omp` shell subcommands, not interactive `/slash` commands.

| Command | Purpose |
| --- | --- |
| `acp` | Serve OMP over stdio using Agent Client Protocol |
| `agents` | Unpack/manage bundled task-agent definitions |
| `auth-broker` | Run and administer the credential vault used by remote/headless clients |
| `auth-gateway` | Run a forwarding proxy backed by the configured auth broker |
| `bench` | Compare model time-to-first-token and generation throughput |
| `commit` | Generate a commit message and update changelogs |
| `completions` | Print Bash, Zsh, or Fish completions |
| `config` | List/get/set/reset configuration and print the active state path |
| `dry-balance` | Simulate OAuth-account selection across random session IDs |
| `gallery` | Preview built-in tool renderers in their lifecycle states |
| `gc` | Dry-run or apply storage garbage collection |
| `grep` | Exercise the built-in grep tool from the shell |
| `grievances` | View, clean, or push auto-QA tool reports |
| `install` | Install/link an extension package; alias of plugin install/link |
| `join` | Join an encrypted live collaboration session |
| `models` | List, search, and refresh available models |
| `plugin` | Install, link, enable, disable, inspect, or diagnose plugins |
| `read` | Show exactly what the built-in read tool returns for a path/URL/internal URI |
| `say` | Synthesize speech with the local TTS engine and play it |
| `search` | Exercise configured web-search providers |
| `setup` | Run onboarding or install/check optional feature dependencies |
| `shell` | Open OMP's interactive shell console |
| `ssh` | Manage SSH host configurations |
| `stats` | Print usage stats or launch the local dashboard |
| `tiny-models` | Download the small local models used for titles/memory |
| `token` | Resolve a provider API key/OAuth token, optionally selecting an account |
| `ttsr` | Inspect and test Time-Traveling Stream Rules |
| `update` | Check/install upstream updates; blocked by these Nix-managed wrappers |
| `usage` | Show provider limits for every authenticated account; supports JSON, provider filtering, and redaction |
| `worktree` | List or clear agent-managed worktrees under `~/.omp/wt` |

Run `omp <command> --help` for the command's current arguments. Useful examples:

```console
$ omp models --json
$ omp usage --redact
$ omp stats --summary
$ omp config list --json
$ omp config path
$ omp setup python --check
$ omp plugin doctor
$ omp gc                         # dry-run
$ omp gc --apply                 # mutate storage
$ omp worktree clear --dry-run
```

For managed state, use the repository-specific diagnostic rather than assuming
upstream `omp config` reports injected layers:

```console
$ omp config managed --json
```

The repository-packaged `omp` passthrough intercepts that one action before
dispatching to upstream. `config managed` is not an upstream v17.0.1
subcommand, despite the intentionally plain-looking invocation.

## Built-in agent tool catalog

The packaged root help advertises these default tools:

| Tool | Capability |
| --- | --- |
| `read` | Files, documents, archives, URLs, internal URIs, and structured stores |
| `bash` | External commands and terminal processes |
| `edit` / `write` | Surgical edits and file creation/overwrite |
| `grep` / `glob` | Content search and path discovery |
| `lsp` | Symbol-aware navigation, refactors, diagnostics, and code actions |
| `python` | Persistent Python execution after `omp setup python` |
| `notebook` | Notebook cell editing |
| `inspect_image` | Vision-model image analysis |
| `browser` | Puppeteer browser automation |
| `task` | Parallel subagents |
| `todo` | Structured task-list state |
| `web_search` | Search through configured web providers |
| `ask` | Interactive operator questions |

Extensions and MCP servers can add tools, so `/tools` is authoritative for the
active session. A wrapper can also limit or deny tools through policy.

The v17.0.1 root help does not advertise `hub`; do not assume it is available
in a bare session. `/tools` is authoritative for the active surface.
Discoverable custom, MCP, image-generation, and TTS tools can mount as `xd://`
virtual devices: use `read xd://` to list mounted devices, `read xd://<tool>`
for a contract, and `write xd://<tool>` to invoke one. Plan and preview
resolution remains at `xd://propose`, `xd://resolve`, and `xd://reject`.

Upstream v17 also defaults `astGrep.enabled` and
`edit.enforceSeenLines` off. These dotfiles deliberately enable both in the
managed defaults and plain-profile seed: repository policy requires scoped,
syntax-aware search, and the strict guard trades occasional extra targeted
reads for protection against edits anchored on unseen source lines.

### Why these two v17 defaults are overridden

The overrides are deliberate but revisitable:

- **`astGrep.enabled: true`** — upstream changed the default in
  [e4bbe34](https://github.com/can1357/oh-my-pi/commit/e4bbe34f6118667245694289c1eb2eff557b9b70)
  without recording a rationale. One known cost is that broad native AST
  searches currently materialize every match before paging
  ([upstream #3932](https://github.com/can1357/oh-my-pi/issues/3932)).
  Repository policy already mitigates that cost by requiring narrow paths and
  prohibiting broad repository-root AST scans. Within those bounds, structural
  matching is safer than text substitution and remains worth exposing. Revisit
  this override if scoped searches show material resource cost or OMP replaces
  the tool with a bounded implementation.
- **`edit.enforceSeenLines: true`** — upstream made the guard opt-in in
  [d50cc4](https://github.com/can1357/oh-my-pi/commit/d50cc4e2d3b62e597f7dc9cf05f4f90fd2dcfedd)
  after real false rejections and extra read/retry round trips, including
  [upstream #4224](https://github.com/can1357/oh-my-pi/issues/4224) and
  [upstream #2773](https://github.com/can1357/oh-my-pi/issues/2773). These
  dotfiles accept that friction because rejecting an edit anchored inside
  elided or unread source is safer than validating only the snapshot hash. This
  repository has also lost invisible Nerd Font literals when a source line was
  reconstructed instead of byte-preserved. Revisit the override if upstream
  eliminates the false-rejection paths or a replacement provides equivalent
  unseen-source protection with fewer round trips.

## Invocation examples, with surface made explicit

```console
# Plain mutable upstream state
$ omp --profile work --model opus --thinking high "review this failure"
$ omp -p --mode json --no-session "summarize @report.txt"
$ omp --config ./experiment.yml --resume

# Repository-managed configuration and policy
$ omp-managed --profile work --resume

# Pick auth in the code TUI, then forward --resume to the chosen launch path
$ code --resume

# Fixed restricted sandbox; never inherits code's selected local vault
$ ompu "inspect this untrusted repository"
```

Sources: packaged `omp --help`; tagged upstream
[settings](https://github.com/can1357/oh-my-pi/blob/v17.0.1/docs/settings.md),
[providers](https://github.com/can1357/oh-my-pi/blob/v17.0.1/docs/providers.md),
[models](https://github.com/can1357/oh-my-pi/blob/v17.0.1/docs/models.md), and
[secrets](https://github.com/can1357/oh-my-pi/blob/v17.0.1/docs/secrets.md)
documentation; repository [Agent tools](../agent-tools.md).
