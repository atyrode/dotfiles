# Agent security

The managed OMP policy reduces the chance that repository-controlled content
can silently expand an agent's authority. It does not make an agent, shell, or
repository trustworthy, and it is not an operating-system sandbox.

Decision record: [ADR-0004](adr/0004-agent-trust-tiers.md).

## Normal sessions

Managed sessions launched through `omp-managed` — including every profile the
`code` generator produces — use the trusted-machine unattended approval policy:
workspace edits, shell/eval, browser, task spawning, and GitHub operations do
not prompt. Secret filtering remains enabled, and requested isolation uses
automatic backend selection and patch merging (both policy-fixed).
`task.isolation.enabled: true` permits isolation; it does not
isolate every spawn. The model or operator must still request `isolated: true`
per task, and `isolation.backend: auto` selects its backend. A managed rule
advises isolation for concurrent writing subagents. There is no repository-side isolation mandate
(#175): a hard guard converted upstream isolation failures into a total
delegation outage, and stock OMP has no such concept.

The policy overlay is applied after writable machine, project, and
one-shot configuration. Repositories can still choose non-security settings,
but cannot change managed approvals, secret filtering, or task isolation.
Explicit yolo flags remain accepted for compatibility, but do not grant these
sessions additional tool approval.

Plain `omp` is deliberately outside this policy: it runs upstream OMP with the
operator's mutable configuration and no Nix overlay, as the tinkering surface
for a machine the operator already trusts. Its approval posture, extensions,
and integrations are whatever that mutable configuration says. The seeded
defaults start that configuration with secret obfuscation and automatic task
isolation enabled, but unlike the managed policy the operator can change or
remove them on the fly — the next apply only reports the drift. Every
managed session is appropriate only for repositories the operator has
reviewed; use `ompu` for untrusted repositories.

## Untrusted projects

Use `ompu --cwd <project>` when opening a repository whose instructions and
configuration have not been reviewed. `ompu` starts the pinned OMP binary from
an empty immutable directory and passes the repository only as the target
working directory. It uses the fixed `untrusted` profile and dedicated HOME,
XDG, temporary, cache, worktree, authentication, and session paths below
`~/.local/state/atyrode/omp-untrusted/`; normal and untrusted sessions therefore
do not share authentication, sessions, MCP state, or caches.

The launcher rebuilds the environment from an allowlist. Provider tokens,
GitHub credentials, SSH agents, caller Git configuration, credential helpers,
and hook configuration are not forwarded. Git prompting and SSH transport are
disabled. Browser, GitHub, eval, debug, LSP, project MCP configuration,
auto-learning, memory, project command discovery, and skill commands are
disabled. Shell and task use remain approval-gated — the operator sees and
approves each command and each spawn, and can require isolation case by case.
That human gate and the untrusted system prompt are the controls; isolation
itself is not separately enforced.

Project instructions, rules, agents, skills, source files, and tool output are
still loaded because they are the material the agent must analyze. The managed
system prompt labels all of them as untrusted input: they cannot grant tool
authority, expose credentials, change policy, authorize non-isolated writing,
or expand work beyond the requested project.

Upstream's `--no-extensions` also disables explicitly supplied managed guards,
so `ompu` cannot rely on that flag. Instead it clears extension configuration,
loads only the read-only managed platform extension root, and refuses projects
that contain executable or policy-bearing roots such as OMP/Pi extensions,
hooks, plugins, commands, tools, package metadata, or project secret files.
Review or remove such content before choosing a trusted launcher.

## Git hooks

« Contourner les hooks git est interdit : corrigez ce que le hook refuse. » A
hook that refuses a commit or a push reports a defect the work still has;
skipping it moves the failure to CI, to a reviewer or to main. The managed
policy (`pkgs/omp-configured/config/policy.yml`, `bash.patterns`) therefore
denies, in the `bash` tool of every managed session and subagent:

- `--no-verify` on any git subcommand, down to git's shortest unambiguous
  abbreviation `--no-veri`;
- `git commit -n`, alone or bundled after `-a`, `-s`, `-q` or `-v`;
- `core.hooksPath` overrides: `git -c` and `--config-env`, any `git config`
  naming the key (reads included), `GIT_CONFIG_KEY_<n>` and
  `GIT_CONFIG_PARAMETERS`, and `git config --remove-section`/`--rename-section
  core`.

`deny` is absolute: it holds in yolo mode, over `tools.approval.bash: allow`,
and project or one-shot `bash.patterns` layers cannot lift it (they prepend
their rules, and an `allow` never overrides a `deny`). OMP's pattern schema has
no message field, so the agent sees `Blocked by bash pattern: <glob>`; the
managed rule `git-hooks` gives every agent the sentence above and the
instruction to fix what the hook refuses.

Patterns are OMP globs: literal and case-sensitive, `*` the only wildcard,
matched against the whole command and against each shell segment with quotes
removed. The trade-offs that follow from that:

- A pattern requires `git ` before the flag, so `echo test --no-verify`,
  `rg -- --no-verify docs` or `git commit --no-edit` still run, but any command
  whose text contains `git ` and later `--no-veri` is denied — `echo git commit
  --no-verify`, `rg "git push --no-verify"`, a `gh pr create --body` quoting
  it, a `git log --grep=--no-verify`. Search for `no-verify` without the `git `
  prefix, or pass long bodies with `--body-file`.
- `git commit` followed by ` -n` anywhere is denied, including a message such
  as `-m "add -n flag"` (rare, and the message can be rephrased).
- `git config … core.hooksPath` is denied even as a read; read `.git/config`
  instead. `git grep core.hooksPath` still runs.
- Config keys are case-insensitive to git; the patterns cover `hooksPath`,
  `hookspath`, `HooksPath` and `HOOKSPATH`, not other mixed spellings.

Known gaps — the policy governs the `bash` tool's command text, not what a
process eventually does:

- **The `eval` tool's subprocesses.** `bash.patterns` does not apply to
  `eval`; `sh("git commit --no-verify")` in its prelude, Python
  `subprocess`/`os.system` or Bun `$` all run unchecked, and managed sessions
  allow `eval` without prompting. Gating it would need
  `tools.approval.eval: prompt` or `deny`, which headless subagents cannot
  satisfy.
- Indirection the text does not show: variables
  (`f=--no-verify; git commit $f`), git aliases defined in a file, scripts that
  call git, `git commit-tree` plus `git update-ref`, and `GIT_CONFIG_GLOBAL`
  or `GIT_CONFIG_SYSTEM` files (repository-local `core.hooksPath` still wins
  over those two).
- Editing `.git/config` or the hook script itself with `edit`/`write`, or
  removing its executable bit.
- Plain `omp` (unmanaged configuration) does not load this policy. `ompu`
  does not either; it prompts for every shell command instead, and loads the
  `git-hooks` rule.

## Limits

OMP task isolation is a worktree/copy-and-patch boundary, not process, kernel,
filesystem, or network isolation. Approval prompts depend on OMP correctly
classifying tool calls; a permitted shell command still has the operating-system
authority of the user running it. The sanitized environment prevents accidental
credential inheritance, but credentials entered or configured inside the
untrusted profile are part of that profile's risk. Inspect generated patches
before merging them and use a real VM/container sandbox when hostile code may
need to execute.

