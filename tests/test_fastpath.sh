#!/usr/bin/env bash
# Integration tests for the preexec/precmd fast path against the fake herdr.
#
# The bug that motivated the "shell" marker: zsh expands aliases in preexec's
# $2 but never expands functions, so calling a function `l` handed the engine
# the literal word "l". No program list can match a function name, so the tab
# flashed "l" and precmd snapped it back -- a flicker on every instant function.
# The hooks now classify the command word; anything that is not an external
# command gets a trailing "shell" marker, and the engine names the tab by the
# pane's REAL foreground process (sampled after a short settle) instead of by
# the typed word. New hook calls place cwd before that marker; the legacy form
# without cwd remains supported.

set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
chmod +x "$MOCK" 2>/dev/null || true

# Sandbox mirroring test_reconcile.sh, plus the tab/pane identity the fast path
# reads from the environment (HERDR_TAB_ID / HERDR_PANE_ID) and a seeded state
# file that marks tab t1 as owned with base "zsh" (so it is rename-eligible).
setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-fast.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures"; mkdir -p "$HERDR_MOCK_DIR"
  export HERDR_MOCK_LOG="$SB/renames.log"; : >"$HERDR_MOCK_LOG"
  export HERDR_BIN_PATH="$MOCK"
  export XDG_STATE_HOME="$SB/state"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"
  export HERDR_SOCKET_PATH="$SB/herdr.sock"   # keeps herdr state reads (session.json) in the sandbox
  export SHELL_NAME=zsh
  export NAME_TABS=1 AUTO_INDEX=1
  unset HIDE_SHELL                            # per-scenario opt-in; default is off
  export HERDR_TAB_ID=t1 HERDR_PANE_ID=p1
  mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
  printf '{"t1":{"auto":"zsh","enabled":true}}\n' \
    >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
  fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"[1] zsh"}}}
JSON
}
fixture() { cat >"$HERDR_MOCK_DIR/$1"; }
log() { cat "$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB" 2>/dev/null || true; }

# ======================================================================
# Scenario 1: instant shell function (the flicker bug).
#   preexec "l" shell; by sample time the function has exited, so the pane's
#   foreground leader is the shell again. The tab must NOT be renamed -- the
#   old behavior renamed it to "[1] l" and precmd flapped it back.
# ======================================================================
setup
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
/usr/bin/env bash "$ENGINE" preexec "l" shell
check "instant function: no rename" "" "$(log)"
teardown

# ======================================================================
# Scenario 2: function wrapping a long-running program.
#   preexec "v" shell; at sample time nvim holds the foreground, so the tab is
#   named after the real program, not the function word.
# ======================================================================
setup
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
/usr/bin/env bash "$ENGINE" preexec "v" shell
check "wrapped program: named by foreground" "tab rename t1 [1] nvim" "$(log)"
teardown

# ======================================================================
# Scenario 3: sampling fails (no process-info) -> rename nothing, never guess.
# ======================================================================
setup
# NOTE: no procinfo_p1.json -> the mock serves "{}" -> no resolvable process.
/usr/bin/env bash "$ENGINE" preexec "l" shell
check "sample failure: no rename" "" "$(log)"
teardown

# ======================================================================
# Scenario 4: external command without the marker -- the pre-existing instant
# path must be untouched (renames from the typed word, no process-info call).
# ======================================================================
setup
/usr/bin/env bash "$ENGINE" preexec "nvim README.md"
check "external command: instant rename" "tab rename t1 [1] nvim" "$(log)"
teardown

# ======================================================================
# Scenario 5: precmd back at the prompt reverts to the shell name.
# ======================================================================
setup
fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"[1] nvim"}}}
JSON
printf '{"t1":{"auto":"nvim","enabled":true}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
/usr/bin/env bash "$ENGINE" precmd zsh
check "precmd: back to shell name" "tab rename t1 [1] zsh" "$(log)"
teardown

# ======================================================================
# Scenario 6: HIDE_SHELL=1 (issue #5). Back at the prompt the tab name goes away
# instead of reverting to the shell: "[1]" with numbering on, nothing at all with
# it off. Starting a real program still names the tab, prefix intact.
# ======================================================================
setup
export HIDE_SHELL=1
fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"[1] nvim"}}}
JSON
printf '{"t1":{"auto":"nvim","enabled":true}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
/usr/bin/env bash "$ENGINE" precmd zsh
check "precmd hidden: number only" "tab rename t1 [1]" "$(log)"
check "hidden name recorded as ours" "true" \
  "$(jq -r '.t1 | (.auto == "") and .enabled' "$XDG_STATE_HOME/herdr-automatic-rename/state.json")"
teardown

setup
export HIDE_SHELL=1 AUTO_INDEX=0
fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"nvim"}}}
JSON
printf '{"t1":{"auto":"nvim","enabled":true}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
/usr/bin/env bash "$ENGINE" precmd fish
check "precmd hidden, index off: empty label" "tab rename t1 " "$(log)"
teardown

# A hidden tab (label "[1]", base empty) must still be recognized as ours when a
# program starts, and keep its number.
setup
export HIDE_SHELL=1
fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"[1]"}}}
JSON
printf '{"t1":{"auto":"","enabled":true}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
/usr/bin/env bash "$ENGINE" preexec "nvim README.md"
check "hidden tab named on preexec" "tab rename t1 [1] nvim" "$(log)"
teardown

# An already-hidden tab must not be renamed to the same thing on every prompt.
setup
export HIDE_SHELL=1
fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"[1]"}}}
JSON
printf '{"t1":{"auto":"","enabled":true}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
/usr/bin/env bash "$ENGINE" precmd zsh
check "hidden tab: no repeat rename" "" "$(log)"
teardown

# ======================================================================
# Scenario 7: new fast-path calls pass the shell's cwd directly.
# ======================================================================
setup
/usr/bin/env bash "$ENGINE" preexec "nvim README.md" "/Users/test/code/foo"
check "preexec: appends shell cwd" "tab rename t1 [1] nvim:foo" "$(log)"
teardown

# A prompt update uses the shell's current directory even with HIDE_SHELL on;
# this is the path that updates the name after `cd`.
setup
export HIDE_SHELL=1
fixture tab_t1.json <<'JSON'
{"result":{"tab":{"tab_id":"t1","label":"[1] nvim"}}}
JSON
printf '{"t1":{"auto":"nvim","enabled":true}}\n' \
  >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
/usr/bin/env bash "$ENGINE" precmd zsh "/Users/test/code/foo"
check "precmd: current cwd replaces shell" "tab rename t1 [1] foo" "$(log)"
teardown

# The new sampled form carries cwd before the shell marker. The legacy marker
# form remains covered by scenarios 1-3 above.
setup
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
/usr/bin/env bash "$ENGINE" preexec "v" "/Users/test/code/foo" shell
check "sampled preexec: appends shell cwd" "tab rename t1 [1] nvim:foo" "$(log)"
teardown

t_summary
