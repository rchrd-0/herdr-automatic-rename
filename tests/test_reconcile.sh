#!/usr/bin/env bash
# Integration test: drive the real engine (automatic-rename.sh) against a fake herdr
# and assert the exact rename commands it issues. This exercises the full
# reconcile -- workspace grouping/numbering, tab naming + numbering, the
# placeholder-defer rule, agent numbering, and the --clear strip -- with no live
# herdr and no live shell.

set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
chmod +x "$MOCK" 2>/dev/null || true

# A fresh sandbox per scenario: isolated fixtures, rename log, state, and config.
setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-test.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures"; mkdir -p "$HERDR_MOCK_DIR"
  export HERDR_MOCK_LOG="$SB/renames.log"; : >"$HERDR_MOCK_LOG"
  export HERDR_BIN_PATH="$MOCK"
  export XDG_STATE_HOME="$SB/state"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"   # absent -> env toggles win
  export HERDR_CONFIG_FILE="$SB/herdr.toml"
  printf 'agent_panel_sort = "spaces"\n' >"$HERDR_CONFIG_FILE"
  export HERDR_SOCKET_PATH="$SB/herdr.sock"   # keeps herdr state reads (session.json) in the sandbox
  export SHELL_NAME=zsh
  unset HERDR_MOCK_VERSION HERDR_MOCK_NO_VERSION   # per-scenario opt-in; mock default is current herdr
  unset HIDE_SHELL                                 # per-scenario opt-in; default is off
}
fixture() { cat >"$HERDR_MOCK_DIR/$1"; }   # fixture <name>  (JSON on stdin)
run_event() { /usr/bin/env bash "$ENGINE" "$1"; }
log() { cat "$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB" 2>/dev/null || true; }

# ======================================================================
# Scenario 1: both features on. Grouped agent sort.
#   - two singleton workspaces -> [1]/[2]
#   - tab t1 at a zsh prompt, t2 running nvim -> named + numbered in one rename
#   - a background multi-pane tab (no resolvable pane) with a placeholder label
#     -> DEFERRED (no throwaway "[N] 3" flash)
#   - one agent -> [1], on the last herdr that accepts a bracketed agent name
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
export HERDR_MOCK_VERSION=0.7.4   # < 0.7.5: agent numbering is still possible
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[
  {"workspace_id":"w1","label":"api"},
  {"workspace_id":"w2","label":"web"}
]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false}
]}}
JSON
fixture tabs_w2.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w2:t1","label":"3","pane_count":2,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false},
  {"pane_id":"p3","tab_id":"w2:t1","focused":false},
  {"pane_id":"p4","tab_id":"w2:t1","focused":false}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[
  {"terminal_id":"term_a","pane_id":"w1:pA","name":"claude","agent_session":{"agent":"claude"}}
]}}
JSON
run_event tab.focused
out=$(log)
check_contains "ws1 numbered"          "$out" "workspace rename w1 [1] api"
check_contains "ws2 numbered"          "$out" "workspace rename w2 [2] web"
check_contains "tab1 named+numbered"   "$out" "tab rename w1:t1 [1] zsh"
check_contains "tab2 named+numbered"   "$out" "tab rename w1:t2 [2] nvim"
check_absent   "placeholder deferred"  "$out" "tab rename w2:t1"
check_contains "agent numbered by pane id" "$out" "agent rename w1:pA [1] claude"
check_absent   "agent never targeted by terminal id" "$out" "agent rename term_a"
teardown

# ======================================================================
# Scenario 2: NAME_TABS on, AUTO_INDEX off.
#   Tabs are named with NO prefix; workspaces and agents are left untouched.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[{"terminal_id":"term_a","pane_id":"w1:pA","name":"claude","agent_session":{"agent":"claude"}}]}}
JSON
run_event tab.focused
out=$(log)
check_contains "tab named without prefix" "$out" "tab rename w1:t1 zsh"
check_absent   "no workspace numbering"   "$out" "workspace rename"
check_absent   "no agent numbering"       "$out" "agent rename"
teardown

# ======================================================================
# Scenario 3: --clear strips every prefix and reverts the agent to detection.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] zsh","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[{"terminal_id":"term_a","pane_id":"w1:pA","name":"[1] claude","agent_session":{"agent":"claude"}}]}}
JSON
run_event --clear
out=$(log)
check_contains "ws prefix stripped"    "$out" "workspace rename w1 api"
check_contains "tab prefix stripped"   "$out" "tab rename w1:t1 zsh"
check_contains "agent reverted"        "$out" "agent rename w1:pA --clear"
teardown

# ======================================================================
# Scenario 4: a process-info blip must NOT clobber a named tab.
#   We already own w1:t1 as "nvim" (seeded state). process-info fails (no
#   fixture -> empty foreground process), so the base must stay "nvim" and the
#   already-correct "[1] nvim" label must not be rewritten to "[1] zsh".
#   Guards engine finding #1 (ar_tab_name must return "" on failure, not $SHELL).
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"nvim","enabled":true}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"code"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] nvim","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
# NOTE: no procinfo_p1.json -> the mock serves "{}" -> no resolvable foreground process.
run_event tab.focused
out=$(log)
check_absent "no clobber to shell name on blip" "$out" "zsh"
check_absent "owned tab left untouched on blip" "$out" "tab rename w1:t1"
teardown

# ======================================================================
# Scenario 5: the api-snapshot path. Same inputs and expected renames as
#   Scenario 1, but the engine's whole picture comes from ONE snapshot.json
#   (no workspaces.json / tabs_*.json / panes.json / agents.json). If the
#   snapshot path were skipped, the fallback would hit the mock's empty list
#   defaults and rename NOTHING -- so these renames appearing proves the
#   snapshot slices are parsed, ordered, and grouped-by-workspace correctly.
#   procinfo fixtures are still required: naming samples the foreground process
#   per tab, which the snapshot does not carry.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
export HERDR_MOCK_VERSION=0.7.4   # < 0.7.5: agent numbering is still possible
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[
    {"workspace_id":"w1","label":"api"},
    {"workspace_id":"w2","label":"web"}
  ],
  "tabs":[
    {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"},
    {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false,"workspace_id":"w1"},
    {"tab_id":"w2:t1","label":"3","pane_count":2,"focused":false,"workspace_id":"w2"}
  ],
  "panes":[
    {"pane_id":"p1","tab_id":"w1:t1","focused":true},
    {"pane_id":"p2","tab_id":"w1:t2","focused":false},
    {"pane_id":"p3","tab_id":"w2:t1","focused":false},
    {"pane_id":"p4","tab_id":"w2:t1","focused":false}
  ],
  "agents":[
    {"terminal_id":"term_a","pane_id":"w1:pA","name":"claude","agent_session":{"agent":"claude"}}
  ]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "snapshot: ws1 numbered"        "$out" "workspace rename w1 [1] api"
check_contains "snapshot: ws2 numbered"        "$out" "workspace rename w2 [2] web"
check_contains "snapshot: tab1 named+numbered" "$out" "tab rename w1:t1 [1] zsh"
check_contains "snapshot: tab2 named+numbered" "$out" "tab rename w1:t2 [2] nvim"
check_absent   "snapshot: placeholder deferred" "$out" "tab rename w2:t1"
check_contains "snapshot: agent numbered"      "$out" "agent rename w1:pA [1] claude"
teardown

# ======================================================================
# Scenario 6: process-info without an argv0 field (issue #6).
#   herdr's Linux builds report no argv0 at all -- only argv/cmdline/name. On
#   NixOS `name` is the on-disk executable, which for a wrapped program is the
#   internal `.<prog>-wrapped` binary, while argv[0] still carries what the user
#   typed. Naming must follow argv[0], not the wrapper.
#   p1: the reporter's payload -- `nh os switch` must read "nh", not ".nh-wrapped".
#   p2: a login shell, where argv[0] keeps the leading "-" that argv0 lacks.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":75757,
  "foreground_processes":[
    {"pid":75757,"argv":["nh","os","switch"],"cmdline":"nh os switch","name":".nh-wrapped"},
    {"pid":75998,"argv":["nix","build","x"],"cmdline":"nix build x","name":"nix"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv":["-zsh"],"cmdline":"-zsh","name":".zsh-wrapped"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "argv[0] names the tab, not the wrapper" "$out" "tab rename w1:t1 nh"
check_absent   "wrapper name never shown"               "$out" "wrapped"
check_contains "login shell argv[0] strips the dash"    "$out" "tab rename w1:t2 zsh"
teardown

# ======================================================================
# Scenario 7: herdr >= 0.7.5 restricts agent names to ^[a-z][a-z0-9_-]{0,31}$,
#   so "[N] claude" can never be set. Numbering must be skipped even though the
#   panel is grouped-sorted, and an "[1] claude" left behind by an older
#   herdr + older plugin must be reverted to detection (the upgrade path: that
#   name is otherwise stuck, including through the uninstall --clear).
#   Workspaces and tabs are unaffected -- their labels stay free-form.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1
export HERDR_MOCK_VERSION=0.8.0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[
  {"terminal_id":"term_a","pane_id":"w1:pA","name":"[1] claude","agent_session":{"agent":"claude"}},
  {"terminal_id":"term_b","pane_id":"w1:pB","name":"my-session","agent_session":{"agent":"codex"}}
]}}
JSON
run_event tab.focused
out=$(log)
check_absent   "no bracketed agent name attempted" "$out" "[1] claude"
check_contains "legacy agent prefix reverted"      "$out" "agent rename w1:pA --clear"
check_absent   "user-named agent left alone"       "$out" "agent rename w1:pB"
check_contains "workspaces still numbered"         "$out" "workspace rename w1 [1] api"
check_contains "tabs still named and numbered"     "$out" "tab rename w1:t1 [1] zsh"
teardown

# ======================================================================
# Scenario 8: an unreadable herdr version must NOT unlock agent numbering.
#   The mock serves no version at all, so ar_herdr_version fails and the engine
#   has to assume the restrictive herdr rather than issuing a rename that a real
#   herdr would reject.
# ======================================================================
setup
export NAME_TABS=0 AUTO_INDEX=1
export HERDR_MOCK_NO_VERSION=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture agents.json <<'JSON'
{"result":{"agents":[{"terminal_id":"term_a","pane_id":"w1:pA","name":"claude","agent_session":{"agent":"claude"}}]}}
JSON
run_event tab.focused
out=$(log)
check_absent   "unknown version does not number agents" "$out" "agent rename w1:pA [1]"
check_contains "workspaces unaffected"                  "$out" "workspace rename w1 [1] api"
teardown

# ======================================================================
# Scenario 9: HIDE_SHELL=1 with AUTO_INDEX=0 (issue #5).
#   A shell tab is renamed to the EMPTY label so herdr renders its own number;
#   an nvim tab is named as usual. The state file must record the empty name as
#   ours, or the next pass would read herdr's number back as a hand rename.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0 HIDE_SHELL=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"fish","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-fish","cmdline":"-fish"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
# t1 is ours, named "fish" by an earlier pass, so the knob has a label to undo.
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"fish","enabled":true}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
run_event tab.focused
out=$(log)
check "shell tab renamed to nothing" "tab rename w1:t1 " "$(printf '%s\n' "$out" | grep 'w1:t1')"
check_contains "nvim tab still named"  "$out" "tab rename w1:t2 nvim"
check "empty name recorded as ours" "true" \
  "$(jq -r '."w1:t1" | (.auto == "") and .enabled' "$XDG_STATE_HOME/herdr-automatic-rename/state.json")"
teardown

# ======================================================================
# Scenario 10: HIDE_SHELL=1 with AUTO_INDEX=1.
#   The jump number is the one thing numbering exists for, so a hidden shell tab
#   keeps "[N]" alone. The next pass must read that back as OUR label (empty base,
#   still owned) and leave it alone rather than opting the tab out.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1 HIDE_SHELL=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] zsh","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"zsh","enabled":true}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
run_event tab.focused
check_contains "numbered shell tab keeps the number only" "$(log)" "tab rename w1:t1 [1]"
# Second pass over the settled "[1]" label: no further rename, still ours.
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1]","pane_count":1,"focused":true}]}}
JSON
: >"$HERDR_MOCK_LOG"
run_event tab.focused
check "settled [N] label is stable" "" "$(printf '%s\n' "$(log)" | grep 'tab rename')"
check "still owned after settling" "true" \
  "$(jq -r '."w1:t1".enabled' "$XDG_STATE_HOME/herdr-automatic-rename/state.json")"
teardown

# ======================================================================
# Scenario 11: HIDE_SHELL and the two ways an empty label must NOT be touched.
#   a) --clear strips a leftover "[1]" off a hidden tab (the uninstall path).
#   b) A process-info blip on a hidden tab leaves the label alone: the old
#      "empty base -> skip" guard now runs on HIDE_SHELL, so nothing may make it
#      guess "[1]" for a tab whose program it could not read.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1 HIDE_SHELL=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1]","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
run_event --clear
check "clear strips a number-only label" "tab rename w1:t1 " "$(printf '%s\n' "$(log)" | grep 'w1:t1')"
teardown

