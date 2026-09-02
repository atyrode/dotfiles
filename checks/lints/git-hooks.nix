{ lib, pkgs }:

# The fleet-wide git hooks run in every repository on every machine, so a
# defect in one is a defect everywhere at once. Each is exercised against a
# real repository: the pre-commit hook must refuse a credential-shaped stage
# and accept a clean one, and both hooks must hand over to a repository's own
# hook, which a global hooks path otherwise hides from git. The token planted
# below is assembled at run time so this source never contains the shape it
# tests for.
let
  preCommit = pkgs.writeScript "pre-commit" (
    builtins.replaceStrings [ "@gitleaks@" ] [ (lib.getExe pkgs.gitleaks) ] (
      builtins.readFile ../../modules/home/git/pre-commit
    )
  );
  prePush = pkgs.writeScript "pre-push" (builtins.readFile ../../modules/home/git/pre-push);
in
pkgs.runCommand "check-git-hooks"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.bash
    ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME/hooks" "$TMPDIR/repo"
    cp ${preCommit} "$HOME/hooks/pre-commit"
    cp ${prePush} "$HOME/hooks/pre-push"
    chmod +x "$HOME/hooks/"*
    patchShebangs "$HOME/hooks"
    cd "$TMPDIR/repo"
    git init -q
    git config user.name fixture
    git config user.email fixture@example.invalid
    git config core.hooksPath "$HOME/hooks"

    printf 'plain text\n' > clean.txt
    git add clean.txt
    git commit -q -m clean || { echo "a clean stage must commit" >&2; exit 1; }

    # Two halves so the assembled string exists only in memory.
    planted="ghp_9Kq2ZxT3vB7nM4pL8w""R5yH6cJ1sA0dF9eGtU2Lx"
    printf 'token = "%s"\n' "$planted" > leak.txt
    git add leak.txt
    if git commit -q -m leak 2>"$TMPDIR/refused.err"; then
      echo "a credential-shaped stage must be refused" >&2
      exit 1
    fi
    grep -qE 'RuleID: +github-pat' "$TMPDIR/refused.err" \
      || { echo "the refusal must name the rule" >&2; cat "$TMPDIR/refused.err" >&2; exit 1; }
    grep -q 'Commit refused' "$TMPDIR/refused.err" \
      || { echo "the refusal must say what happened" >&2; exit 1; }
    if grep -q "$planted" "$TMPDIR/refused.err"; then
      echo "the refusal must not echo the value" >&2
      exit 1
    fi
    git rm -q --cached leak.txt
    rm leak.txt

    # A repository's own pre-commit hook still runs after the scan.
    mkdir -p .git/hooks
    printf '#!/bin/sh\ntouch "$TMPDIR/local-pre-commit-ran"\n' > .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    printf 'more\n' >> clean.txt
    git add clean.txt
    git commit -q -m chained
    test -e "$TMPDIR/local-pre-commit-ran" \
      || { echo "the repository's own pre-commit hook must be chained" >&2; exit 1; }

    # The pre-push hook passes non-GitHub pushes through to the local hook
    # with the ref list intact.
    printf '#!/bin/sh\ncat > "$TMPDIR/local-pre-push-stdin"\n' > .git/hooks/pre-push
    chmod +x .git/hooks/pre-push
    printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(printf '0%.0s' $(seq 1 40))" \
      | "$HOME/hooks/pre-push" origin https://example.invalid/repo.git
    grep -q '^refs/heads/main ' "$TMPDIR/local-pre-push-stdin" \
      || { echo "the repository's own pre-push hook must receive the ref list" >&2; exit 1; }

    mkdir "$out"
  ''
