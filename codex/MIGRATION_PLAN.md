# Codex Migration Plan

First-pass inventory and migration plan for making this repository the source of truth for personal Codex configuration, global instructions, and reusable agent workflows.

## Proposed Structure

```text
dotfiles/
  codex/
    AGENTS.md
    config.toml
    MIGRATION_PLAN.md
    skills/
    templates/
      repo-AGENTS.md
  home/
    codex.nix
```

This keeps Codex-specific files isolated while following the existing Home Manager module layout under `home/`.

## Scan Scope

- Searched `/home/alex` for git repositories and Codex/agent-related files.
- `/Users/alex` does not exist on this machine.
- Included git worktrees with `.git` files.
- Excluded generated/vendor/cache surfaces such as Codex plugin caches, VS Code extension installs, dependency folders, Cargo/Rust caches, and `.codex-profiles/*/.tmp`.
- No matching `CLAUDE.md`, `.cursorrules`, `.windsurfrules`, `.cursor/rules/*`, `AGENTS.override.md`, `docs/agents.md`, or `docs/AGENTS.md` files were found in user repos.

## Repository Inventory

| Repo root | Project | Relevant files | Notes |
|---|---|---|---|
| current local checkout | dotfiles | `.agents/`, `.codex/`, `home/shell/codex.zsh` | The local directory can be renamed after this work is committed or otherwise preserved. `.agents/` is empty. |
| `/home/alex/liquid` | Liquid | `AGENTS.md`, empty `.agents/`, empty `.codex/` | Heavy duplicate of shared governance/docs/secrets template plus project docs map. |
| `/home/alex/archi_simple` | archi-simple | `AGENTS.md`, empty `.agents/`, empty `.codex/`, `docs/workflows/CODEX_GOAL_PLANNING.md` | Good source for regression-test and goal-planning workflow guidance. |
| `/home/alex/factorio-gui-web-editor` | factorio-gui-web-editor | `AGENTS.md`, empty `.agents/`, empty `.codex/` | Repo-specific Factorio GUI/editor/visual evidence guidance. |
| `/home/alex/factorio_mods/player_quality` | player_quality | `AGENTS.md`, empty `.agents/`, empty `.codex/` | AGENTS appears mostly copied and likely stale for this repo. |
| `/home/alex/factorio_mods/turret_xp` | turret_xp | `AGENTS.md`, empty `.agents/`, empty `.codex/`, `.codex_tmp/*` | Repo-specific Factorio mod release/testing guidance plus temporary design/PR spike notes. |
| `/home/alex/.codex/worktrees/8c46/turret_xp` | turret_xp worktree | `AGENTS.md` | Codex-managed detached worktree. |
| `/home/alex/.codex/worktrees/b742/turret_xp` | turret_xp worktree | `AGENTS.md`, empty `.agents/`, empty `.codex/`, `.codex_tmp/` | Codex-managed worktree with additional feature/test workflow wording. |
| `/home/alex/innerbloom` | innerbloom | `.codex/skills/openspec-*.md` | Contains five OpenSpec workflow skills. |
| `/home/alex/kroissant_website` | kroissant-website | `AGENTS.md` | Repo-specific Astro/WordPress/SEO/branch-variant guidance plus shared governance. |
| `/home/alex/sts2/sts2-mod-compendium` | sts2-mod-compendium | `AGENTS.md`, empty `.agents/`, empty `.codex/` | Strong reusable handoff/source-control wording plus app-specific importer rules. |
| `/home/alex/terraria_infra_repo` | tModLoader Dedicated Server | `AGENTS.md`, empty `.agents/`, empty `.codex/` | Terraria infra rules; very similar to `terraria_server`. |
| `/home/alex/terraria_server` | tModLoader Dedicated Server | `AGENTS.md`, empty `.agents/`, empty `.codex/` | `.git` exists but appears invalid/empty; decide whether superseded by `terraria_infra_repo`. |
| `/home/alex/case_studies` | Case Studies | none found | No Codex/agent files found. |
| `/home/alex/seablock` | Rust Server Docker | none found | No Codex/agent files found. |
| `/home/alex/pcf_marin` | riseup-formation-archiver | empty `.agents/`, empty `.codex/` | `.git` exists but appears invalid/empty. |
| `/home/alex/sts2/runesmith_fr_localization` | runesmith_fr_localization | empty `.agents/`, empty `.codex/` | `.git` exists but appears invalid/empty. |
| `/home/alex/sts2/runesmith_fr_localization/Runesmith2-StS2` | The Runesmith 2 | none found | Nested repo. |

