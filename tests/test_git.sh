#!/usr/bin/env bash
# Unit tests for git.sh -- what the repository holding a directory has checked
# out, read from the files under .git rather than by running git.
#
# The fixtures are built by hand rather than with `git init`, because what is
# under test is the parsing of those files: a fixture git wrote would prove the
# reader agrees with this machine's git version and nothing about the layouts it
# has to survive (a worktree, a rebase, a repository with no origin). One real
# `git init` at the end checks the hand-built shapes against the real thing.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
# shellcheck source=git.sh
. "$here/../git.sh"

SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-git.XXXXXX")

# head <dir> -> "<branch or short hash>|<default branch>", or "-" when the
# directory is in no repository. One string so a check reads as one line.
head_of() {
  if ar_git_head "$1"; then printf '%s|%s' "$AR_GIT_HEAD" "$AR_GIT_DEFAULT"; else printf -- '-'; fi
}

# ---- a plain checkout ----
mkdir -p "$SB/repo/.git/refs/remotes/origin" "$SB/repo/src"
printf 'ref: refs/heads/feature/oauth\n' >"$SB/repo/.git/HEAD"
printf 'ref: refs/remotes/origin/main\n' >"$SB/repo/.git/refs/remotes/origin/HEAD"
check "the checked-out branch" "feature/oauth|main" "$(head_of "$SB/repo")"
check "read from a subdirectory too" "feature/oauth|main" "$(head_of "$SB/repo/src")"
check "outside a repository, nothing" "-" "$(head_of "$SB")"
check "a relative path is refused" "-" "$(head_of "repo/src")"
check "an empty path is refused" "-" "$(head_of "")"

# A repository nobody cloned records no default branch, so every branch it has
# is worth showing. The head still reads.
rm -f "$SB/repo/.git/refs/remotes/origin/HEAD"
check "no origin, no default" "feature/oauth|" "$(head_of "$SB/repo")"
printf 'ref: refs/remotes/origin/main\n' >"$SB/repo/.git/refs/remotes/origin/HEAD"

# ---- detached HEAD ----
# Where commits get lost, and silence there is indistinguishable from sitting on
# the trunk, so the hash is the answer. Abbreviated to the seven git prints.
printf '3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a\n' >"$SB/repo/.git/HEAD"
check "a detached HEAD is its short hash" "3f2a1b9|main" "$(head_of "$SB/repo")"
# A sha256 repository's hash is 64 characters and abbreviates the same way.
printf '%s\n' "$(printf 'a%.0s' $(seq 64))" >"$SB/repo/.git/HEAD"
check "a sha256 HEAD abbreviates too" "aaaaaaa|main" "$(head_of "$SB/repo")"
# Anything that is neither a ref nor a whole hash is not a HEAD this can read,
# and a tab label is not the place to find that out.
printf 'not a ref at all\n' >"$SB/repo/.git/HEAD"
check "an unreadable HEAD says nothing" "-" "$(head_of "$SB/repo")"
printf '' >"$SB/repo/.git/HEAD"
check "an empty HEAD says nothing" "-" "$(head_of "$SB/repo")"

# ---- a rebase in progress ----
# A rebase detaches HEAD and records the branch it set aside. That branch is
# still where the user is, so the tab keeps its name instead of taking a new
# hash on every step.
printf '3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a\n' >"$SB/repo/.git/HEAD"
mkdir -p "$SB/repo/.git/rebase-merge"
printf 'refs/heads/feature/oauth\n' >"$SB/repo/.git/rebase-merge/head-name"
check "a rebase keeps the branch" "feature/oauth|main" "$(head_of "$SB/repo")"
rm -rf "$SB/repo/.git/rebase-merge"
# `git am` and `rebase --apply` use the other backend, which records it in
# another directory under the same name.
mkdir -p "$SB/repo/.git/rebase-apply"
printf 'refs/heads/hotfix\n' >"$SB/repo/.git/rebase-apply/head-name"
check "the apply backend too" "hotfix|main" "$(head_of "$SB/repo")"
rm -rf "$SB/repo/.git/rebase-apply"

# ---- a linked worktree ----
# Its `.git` is a FILE pointing at a directory inside the main repository, which
# holds its own HEAD but not the remote refs the default branch lives in. Agents
# run in worktrees, so this is the layout the feature is most often read from.
mkdir -p "$SB/repo/.git/worktrees/wt/"
printf 'ref: refs/heads/feature/parser\n' >"$SB/repo/.git/worktrees/wt/HEAD"
printf '../..\n' >"$SB/repo/.git/worktrees/wt/commondir"
mkdir -p "$SB/wt/src"
printf 'gitdir: %s\n' "$SB/repo/.git/worktrees/wt" >"$SB/wt/.git"
printf 'ref: refs/heads/main\n' >"$SB/repo/.git/HEAD"
check "a worktree reads its own HEAD" "feature/parser|main" "$(head_of "$SB/wt")"
check "and from inside it" "feature/parser|main" "$(head_of "$SB/wt/src")"
# The pointer may be relative to the file holding it, which is what `git
# worktree add` writes when the worktree sits beside the repository.
printf 'gitdir: ../repo/.git/worktrees/wt\n' >"$SB/wt/.git"
check "a relative gitdir is followed" "feature/parser|main" "$(head_of "$SB/wt")"
# A `.git` file pointing nowhere is not a repository, and guessing from the
# directory above it would name the tab after somebody else's branch.
printf 'gitdir: %s/nope\n' "$SB" >"$SB/wt/.git"
check "a dangling gitdir says nothing" "-" "$(head_of "$SB/wt")"
printf 'this is not a gitdir line\n' >"$SB/wt/.git"
check "a .git file that is not a pointer" "-" "$(head_of "$SB/wt")"

# ---- a ref file that is not a file ----
# Reading a fifo blocks forever, and this runs inside the pass holding the
# plugin's lock: one directory with a `.git/HEAD` like this would stall every
# rename behind it. The test hangs rather than fails if the guard goes, which is
# the honest way to notice.
if command -v mkfifo >/dev/null 2>&1; then
  mkdir -p "$SB/fifo/.git"
  mkfifo "$SB/fifo/.git/HEAD" 2>/dev/null
  check "a HEAD that is not a regular file" "-" "$(head_of "$SB/fifo")"
else
  check "mkfifo absent: skipped" "" ""
fi

# ---- against real git, if it is here ----
# The hand-built fixtures above are the point of this file; this one check is
# what says they are the shapes git actually writes.
if command -v git >/dev/null 2>&1; then
  mkdir -p "$SB/real"
  # The GIT_* variables are unset because this suite also runs from a git hook
  # (the pre-commit gate), which exports GIT_DIR and GIT_INDEX_FILE pointing at
  # the repository being committed -- `git init` under those does not make a
  # repository here, and the check failed for a reason that had nothing to do
  # with the code.
  ( cd "$SB/real" \
    && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR \
    && git init -q -b trunk . && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  ar_git_head "$SB/real"
  check "a real repository's branch" "trunk" "$AR_GIT_HEAD"
else
  check "git absent: skipped" "" ""
fi

rm -rf "$SB"
t_summary
