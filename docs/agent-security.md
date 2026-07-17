# Agent security

The managed OMP policy reduces the chance that repository-controlled content
can silently expand an agent's authority. It does not make an agent, shell, or
repository trustworthy, and it is not an operating-system sandbox.

## Normal sessions

Managed sessions launched through `omp-managed` — including every profile the
`code` generator produces — use the trusted-machine unattended approval policy:
workspace edits, shell/eval, browser, task spawning, and GitHub operations do
not prompt. Secret filtering remains enabled, and when a spawn requests
isolation, OMP's automatic backend selection and patch merging apply (both
policy-fixed). Isolation itself is upstream's per-spawn opt-in — the model or
operator requests `isolated: true` per task; a managed rule advises it for
concurrent writing subagents. There is no repository-side isolation mandate
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

## Limits

OMP task isolation is a worktree/copy-and-patch boundary, not process, kernel,
filesystem, or network isolation. Approval prompts depend on OMP correctly
classifying tool calls; a permitted shell command still has the operating-system
authority of the user running it. The sanitized environment prevents accidental
credential inheritance, but credentials entered or configured inside the
untrusted profile are part of that profile's risk. Inspect generated patches
before merging them and use a real VM/container sandbox when hostile code may
need to execute.

This is the OMP security slice resolved under issue #17. Workspace
trust/revocation and residual Codex and local/SSH workspace diagnostics are now
owned by #22. The Pi experiment (#29) closed to operator notes on 2026-07-17 and
ships no launcher; the Zed evaluation (#30) is closed and Zed remains absent.