## Instruction Classification

| Path | Scope guess | Content summary | Candidate destination | Risk/notes |
|---|---|---|---|---|
| `/home/alex/.codex/AGENTS.md` | global | Empty. | Replace with reviewed `codex/AGENTS.md`. | Do not wire until reviewed. |
| `/home/alex/.codex-profiles/default/AGENTS.md` | global/profile | Empty. | Ignore for now. | Profile copy may be obsolete. |
| `/home/alex/.codex/config.toml` | global | Active Codex config: model, reviewer, trusted projects, TUI theme, goals feature. | Split generic defaults into `codex/config.toml`; leave `[projects]` trust entries machine-local. | Do not manage live `~/.codex/config.toml` as a Home Manager symlink because Codex mutates it. |
| `/home/alex/.codex/rules/default.rules` | global/runtime | Approval prefix history. | Ignore/archive. | Runtime approval state, not durable instructions. |
| `/home/alex/.codex/prompts/opsx-*.md` | global/prompt | OpenSpec prompt workflows. | Skill candidate. | Superseded by structured `innerbloom/.codex/skills/openspec-*`. |
| `/home/alex/liquid/AGENTS.md` | project | Shared git/governance/docs/secrets/operator-script/validation rules plus land-report docs map. | Split shared rules to global; keep docs map local. | Heavy duplicate of other templates. |
| `/home/alex/archi_simple/AGENTS.md` | project | Shared governance/docs/secrets rules plus issue workflow, benchmark requirements, bug-test guidance. | Split shared rules to global; keep benchmark/docs rules local. | Useful source for bug-fix testing wording. |
| `/home/alex/archi_simple/docs/workflows/CODEX_GOAL_PLANNING.md` | docs/workflow | Reusable workflow for scanning repo state and producing a ready `/goal` prompt. | Skill candidate. | Needs generalization from Archi Simple doc map. |
| `/home/alex/factorio-gui-web-editor/AGENTS.md` | project | Factorio GUI editor direction, copyright limits, docs ownership, visual evidence, Factorio research shortcuts, validation. | Repo-specific AGENTS.md. | Domain-specific; keep local. |
| `/home/alex/factorio_mods/player_quality/AGENTS.md` | project | Mostly shared governance/docs/secrets template with unrelated land-report docs references. | Rewrite as repo-specific AGENTS.md later. | Likely stale copy. |
| `/home/alex/factorio_mods/turret_xp/AGENTS.md` | project | Shared template plus Factorio mod docs upkeep, headless tests, release/handoff source-control rules. | Split shared rules to global; keep mod rules local. | Some copied docs-map entries still look generic. |
| `/home/alex/factorio_mods/turret_xp/.codex_tmp/scripted_veteran_overlay_issue.md` | project/temp | Issue draft for a selected-veteran-turret world overlay spike. | Repo-specific docs/issues, not global AGENTS. | Temporary design artifact; migrate to issue tracker or repo docs if still relevant. |
| `/home/alex/factorio_mods/turret_xp/.codex_tmp/scripted_veteran_overlay_pr.md` | project/temp | PR summary and validation notes for the selected-turret overlay spike. | Repo-specific PR notes, not global AGENTS. | Temporary handoff artifact. |
| `/home/alex/factorio_mods/turret_xp/.codex_tmp/veteran_turret_runtime_flexibility_case_study.md` | project/temp | Detailed Factorio design case study about prototype/runtime limits for veteran turret HP/range/tooltip/preview behavior. | Repo-specific design doc candidate. | Valuable domain research; consider moving into `turret_xp/docs/` if still current. |
| `/home/alex/.codex/worktrees/8c46/turret_xp/AGENTS.md` | worktree/project | Variant of turret_xp AGENTS with feature workflow added. | Review before merging into canonical turret_xp AGENTS or skill. | Detached Codex worktree. |
| `/home/alex/.codex/worktrees/b742/turret_xp/AGENTS.md` | worktree/project | Variant of turret_xp AGENTS with feature workflow plus Factorio test-driver wording. | Skill candidate or turret_xp-local rule after review. | Codex worktree; may contain unmerged useful guidance. |
| `/home/alex/innerbloom/.codex/skills/openspec-*.md` | project skill | OpenSpec explore/propose/apply/sync/archive skills. | Global skill candidates. | Generated metadata; review tool names before global install. |
| `/home/alex/kroissant_website/AGENTS.md` | project | Astro static site, React islands, headless WordPress, SEO, branch variants, VPS validation limits. | Split shared rules to global; keep WordPress/Astro/branch rules local. | Unique branch model; keep local. |
| `/home/alex/sts2/sts2-mod-compendium/AGENTS.md` | project | STS2 mod compendium/importer rules, live deployment caution, copyright asset limits, test/build validation. | Split shared rules to global; keep app/importer rules local. | Strong reusable handoff wording. |
| `/home/alex/terraria_infra_repo/AGENTS.md` | project | Terraria/tModLoader infra source of truth, runtime boundaries, backups, deployment docs, compose validation. | Repo-specific AGENTS.md. | Decide canonical repo versus `terraria_server`. |
| `/home/alex/terraria_server/AGENTS.md` | unknown/project | Terraria/tModLoader infra rules similar to `terraria_infra_repo`. | Repo-specific or archive after supersession decision. | Invalid/empty `.git`; likely old checkout. |

