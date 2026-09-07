# Repository instructions

Fill only applicable repository-specific facts, then delete empty headings and
prompts. This template is harness-neutral: its source remains in the legacy
`modules/home/codex/templates/repo-AGENTS.md` location and Home Manager deploys
it to `~/.codex/templates/repo-AGENTS.md`; neither location requires Codex use.
Do not add personal standing authority or generated machine facts here.

The marked common section is generated from the
[common engineering source](https://github.com/atyrode/dotfiles/blob/main/modules/home/agents/engineering.md).
Edit local sections outside it; propose reusable-rule changes at that source.

## Common policy maintenance and enrollment

The authored source is dotfiles' `modules/home/agents/engineering.md`, not a
copied block. A source PR uses the
[dotfiles render/check commands](https://github.com/atyrode/dotfiles/blob/main/AGENTS.md#common-policy-authoring-and-distribution)
to update its root, static operator policy and this template together. Normal
Home Manager activation deploys this template; it does not update repositories
previously created from it.

For an unenrolled repository, use a reviewed dotfiles checkout and run the
following there, substituting the repository path. If initially authoring a
document without the section, `block` emits the complete envelope to insert
after its introduction; `render` never initializes missing or corrupt markers.

```sh
python3 ci/agent-policy.py block --source modules/home/agents/engineering.md
python3 ci/agent-policy.py render --source modules/home/agents/engineering.md --root <repository> --layout repository
python3 ci/agent-policy.py check --source modules/home/agents/engineering.md --root <repository> --layout repository
```

Copying this template does **not** enroll a new repository in automation.
Enrollment requires reviewed support in the shared synchronizer's repository
allowlist and core-check mapping, then the existing Code/Babel/Manifold
[consumer workflow pattern](https://github.com/atyrode/code/blob/main/.github/workflows/agent-policy.yml):
PR/push checks use the remote dotfiles `main` action read-only; hourly/manual
runs call the reusable synchronizer with explicit repository-scoped
contents/pull-requests/actions write permission. Keep default token permission
read-only, enable Actions PR creation, provide core CI's `workflow_dispatch`,
and require successful `agent-policy` plus the repository's core checks with
strict/up-to-date protection while preserving existing protections. The bot
does not review PRs or use cross-repository write credentials.

An enrolled consumer receives generated-only draft PRs, exact-head core/policy
CI, guarded squash merges and separately observed main CI. This trusts reviewed
dotfiles `main` automation code as well as Markdown. Scheduling and CI provide
eventual convergence, not an exact update-time guarantee; failures remain
visible. CI rejects byte drift, not every semantic conflict. Repository copies,
machine activation and already-running instruction snapshots are separate
states; copying the template grants no live-system or personal merge authority.

## Purpose and authority

- Repository purpose and owning contracts/ADRs:
- Local ownership, issue requirements and applicable instruction precedence:
- Necessary project-specific restrictions, their reasons and owning authority:

## Commands

- Setup:
- Build:
- Test:
- Lint/typecheck:
- Other required workflows:
- Prerequisites by platform and which missing capabilities skip locally versus fail CI:

## Generated files

- Other generated paths and their source of truth:
- Regeneration command:
- Files that must not be edited directly:

## Deployment

- Targets and environments:
- Deployment or release command:
- Required approvals or environment-specific constraints:

## Live systems and secrets

- Connected live services or shared resources:
- Repository-specific credential locations and handling constraints:
- Actions prohibited against live systems; isolation needed for disposable fixtures:

## Verification

- Required checks by change type and applicable interaction/rendered proof:
- Manual or environment-specific verification:
- Evidence expected when a check cannot run; required CI evidence for local skips:
- Source revision versus deployed revision and runtime evidence, where applicable:

## Delivery and compatibility

- Repository-specific branch or PR convention:
- Required CI state and integration target before ready/merge:
- Public interfaces, persistent formats and separately released consumers:
- Coordinated migration, compatibility and rollback obligations:
- Release, publish, or handoff requirements:
