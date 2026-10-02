#!/usr/bin/env bash
# Integration test: workspace numbering follows herdr's VISIBLE sidebar order.
#
# alt+N (switch_workspace) resolves through herdr's visible workspace order, so
# every rule that decides which rows the sidebar renders decides our numbers too:
# which worktree workspaces group into a space, which member heads the group, and
# which members a COLLAPSED space hides. Collapse lives on disk, in the client
# preference file herdr 0.9.0 keeps beside its other per-client state (and in
# session.json below 0.9.0) -- so these scenarios point $HERDR_SOCKET_PATH and
# $XDG_STATE_HOME at a sandbox and write the file herdr would have written.
#
# Reference (herdr 0.9.0 src/client/shell/sidebar.rs workspace_entries +
# src/client/shell/actions.rs KeybindAction::SwitchWorkspace).

set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
chmod +x "$MOCK" 2>/dev/null || true

# ======================================================================
# The order rule itself: ar_workspace_positions takes both inputs as arguments
# and reads nothing, so sourcing the engine (which runs nothing) exercises it
# directly. One repo with a main checkout and one linked worktree, then a plain
# workspace, is the smallest shape that shows every rule.
# ======================================================================
# shellcheck source=automatic-rename.sh
. "$ENGINE"

positions() { ar_workspace_positions "$1" "$2" | tr '\037' ' ' | tr '\n' '|'; }

WS='{"result":{"workspaces":[
  {"workspace_id":"wA","label":"main","focused":false,
   "worktree":{"repo_key":"/r/a/.git","is_linked_worktree":false}},
  {"workspace_id":"wB","label":"wt","focused":false,
   "worktree":{"repo_key":"/r/a/.git","is_linked_worktree":true}},
  {"workspace_id":"wC","label":"solo","focused":false,
   "worktree":{"repo_key":"/r/c/.git","is_linked_worktree":false}}
]}}'

check "expanded: every row numbered in order" \
  "wA main 1|wB wt 2|wC solo 3|" "$(positions "$WS" '[]')"
check "collapsed: member hidden, next row moves up" \
  "wA main 1|wB wt 0|wC solo 2|" "$(positions "$WS" '["/r/a/.git"]')"
check "collapsed: focused member stays rendered" \
  "wA main 1|wB wt 2|wC solo 3|" \
  "$(positions "${WS/\"workspace_id\":\"wB\",\"label\":\"wt\",\"focused\":false/\"workspace_id\":\"wB\",\"label\":\"wt\",\"focused\":true}" '["/r/a/.git"]')"
check "collapse key for an unknown repo changes nothing" \
  "wA main 1|wB wt 2|wC solo 3|" "$(positions "$WS" '["/r/z/.git"]')"
check "empty list yields no rows" "" "$(positions '{"result":{"workspaces":[]}}' '[]')"

# Numbering only: NAME_TABS off and no tab/pane fixtures, so the rename log holds
# workspace renames alone.
setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-wsorder.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures"; mkdir -p "$HERDR_MOCK_DIR"
  export HERDR_MOCK_LOG="$SB/renames.log"; : >"$HERDR_MOCK_LOG"
  export HERDR_BIN_PATH="$MOCK"
  export XDG_STATE_HOME="$SB/state"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"   # absent -> env toggles win
  export HERDR_CONFIG_FILE="$SB/herdr.toml"
  printf 'agent_panel_sort = "spaces"\n' >"$HERDR_CONFIG_FILE"
  export HERDR_SOCKET_PATH="$SB/herdr.sock"            # session.json sits beside it
  export SHELL_NAME=zsh
  export NAME_TABS=0 AUTO_INDEX=1
}
fixture() { cat >"$HERDR_MOCK_DIR/$1"; }
# collapsed <json-array>  -- write the client preference file herdr 0.9.0 keeps
# collapse in. The path is the engine's own derivation, so a change to it that
# stopped matching herdr would break these scenarios rather than pass quietly.
collapsed() {
  local f
  f=$(ar_herdr_client_prefs)
  mkdir -p "${f%/*}"
  printf '{"sidebar_width":26,"collapsed_groups":%s}\n' "$1" >"$f"
}
# collapsed_legacy <json-array>  -- the same answer from where herdr below 0.9.0
# kept it, with no client file present.
collapsed_legacy() {
  rm -f "$(ar_herdr_client_prefs)"
  printf '{"version":7,"collapsed_space_keys":%s,"workspaces":[]}\n' "$1" >"$SB/session.json"
}
run_event() { /usr/bin/env bash "$ENGINE" "$1"; }
log() { cat "$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB" 2>/dev/null || true; }

# Repo keys, as herdr reports them (.worktree.repo_key) and persists them
# (collapsed_space_keys holds exactly these strings).
MONO=/repos/fh-mono/.git
FOCUS=/repos/focusbeacon/.git
CHEZ=/repos/chezmoi/.git

# The bug's exact shape: one main checkout (fh-mono) with two linked worktrees,
# a plain workspace before it and another after it.
fixture_bug_shape() {
  fixture workspaces.json <<JSON
{"result":{"workspaces":[
  {"workspace_id":"w1","label":"[1] personal","focused":${1:-true},
   "worktree":{"repo_key":"$CHEZ","is_linked_worktree":false}},
  {"workspace_id":"w2","label":"[2] fh-mono","focused":false,
   "worktree":{"repo_key":"$MONO","is_linked_worktree":false}},
  {"workspace_id":"w3","label":"[3] fh-9183","focused":${2:-false},
   "worktree":{"repo_key":"$MONO","is_linked_worktree":true}},
  {"workspace_id":"w4","label":"[4] fh-9090","focused":false,
   "worktree":{"repo_key":"$MONO","is_linked_worktree":true}},
  {"workspace_id":"w5","label":"[5] focusbeacon","focused":false,
   "worktree":{"repo_key":"$FOCUS","is_linked_worktree":false}}
]}}
JSON
}

# ======================================================================
# Scenario 1: a COLLAPSED space hides its non-parent members from alt+N, so the
#   workspaces after it move up. The hidden rows lose their number: no keybind
#   reaches them, exactly like position 10+.
# ======================================================================
setup
fixture_bug_shape true false
collapsed "[\"$MONO\"]"
run_event tab.focused
out=$(log)
check_absent   "collapsed: parent keeps [1]"     "$out" "workspace rename w1"
check_absent   "collapsed: fh-mono keeps [2]"    "$out" "workspace rename w2"
check_contains "collapsed: hidden member bare"   "$out" "workspace rename w3 fh-9183"
check_contains "collapsed: hidden member 2 bare" "$out" "workspace rename w4 fh-9090"
check_contains "collapsed: next ws moves to [3]" "$out" "workspace rename w5 [3] focusbeacon"
teardown

# ======================================================================
# Scenario 2: herdr keeps the ACTIVE member of a collapsed space rendered
#   (indented under its parent), so it still holds a number -- and pushes the
#   rows after it down by one.
# ======================================================================
setup
fixture_bug_shape false true
collapsed "[\"$MONO\"]"
run_event tab.focused
out=$(log)
check_absent   "active member: parent keeps [1]"  "$out" "workspace rename w1"
check_absent   "active member: fh-mono keeps [2]" "$out" "workspace rename w2"
check_absent   "active member keeps [3]"          "$out" "workspace rename w3"
check_contains "active member: other one bare"    "$out" "workspace rename w4 fh-9090"
check_contains "active member: next ws to [4]"    "$out" "workspace rename w5 [4] focusbeacon"
teardown

# ======================================================================
# Scenario 3: expanded (nothing collapsed) numbers every row in sidebar order --
#   the pre-collapse behavior, unchanged.
# ======================================================================
setup
fixture_bug_shape true false
collapsed "[]"
run_event tab.focused
out=$(log)
check_absent "expanded: no renames needed" "$out" "workspace rename"
teardown

# ======================================================================
# Scenario 4: neither file present (a herdr too old to persist collapse at all,
#   or a client that has never collapsed anything) degrades to "everything
#   expanded", which is what the plugin did before it read collapse.
# ======================================================================
setup
fixture_bug_shape true false
run_event tab.focused
out=$(log)
check_absent "no collapse on disk: assume expanded" "$out" "workspace rename"
teardown

# ======================================================================
# Scenario 4b: below herdr 0.9.0 the server kept collapse in session.json and
#   wrote no client file, so the same collapse has to reach the numbers from
#   there. The file that is present picks the source, not a version test.
# ======================================================================
setup
fixture_bug_shape true false
collapsed_legacy "[\"$MONO\"]"
run_event tab.focused
out=$(log)
check_contains "legacy: hidden member bare"      "$out" "workspace rename w3 fh-9183"
check_contains "legacy: next ws moves to [3]"    "$out" "workspace rename w5 [3] focusbeacon"
teardown

