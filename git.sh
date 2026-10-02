# git.sh - what the repository holding a directory has checked out.
#
# Sourced by automatic-rename.sh, beside naming.sh and icons.sh. This is the one
# module that reads the FILESYSTEM (naming.sh reads strings, icons.sh is a
# table), which is why it is not in either of them.
#
# Everything here is read out of the files under .git and nothing runs git. A
# `git rev-parse` is a process; `HEAD` is one open, and this runs once per named
# tab on every herdr event and again on every shell prompt, where a fork per tab
# is exactly the cost that shows up as a slow prompt. Nothing is cached either:
# a fresh read costs less than remembering a stale answer, and a checkout shows
# up in the tab bar on the next event rather than whenever a cache expires.
#
# The answers come back in globals rather than on stdout, because a command
# substitution IS the fork this file exists to avoid. Targets bash 3.2, like the
# rest of the plugin.
#
# Checked on its own by shellcheck, where those globals have no reader in sight:
# the engine next door is what reads them.
# shellcheck disable=SC2034

# ar_git_line <path> -> sets AR_GIT_LINE to that file's first line, trimmed;
# rc 1 when there is nothing to read (missing file, a directory, an empty line).
#
# The redirect is what keeps this fork-free. `read` reports a last line with no
# newline as a failure and ref files written by hand often have none, so what
# was read decides, not the status.
#
# The order of the two redirections is load-bearing: they are applied left to
# right, so a `< "$1"` written first fails BEFORE stderr has been silenced and
# the shell prints the missing file on the terminal. Most of the files asked for
# here are absent in any given repository (a rebase is not usually in progress),
# so that is not an edge case.
ar_git_line() {
  local line=""
  AR_GIT_LINE=""
  # A REGULAR file, tested before it is opened. Reading from a fifo blocks
  # forever, and this runs inside the pass that holds the plugin's lock, so one
  # directory with a `.git/HEAD` that is not a file would stall every rename and
  # both actions behind it until the lock went stale.
  [ -f "$1" ] || return 1
  IFS= read -r line 2>/dev/null < "$1"
  line=${line#"${line%%[![:space:]]*}"}           # leading blanks
  line=${line%"${line##*[![:space:]]}"}           # trailing blanks, CR included
  [ -n "$line" ] || return 1
  AR_GIT_LINE=$line
}

# ar_git_dir <dir> -> sets AR_GIT_DIR (the directory holding HEAD) and
# AR_GIT_COMMON (the one holding the refs shared with the repository); rc 1 when
# <dir> is in no repository.
#
# The two differ in a linked worktree and in a submodule, where `.git` is a FILE
# naming a directory inside the main repository: that directory has the
# worktree's own HEAD but not the remote refs the default branch is read from.
# Agents run in worktrees, so this is not the exotic case.
#
# Relative paths are left relative on purpose. Every use of these is opening a
# file under them, and the kernel resolves `..` in a path perfectly well, so
# normalizing would be work done for nobody.
# It walks for `.git` much as ar_project_base does next door, and the two are
# deliberately not one function: that one answers "what does herdr call the
# workspace sitting here", so it stops at the first `.git` of any kind and never
# reads it, while this one has to open what it finds and can still answer "no
# repository" for a `.git` it cannot follow.
ar_git_dir() {
  local dir=$1 cand target
  AR_GIT_DIR=""
  AR_GIT_COMMON=""
  # herdr reports absolute directories; a relative one is a value that arrived
  # broken, and resolving it against the plugin's own cwd would answer for a
  # repository the pane has never been in.
  case $dir in /*) ;; *) return 1 ;; esac
  dir=${dir%/}
  while [ -n "$dir" ]; do
    cand=$dir/.git
    if [ -d "$cand" ]; then
      AR_GIT_DIR=$cand
      AR_GIT_COMMON=$cand
      return 0
    fi
    if [ -f "$cand" ]; then
      ar_git_line "$cand" || return 1
      case $AR_GIT_LINE in
      gitdir:*) target=${AR_GIT_LINE#gitdir:} ;;
      *) return 1 ;;                              # a `.git` file that points nowhere
      esac
      target=${target#"${target%%[![:space:]]*}"}
      [ -n "$target" ] || return 1
      case $target in /*) ;; *) target=$dir/$target ;; esac
      [ -d "$target" ] || return 1                # dangling: not a repository
      AR_GIT_DIR=$target
      if ar_git_line "$target/commondir"; then
        case $AR_GIT_LINE in
        /*) AR_GIT_COMMON=$AR_GIT_LINE ;;
        *) AR_GIT_COMMON=$target/$AR_GIT_LINE ;;
        esac
      else
        AR_GIT_COMMON=$target
      fi
      return 0
    fi
    dir=${dir%/*}
  done
  return 1
}

# ar_git_head <dir> -> sets AR_GIT_HEAD to the branch <dir>'s repository has
# checked out (or, detached, the short hash HEAD points at) and AR_GIT_DEFAULT to
# the branch that repository calls its trunk; rc 1 when there is nothing to say.
#
# AR_GIT_DEFAULT comes from the repository itself, not from a list of names, so a
# team whose trunk is `develop` gets the same silence a `main` one does -- and a
# branch actually called `main` off a `develop` trunk still shows. A repository
# nobody cloned records none, and then every branch it has is worth showing.
ar_git_head() {
  local head state
  AR_GIT_HEAD=""
  AR_GIT_DEFAULT=""
  ar_git_dir "$1" || return 1
  ar_git_line "$AR_GIT_DIR/HEAD" || return 1
  head=$AR_GIT_LINE
  case $head in
  "ref: refs/heads/"?*) AR_GIT_HEAD=${head#ref: refs/heads/} ;;
  *)
    # A rebase detaches HEAD and records the branch it set aside, which is still
    # where the user is: without this the tab takes a new hash on every step of
    # the rebase. Both backends record it, the merge one by default and the
    # apply one under `--apply` and `git am`.
    for state in rebase-merge rebase-apply; do
      if ar_git_line "$AR_GIT_DIR/$state/head-name"; then
        case $AR_GIT_LINE in
        refs/heads/?*)
          AR_GIT_HEAD=${AR_GIT_LINE#refs/heads/}
          break
          ;;
        esac
      fi
    done
    # Failing that, a detached HEAD, which is the one place a bare hash belongs
    # in a tab: it is where commits get lost, and silence there cannot be told
    # from sitting on the trunk. Checking the length is what keeps a HEAD holding
    # something else from being read as one -- 40 for sha1, 64 for a repository
    # built with sha256.
    if [ -z "$AR_GIT_HEAD" ]; then
      case ${#head} in
      40 | 64)
        case $head in
        *[!0-9a-fA-F]*) ;;
        *) AR_GIT_HEAD=${head:0:7} ;;             # what git itself abbreviates to
        esac
        ;;
      esac
    fi
    ;;
  esac
  [ -n "$AR_GIT_HEAD" ] || return 1
  # A symbolic ref, which `git pack-refs` leaves as a file, so there is no packed
  # form to look in.
  if ar_git_line "$AR_GIT_COMMON/refs/remotes/origin/HEAD"; then
    case $AR_GIT_LINE in
    "ref: refs/remotes/origin/"?*) AR_GIT_DEFAULT=${AR_GIT_LINE#ref: refs/remotes/origin/} ;;
    esac
  fi
  return 0
}
