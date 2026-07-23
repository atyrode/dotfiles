---
name: bump-omp-fork
description: Syncs atyrode/omp with a new can1357/oh-my-pi release, preserves fork-only auth and release changes, publishes an immutable atyrode release, and updates the dotfiles OMP pin. MUST use when asked to bump, update, upgrade, release, or pin OMP or oh-my-pi in this repository.
---

# Bump the OMP fork and dotfiles pin

Use this workflow for every OMP bump. The dotfiles MUST consume release binaries from `atyrode/omp`; they NEVER pin `can1357/oh-my-pi` directly.

## Branch contract

- `atyrode/omp` remote `origin` is the fork.
- `can1357/oh-my-pi` remote `upstream` is the original.
- `main` MUST exactly mirror `upstream/main` and track `origin/main`.
- `atyrode-release` MUST contain fork changes atop an upstream release tag.
- `vX.Y.Z-atyrode.N` tags MUST be immutable.
- Fork changes MUST NEVER land on `main`.

The current fork delta is exactly these paths:

```text
.github/workflows/fork-release.yml
packages/ai/src/auth-broker/discover.ts
packages/ai/src/auth-broker/remote-store.ts
packages/ai/src/auth-storage.ts
packages/ai/test/auth-broker-config-discovery.test.ts
packages/ai/test/auth-broker-remote-store.test.ts
packages/ai/test/auth-storage-account-identity.test.ts
```

Unexpected paths indicate drift. Stop and investigate; intentional additions MUST update this contract in the same change.

## 1. Establish release state

1. Read `pkgs/omp/default.nix` for the current `vX.Y.Z-atyrode.N` pin.
2. Query the latest non-draft, non-prerelease release from `can1357/oh-my-pi`; call its tag `upstream_tag`.
3. Query the latest published release from `atyrode/omp`; call its tag `latest_fork_tag`.
4. Fetch `origin`, `upstream`, and tags in the OMP checkout.
5. Require clean OMP and dotfiles worktrees before rewriting branches.

Always mirror `main` before deciding whether fork release work is required.

## 2. Mirror upstream on fork main

In the OMP checkout, verify remotes before pushing:

```console
git remote -v
git fetch --all --prune --tags
git switch main
git merge --ff-only upstream/main
test "$(git rev-parse main)" = "$(git rev-parse upstream/main)"
git push origin main
git branch --set-upstream-to=origin/main main
```

A non-fast-forward local `main`, dirty worktree, or unexpected remote update MUST stop the workflow. Preserve unknown commits before any destructive operation.

Verify `origin/main...upstream/main` reports `0 0`.

A published `vX.Y.Z-atyrode.N` matching `upstream_tag` already exists? Skip to section 5. NEVER recreate or move its tag.

## 3. Rebase fork changes onto the release

Resolve the upstream tag to a commit and require it on `upstream/main`:

```console
release_commit="$(git rev-parse "${upstream_tag}^{commit}")"
git merge-base --is-ancestor "$release_commit" upstream/main
old_base="$(git merge-base atyrode-release upstream/main)"
test "$(git rev-parse atyrode-release)" = "$(git rev-parse origin/atyrode-release)"
git switch atyrode-release
git rebase --onto "$release_commit" "$old_base"
```

Resolve conflicts by preserving the fork contracts, not by accepting one side wholesale. The rebased branch SHOULD remain four commits ahead of the release until the documented fork delta changes.

Verify the changed-path set exactly matches the branch contract:

```console
git diff --name-only "$release_commit"...HEAD
```

## 4. Verify and publish the fork release

Run from the OMP checkout:

```console
bun test packages/ai/test/auth-broker-config-discovery.test.ts \
  packages/ai/test/auth-broker-remote-store.test.ts \
  packages/ai/test/auth-storage-account-identity.test.ts
(cd packages/ai && bun run check:types)
bunx biome check \
  packages/ai/src/auth-broker/discover.ts \
  packages/ai/src/auth-broker/remote-store.ts \
  packages/ai/src/auth-storage.ts \
  packages/ai/test/auth-broker-config-discovery.test.ts \
  packages/ai/test/auth-broker-remote-store.test.ts \
  packages/ai/test/auth-storage-account-identity.test.ts \
  .github/workflows/fork-release.yml
```

All checks MUST pass before publishing. Then:

1. Push `atyrode-release` with `--force-with-lease` because rebasing rewrites it.
2. Choose `vX.Y.Z-atyrode.1` for the first fork build of an upstream release.
3. Increment `N` only for another fork build of the same upstream release.
4. Verify the tag is absent locally, remotely, and from GitHub Releases.
5. Create an annotated tag at `atyrode-release` HEAD.
6. Push only that tag.

The matching tag push triggers `.github/workflows/fork-release.yml`. Watch that exact workflow run to success. NEVER update dotfiles while the run is pending or failed.

Require these release assets:

```text
omp-linux-x64
omp-linux-arm64
omp-darwin-x64
omp-darwin-arm64
```

Verify all four assets exist and are downloadable from the published `atyrode/omp` release.

## 5. Update the dotfiles pin

Return to the dotfiles checkout and run:

```console
./scripts/update-pins.sh omp
```

Require all of the following:

- `pkgs/omp/default.nix` is the only pin changed.
- Its version equals the published fork tag without leading `v`.
- All four hashes match the downloaded release assets.
- `omp/defaults.yml`, `omp/models.yml`, and `omp/plain-seed.yml` remain valid for the release; update them only for real upstream contract changes.

Verify the package and managed configuration:

```console
nix build .#omp
./result/bin/omp --version
./result/bin/omp --smoke-test
nix flake check --show-trace
```

Failures MUST be fixed before merge; NEVER suppress a changed upstream contract.

## 6. Land the dotfiles bump

1. Check for an existing `bot/update-pins` pull request after publishing the release.
2. Reuse a correct bot PR; NEVER open a duplicate.
3. Otherwise create a focused branch and commit the OMP pin/config changes.
4. Open a PR against `atyrode/dotfiles:main`.
5. Wait for required CI.
6. Squash-merge and delete the branch after CI passes.
7. Run `atyrode apply` only when the task includes updating the current machine.

## Critical failures to avoid

- NEVER pin original-repository binaries in dotfiles.
- NEVER squash upstream snapshots into fork `main`.
- NEVER overwrite unknown local or remote commits.
- NEVER reuse, move, or silently rebuild an existing release tag.
- NEVER pin a release before all four assets pass CI.
- NEVER merge a bump whose smoke test or flake checks fail.