## Master AGENTS Extraction

`codex/AGENTS.md` now drafts only repeated, non-project-specific guidance:

- operating style and exploration habits;
- editing discipline and user-change safety;
- instruction-file governance;
- git and remote safety;
- documentation discipline;
- secret handling;
- operator script and live-system caution;
- testing, regression, and validation expectations;
- final handoff expectations.

It intentionally excludes package managers, repo commands, architecture, deployment targets, docs maps, and domain constraints.

## Skill Candidate Migration

| Skill | Trigger | Sources | Why | Scope |
|---|---|---|---|---|
| `openspec-change-workflow` | User wants to explore, propose, apply, sync, or archive an OpenSpec change. | `~/.codex/prompts/opsx-*.md`, `/home/alex/innerbloom/.codex/skills/openspec-*` | Same workflow exists as prompts and skills; centralizing avoids drift. | Global, requires `openspec`. |
| `codex-next-goal-planner` | User asks for the next useful `/goal`, task selection, or planning prompt. | `/home/alex/archi_simple/docs/workflows/CODEX_GOAL_PLANNING.md` | Reusable workflow for scanning repo state and producing a measurable Codex goal without implementing. | Global after doc-map generalization. |
| `factorio-mod-release` | User wants to release or publish a Factorio mod. | `turret_xp` and `player_quality` release scripts/workflows | Release safety depends on clean branch, version/tag alignment, package/headless validation, and secret-safe Mod Portal publishing. | Global Factorio-specific. |
| `terraria-server-deploy` | User wants to validate, deploy, restart, or update Terraria/tModLoader infra or edge proxy. | `terraria_server` docs/scripts and duplicated infra repo guidance | Live server deployment has operational risk around backups, runtime state, restarts, and edge proxy separation. | Repo-specific; reconcile canonical repo first. |
| `archi-simple-preview-ops` | User wants to provision, deploy, validate, or debug Archi Simple preview/Keycloak/mail/Caddy. | `archi_simple/deploy/*`, security validation script, `AGENTS.md` | Dense operational runbook with secret-safe validation and container/DNS caveats. | Repo-specific. |
| `archi-simple-benchmark-issue-fix` | User fixes a GitHub issue affecting report behavior, source evidence, review gates, source confidence, or admin benchmark workflows. | `archi_simple/AGENTS.md`, `docs/REAL_PARCEL_BENCHMARK.md`, `docs/DEVELOPMENT_STEPS.md` | Combines regression tests, benchmark-case judgment, and PR notes. | Repo-specific. |
| `factorio-gui-atom-workflow` | User adds or revises Factorio GUI atom/spec/visual parity features. | `factorio-gui-web-editor` AGENTS and docs | Strong repeatable flow for evidence, model, renderer, inspector, Lua export, screenshots, and validation. | Repo-specific. |

