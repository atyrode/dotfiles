# Backup of local-only git state: dotfiles-owner-rpc-repository (2026-11-11)

`dotfiles-owner-rpc-repository.bundle` holds every branch, stash and working-tree snapshot that existed only in the local clone
`/home/alex/dotfiles-owner-rpc-repository` on 2026-11-11 (see `MANIFEST.tsv`). Original commits are preserved exactly, with the same SHAs.
The bundle is thin: it needs the history of `origin/main`.

Excluded on purpose: squash-merged branches whose PR head matches the local tip (their content is in the default branch);
`node_modules`; build/cache directories; files named like secrets; untracked files above 20 MB.

## Restore

```sh
git fetch origin refs/backup/2026-11-11/dotfiles-owner-rpc-repository/bundle
git cat-file blob FETCH_HEAD:dotfiles-owner-rpc-repository.bundle > /tmp/dotfiles-owner-rpc-repository.bundle
git bundle verify /tmp/dotfiles-owner-rpc-repository.bundle
git fetch /tmp/dotfiles-owner-rpc-repository.bundle 'refs/backup/2026-11-11/*:refs/backup/2026-11-11/*'
git for-each-ref refs/backup/2026-11-11
```

Stashes: `git stash apply <ref>`. Working-tree snapshots are commits on top of the worktree's HEAD: `git diff <ref>^ <ref>`.