# ======================================================================
# Scenario 4c: on 0.9.0 the server writes an empty collapsed_space_keys whatever
#   the sidebar shows, so a session.json saying "nothing collapsed" must not
#   overrule the client file that says otherwise. This is the shape the numbers
#   went stale in: reading the server's copy answered "expanded" for every
#   collapsed space.
# ======================================================================
setup
fixture_bug_shape true false
printf '{"version":7,"collapsed_space_keys":[],"workspaces":[]}\n' >"$SB/session.json"
collapsed "[\"$MONO\"]"
run_event tab.focused
out=$(log)
check_contains "client file wins: hidden member bare"   "$out" "workspace rename w3 fh-9183"
check_contains "client file wins: next ws moves to [3]" "$out" "workspace rename w5 [3] focusbeacon"
teardown

# ======================================================================
# Scenario 5: a space needs 2+ members AND a main (non-linked) checkout to group.
#   Two linked worktrees whose repo has no open main workspace stay top-level
#   rows in ARRAY order -- interleaved with other repos, and immune to a stale
#   collapse key for that repo.
# ======================================================================
setup
fixture workspaces.json <<JSON
{"result":{"workspaces":[
  {"workspace_id":"w1","label":"alpha","focused":true,
   "worktree":{"repo_key":"$CHEZ","is_linked_worktree":false}},
  {"workspace_id":"w2","label":"wt-x","focused":false,
   "worktree":{"repo_key":"$MONO","is_linked_worktree":true}},
  {"workspace_id":"w3","label":"beta","focused":false,
   "worktree":{"repo_key":"$FOCUS","is_linked_worktree":false}},
  {"workspace_id":"w4","label":"wt-y","focused":false,
   "worktree":{"repo_key":"$MONO","is_linked_worktree":true}}
]}}
JSON
collapsed "[\"$MONO\"]"
run_event tab.focused
out=$(log)
check_contains "ungrouped: w1 [1]" "$out" "workspace rename w1 [1] alpha"
check_contains "ungrouped: w2 [2]" "$out" "workspace rename w2 [2] wt-x"
check_contains "ungrouped: w3 [3]" "$out" "workspace rename w3 [3] beta"
check_contains "ungrouped: w4 [4]" "$out" "workspace rename w4 [4] wt-y"
teardown

# ======================================================================
# Scenario 6: the group's first row is its MAIN checkout, even when a linked
#   worktree of the same repo comes earlier in the list. The space still renders
#   at the first member's slot; the main checkout heads it.
# ======================================================================
setup
fixture workspaces.json <<JSON
{"result":{"workspaces":[
  {"workspace_id":"w1","label":"wt-x","focused":false,
   "worktree":{"repo_key":"$MONO","is_linked_worktree":true}},
  {"workspace_id":"w2","label":"main-b","focused":true,
   "worktree":{"repo_key":"$MONO","is_linked_worktree":false}},
  {"workspace_id":"w3","label":"gamma","focused":false,
   "worktree":{"repo_key":"$FOCUS","is_linked_worktree":false}}
]}}
JSON
collapsed "[]"
run_event tab.focused
out=$(log)
check_contains "main checkout heads group" "$out" "workspace rename w2 [1] main-b"
check_contains "worktree member second"    "$out" "workspace rename w1 [2] wt-x"
check_contains "next repo third"           "$out" "workspace rename w3 [3] gamma"
teardown

# ======================================================================
# Scenario 7: same rules on the api-snapshot path (herdr >= 0.7.2), where the
#   workspace list arrives inside snapshot.json instead of workspace list.
# ======================================================================
setup
fixture snapshot.json <<JSON
{"result":{"snapshot":{"workspaces":[
  {"workspace_id":"w2","label":"[2] fh-mono","focused":true,
   "worktree":{"repo_key":"$MONO","is_linked_worktree":false}},
  {"workspace_id":"w3","label":"[3] fh-9183","focused":false,
   "worktree":{"repo_key":"$MONO","is_linked_worktree":true}},
  {"workspace_id":"w5","label":"[5] focusbeacon","focused":false,
   "worktree":{"repo_key":"$FOCUS","is_linked_worktree":false}}
],"tabs":[],"panes":[],"agents":[]}}}
JSON
collapsed "[\"$MONO\"]"
run_event tab.focused
out=$(log)
check_contains "snapshot: fh-mono to [1]"      "$out" "workspace rename w2 [1] fh-mono"
check_contains "snapshot: hidden member bare"  "$out" "workspace rename w3 fh-9183"
check_contains "snapshot: focusbeacon to [2]"  "$out" "workspace rename w5 [2] focusbeacon"
teardown

t_summary
