---
name: bump-omp
description: Updates the dotfiles OMP pin from upstream can1357/oh-my-pi releases and validates the managed configuration against release notes. MUST use when asked to bump, update, upgrade, release, or pin OMP or oh-my-pi in this repository.
---

# Bump the OMP pin

Bumps consume upstream `can1357/oh-my-pi` release binaries directly.

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

## Critical failures to avoid

- NEVER pin a release before all four assets download and hash.
- NEVER merge a bump whose smoke test or flake checks fail.
- NEVER update managed configuration for anything but a verified upstream contract change.