Not recommended as skills:

- repeated branch/secret/governance rules: better as always-on global/repo instructions;
- `~/.codex/rules/default.rules`: approval history, not reusable workflow;
- empty `.agents/` and `.codex/` directories;
- `turret_xp/.codex_tmp/*.md`: useful project design/PR notes, but not reusable agent workflows;
- `codex-use`: already deterministic shell tooling in `home/packages.nix`;
- thin CI YAML or deployment examples without runbook logic;
- `kroissant_website` deploy/release docs until Astro/static versus WordPress-theme wording is reconciled.

## Proposed Home Manager Wiring

Module added at `home/codex.nix` and imported from `home/default.nix`.

```nix
{
  home.activation.installCodexProfileFiles = ...
  home.file.".agents/skills" = ...
}
```

The activation hook installs the managed `codex/AGENTS.md` symlink into the
active `~/.codex` profile and existing inactive `~/.codex-profiles/*`
profiles. It also seeds `config.toml` only when a profile has no config or an
empty config, then leaves it mutable.

`codex-use` mirrors the same behavior whenever it creates, migrates, or switches
profiles. This keeps profile switching compatible with the dotfiles-managed
global AGENTS file while preserving machine-local `[projects]` trust entries.

## Repo Name References

The code/docs now use `dotfiles` as the active repo identity.

Updated:

- `README.md`: title, clone/install commands, update commands, structure heading, troubleshooting path.
- `install.sh`: comments, GitHub URL, default clone path, install message.
- `home/default.nix`: imports the Codex module.
- `home/packages.nix`: keeps Codex profile switching compatible with managed AGENTS and config seeding.
- `home/shell/nix.zsh`: lookup paths, helper names, env vars, and comments.
- `home/shell/startup.zsh`: fastfetch env vars.

New names:

- `DOTFILES`
- `DOTFILES_CONFIG`
- `DOTFILES_RESTART_SHELL`
- `DOTFILES_FASTFETCH`
- `DOTFILES_FASTFETCH_SHOWN`

## External Rename Status

Completed on 2026-06-27:

1. Renamed the existing old GitHub repo from `atyrode/dotfiles` to `atyrode/old-dotfiles`.
2. Archived `atyrode/old-dotfiles`.
3. Renamed the active GitHub repo to `atyrode/dotfiles`.
4. Updated this checkout's `origin` URL to `https://github.com/atyrode/dotfiles.git`.

Still pending:

1. Update any external flake inputs, scripts, docs, bookmarks, or automation that refer to the old GitHub repo name.
2. Optionally rename the local checkout directory to `~/dotfiles`.

## Safe To Apply Now

- Review `codex/AGENTS.md` as the draft master global instruction file.
- Review `codex/templates/repo-AGENTS.md` as the reusable repo template.
- Review `codex/config.toml` as generic Codex defaults without machine-local project trust entries.
- Run Home Manager after committing or otherwise preserving this work to install the managed Codex files.

## Needs Review Before Applying

- Trim or rewrite existing project `AGENTS.md` files.
- Move OpenSpec workflows from prompts/project-local skills into `codex/skills`.
- Decide whether `terraria_infra_repo` supersedes `terraria_server`.
- Decide whether `player_quality/AGENTS.md` should be rewritten because it appears stale.
- Rename the local checkout directory, if desired.
