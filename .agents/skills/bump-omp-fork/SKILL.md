---
name: bump-omp-fork
description: Syncs atyrode/omp with a new can1357/oh-my-pi release, preserves the complete fork-only commit series, publishes an immutable atyrode release, and updates the dotfiles OMP pin. MUST use when asked to bump, update, upgrade, release, or pin OMP or oh-my-pi in this repository.
---

# Bump the OMP fork and dotfiles pin

Use this workflow for every OMP bump. The dotfiles MUST consume release binaries from `atyrode/omp`; they NEVER pin `can1357/oh-my-pi` directly.

## Branch contract

- `atyrode/omp` remote `origin` is the fork.
- `can1357/oh-my-pi` remote `upstream` is the original.
- `main` MUST exactly mirror `upstream/main` and track `origin/main`.
- `atyrode-release` MUST contain the complete fork-only commit series atop an upstream release tag.
- Every pre-bump fork-only commit MUST survive unless the operator explicitly removes it.
- `.github/workflows/fork-release.yml` MUST publish matching `v*-atyrode.*` tags.
- `vX.Y.Z-atyrode.N` tags MUST be immutable.
- Fork changes MUST NEVER land on `main`.

File paths and commit counts are intentionally not fixed. Fork customization may grow; the preserved commit range is the source of truth.

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

Resolve the upstream tag, record the complete old fork range, and create a local safety branch before rebasing:

```console
release_commit="$(git rev-parse "${upstream_tag}^{commit}")"
git merge-base --is-ancestor "$release_commit" upstream/main
old_tip="$(git rev-parse origin/atyrode-release)"
test "$(git rev-parse atyrode-release)" = "$old_tip"
old_base="$(git merge-base "$old_tip" upstream/main)"
old_count="$(git rev-list --count "$old_base..$old_tip")"
backup_branch="backup/atyrode-release-before-${upstream_tag#v}-$(date -u +%Y%m%dT%H%M%SZ)"
git branch "$backup_branch" "$old_tip"
git log --reverse --format='%h %s' "$old_base..$old_tip"
git switch atyrode-release
git rebase --onto "$release_commit" "$old_base"
new_count="$(git rev-list --count "$release_commit..atyrode-release")"
test "$new_count" -eq "$old_count"
git range-diff "$old_base..$old_tip" "$release_commit..atyrode-release"
git diff --stat "$release_commit"...atyrode-release
```

You MUST inspect every `range-diff` change. Conflict resolutions MAY adapt patches to new upstream APIs, but MUST preserve their observable contracts. An upstream release that absorbed a fork patch may reduce the commit count only after explicit operator review; NEVER let rebase silently drop it.

## 4. Verify and publish the fork release

You MUST run tests covering every commit in the preserved range. The current auth customization requires:

```console
bun test packages/ai/test/auth-broker-config-discovery.test.ts \
  packages/ai/test/auth-broker-remote-store.test.ts \
  packages/ai/test/auth-storage-account-identity.test.ts
(cd packages/ai && bun run check:types)
```

You MUST also format-check every supported file changed by the fork range:

```console
mapfile -d '' changed_files < <(
  git diff --name-only -z "$release_commit"...HEAD -- \
    '*.ts' '*.tsx' '*.js' '*.json' '*.yml' '*.yaml' '*.css'
)
if ((${#changed_files[@]} > 0)); then
  bunx biome check "${changed_files[@]}"
fi
```

Additional fork customizations MUST supply and run their own focused tests. All checks MUST pass before publishing. Then:

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
