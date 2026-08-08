---
name: bump-omp-fork
description: Updates the dotfiles OMP pin from upstream can1357/oh-my-pi releases, validates the managed configuration against release notes, and owns the dormant atyrode/omp emergency fork-release path plus accepted-patch reconciliation. MUST use when asked to bump, update, upgrade, release, or pin OMP or oh-my-pi in this repository.
---

# Bump the OMP pin

Routine bumps consume upstream `can1357/oh-my-pi` release binaries directly (operator decision 2026-08-08; the fork had carried no source delta since its auth customization landed upstream). The `atyrode/omp` fork remains the contribution vehicle for `contribute-omp-upstream` and the dormant emergency-release pipeline below. It is NEVER a routine consumption source.

## Routine bump

1. Read `pkgs/omp/default.nix` for the current pin.
2. Query the latest non-draft, non-prerelease release from `can1357/oh-my-pi`.
3. Require a clean dotfiles worktree.
4. Run `./scripts/update-pins.sh omp`.
5. Require all of the following:
   - `pkgs/omp/default.nix` is the only pin changed.
   - Its version equals the upstream tag without leading `v`.
   - All four hashes come from assets the script actually downloaded:

     ```text
     omp-linux-x64
     omp-linux-arm64
     omp-darwin-x64
     omp-darwin-arm64
     ```

6. Review every upstream release note between the old and new pin. `omp/defaults.yml`, `omp/models.yml`, and `omp/plain-seed.yml` MUST remain valid for the release; update them only for real upstream contract changes (settings keys, model ids, agent names) — SDK and tool wire-schema changes do not qualify.
7. Verify the package and managed configuration:

   ```console
   nix build .#omp
   ./result/bin/omp --version
   ./result/bin/omp --smoke-test
   nix flake check --show-trace
   ```

   Failures MUST be fixed before merge; NEVER suppress a changed upstream contract.
8. Land the bump:
   1. Reuse a correct open `bot/update-pins` pull request; NEVER open a duplicate.
   2. Otherwise create a focused branch and commit the pin/config changes.
   3. Open a PR against `atyrode/dotfiles:main`, wait for required CI, squash-merge, delete the branch.
   4. Run `atyrode apply` only when the task includes updating the current machine.

## Emergency fork release

Upstream ships a regression the operator needs fixed before any upstream release contains the fix? Only then does `atyrode/omp` become a release source, and only for the life of the carried patch.

Branch contract, unchanged from the fork-consumption era:

- `atyrode/omp` remote `origin` is the fork; `can1357/oh-my-pi` remote `upstream` is the original.
- `main` MUST exactly mirror `upstream/main` and track `origin/main`; fork changes NEVER land on `main`.
- `atyrode-release` MUST contain the complete fork-only commit series atop an upstream release tag.
- `.github/workflows/fork-release.yml` MUST publish matching `v*-atyrode.*` tags with the four platform assets.
- `vX.Y.Z-atyrode.N` tags MUST be immutable: NEVER reuse, move, or silently rebuild one.

Workflow:

1. Mirror `main`, then place the patch series on `atyrode-release` atop the upstream release tag. Record the pre-change tip in a `backup/` branch before any rewrite, and inspect every `git range-diff` change after a rebase.
2. Run focused tests covering every carried patch plus the affected package's type check; format-check every supported file the patch range touches.
3. Create an annotated `vX.Y.Z-atyrode.N` tag (`.1` for the first fork build of an upstream release), push only that tag, watch `.github/workflows/fork-release.yml` to success, and verify all four assets are downloadable.
4. Point the pin at the fork in one PR that records why: the omp entry in `scripts/update-pins.sh` and the URL in `pkgs/omp/default.nix` switch to `atyrode/omp`, and the routine-bump verification above still applies.

### Reconciling back to upstream

Every routine bump while a patch is carried MUST check whether the new upstream release supersedes it:

1. Identify the upstream pull request or commit that absorbs each carried patch.
2. Exercise the patch's observable contract against the upstream release.
3. Record `carried patch → superseding upstream PR/commit` in the bump PR body.
4. Equivalence proven for the whole series? Return the pin to upstream in that bump. Equivalence missing or uncertain? Keep carrying the patch on a fresh fork release instead of dropping it.

This is the reconciliation path for contributions prepared with `contribute-omp-upstream`.

## Critical failures to avoid

- NEVER pin a release before all four assets download and hash.
- NEVER merge a bump whose smoke test or flake checks fail.
- NEVER update managed configuration for anything but a verified upstream contract change.
- NEVER leave the pin on `atyrode/omp` once the pinned upstream release contains every carried patch.
- NEVER reuse, move, or silently rebuild an existing release tag.
- NEVER squash upstream snapshots into fork `main` or overwrite unknown commits.