setup
export NAME_TABS=1 AUTO_INDEX=1 HIDE_SHELL=1
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"nvim","enabled":true}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"code"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] nvim","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
# NOTE: no procinfo_p1.json -> process-info resolves nothing.
run_event tab.focused
check_absent "blip does not hide a named tab" "$(log)" "tab rename w1:t1"
teardown

# ======================================================================
# Scenario 12: a hidden tab whose program can't be sampled must still be
#   renumbered. A background multi-pane tab exposes no active pane at all, so its
#   name is never computable -- but its jump number still has to follow the tab
#   order, which is exactly what the "[i]"-only label has to keep working for.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1 HIDE_SHELL=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t9","label":"[2]","pane_count":2,"focused":false}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t9","focused":false},
  {"pane_id":"p2","tab_id":"w1:t9","focused":false}
]}}
JSON
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t9":{"auto":"","enabled":true}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
run_event tab.moved
check_contains "hidden tab follows its number" "$(log)" "tab rename w1:t9 [1]"
teardown

# ======================================================================
# Scenario 13: with HIDE_SHELL off, a name the config erased is not a name.
#   MAX_NAME_LEN=0 stands in for any rule that computes a name and then leaves
#   nothing of it (a catch-all SUBSTITUTE_SETS does the same). Only HIDE_SHELL
#   licenses blanking a tab, so this must leave the label alone.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=1 MAX_NAME_LEN=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] nvim","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
printf '{"w1:t1":{"auto":"nvim","enabled":true}}\n' >"$XDG_STATE_HOME/herdr-automatic-rename/state.json"
run_event tab.focused
check_absent "erased name does not blank a tab" "$(log)" "tab rename w1:t1"
unset MAX_NAME_LEN
teardown

# ======================================================================
# Scenario 14: cwd-aware naming reads cwd from the cached pane list.
#   foreground_cwd wins over cwd when both exist; cwd is the fallback when the
#   foreground value is absent. No separate cwd query is available in the mock.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0 SHOW_CWD=1
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"code"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"2","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true,"foreground_cwd":"/Users/test/code/foo","cwd":"/wrong/fallback"},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false,"cwd":"/Users/test/code/bar"}
]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
fixture procinfo_p2.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
run_event tab.focused
out=$(log)
check_contains "pane list: foreground cwd wins" "$out" "tab rename w1:t1 foo"
check_contains "pane list: cwd fallback is used" "$out" "tab rename w1:t2 nvim:bar"
check_absent "pane list: lower-priority cwd ignored" "$out" "fallback"
teardown

# ======================================================================
# Scenario 15: the snapshot pane slice carries cwd through the same resolver.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0 SHOW_CWD=1
fixture snapshot.json <<'JSON'
{"result":{"snapshot":{
  "workspaces":[{"workspace_id":"w1","label":"code"}],
  "tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true,"workspace_id":"w1"}],
  "panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true,"foreground_cwd":"/Users/test/code/project"}],
  "agents":[]
}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"codex","cmdline":"codex"}]}}}
JSON
run_event tab.focused
check_contains "snapshot: foreground cwd reaches formatter" "$(log)" "tab rename w1:t1 codex:project"
teardown

# ======================================================================
# Scenario 16: disabling cwd display keeps the existing name even when the
#   cached pane has cwd data.
# ======================================================================
setup
export NAME_TABS=1 AUTO_INDEX=0 SHOW_CWD=0
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"code"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true,"foreground_cwd":"/Users/test/code/project"}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
run_event tab.focused
check_contains "SHOW_CWD disabled: existing reconcile output" "$(log)" "tab rename w1:t1 nvim"
check_absent "SHOW_CWD disabled: no cwd suffix" "$(log)" "project"
teardown

t_summary
