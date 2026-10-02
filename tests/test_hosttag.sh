#!/usr/bin/env bash
# Tests for the HOST_PREFIX host tag: the three review findings on PR #24, each
# pinned as the behavior a fix has to land on.
#
# Unit half: sourcing the engine defines ar_tab_strip_prefix without running
# anything (the ar_main guard), so the strip is checked strings in, strings out.
# Integration half: the real engine against tests/mocks/herdr, mirroring the
# harnesses of tests/test_prefix.sh and tests/test_reconcile.sh.
#
# The tag is whatever ar_host_tag derives on the machine running the suite
# (short uname -n + the default separator), computed here the same way, because
# the engine derives it live and the label fixtures have to carry the same
# spelling.

set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
# shellcheck source=automatic-rename.sh
. "$here/../automatic-rename.sh"

TAG="$(uname -n 2>/dev/null)"; TAG="${TAG%%.*}: "

# ======================================================================
# Review finding: the through-the-marker cut must not reach a bracketed
# number in the middle of a hand name. The cut exists for an unspellable
# tag ahead of the plugin's own "[N] " marker, but its pattern let any
# text ahead of any bracket fire it, so "notes [2] draft" lost everything
# before the bracket -- while the knob was on, and under --clear on a
# session that never set it.
# ======================================================================
unset CLEAR
HOST_PREFIX=1
check "strip: exact tag + marker peels" "api" "$(ar_tab_strip_prefix "${TAG}[1] api" 1)"
check "strip: mid-label bracket kept, knob on" "notes [2] draft" "$(ar_tab_strip_prefix 'notes [2] draft' 1)"
# The separator an empty host evaluation writes, peeled by its own layer while
# the knob is on and by the residue cut when it is off (a tagged row healing).
check "strip: bare separator peels, knob on" "api" "$(ar_tab_strip_prefix ': [1] api' 1)"
# A tag spelled under rules nobody can recompute still ends at the marker: the
# cut takes everything through the first "<sep>[N] ", and only such a head.
check "strip: unspellable tag heals through the marker" "api" "$(ar_tab_strip_prefix 'oldhost: [1] api' 1)"
unset HOST_PREFIX
check "strip: bare separator heals via the cut, knob off" "api" "$(ar_tab_strip_prefix ': [1] api' 1)"
CLEAR=1
check "strip: mid-label bracket kept under clear" "notes [2] draft" "$(ar_tab_strip_prefix 'notes [2] draft' 1)"
check "strip: non-digit bracket safe under clear" "[wip] foo" "$(ar_tab_strip_prefix '[wip] foo' 1)"
unset CLEAR

# The residue reader behind the separator-edit heal, and the head test behind
# the no-stack guard: both reduce ar_host_tag's spelling to the host name
# itself, so the checks hold on whatever machine runs the suite. The
# separators inside these strings are deliberately not the configured one.
yn() { if "$@"; then printf 'yes'; else printf 'no'; fi; }
H="$(uname -n 2>/dev/null)"; H="${H%%.*}"
HOST_PREFIX=1
check "residue: old separator plus marker reads as ours" "yes" "$(yn ar_tag_residue_p "${H} | [1] api" api)"
check "residue: old separator without a marker reads as ours" "yes" "$(yn ar_tag_residue_p "${H} | api" api)"
check "residue: a foreign host name does not" "no" "$(yn ar_tag_residue_p "oldhost: [1] api" api)"
check "residue: a tail that is not the recorded base does not" "no" "$(yn ar_tag_residue_p "${H} | [1] web" api)"
check "head: a hostname-headed base is detected" "yes" "$(yn ar_tag_head_p "${H}: [1] api" 1)"
check "head: a plain base is not" "no" "$(yn ar_tag_head_p "api" 1)"
check "head: without strip permission it never fires" "no" "$(yn ar_tag_head_p "${H}: [1] api")"
unset HOST_PREFIX

# ======================================================================
# Integration harness (see tests/test_reconcile.sh for the shape).
# ======================================================================
ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
chmod +x "$MOCK" 2>/dev/null || true

setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-tag.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures"; mkdir -p "$HERDR_MOCK_DIR"
  export HERDR_MOCK_LOG="$SB/renames.log"; : >"$HERDR_MOCK_LOG"; rm -f "$HERDR_MOCK_LOG.tabget"
  export HERDR_BIN_PATH="$MOCK"
  export XDG_STATE_HOME="$SB/state"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/none.sh"   # absent -> env toggles win
  export HERDR_CONFIG_FILE="$SB/herdr.toml"
  printf 'agent_panel_sort = "spaces"\n' >"$HERDR_CONFIG_FILE"
  export HERDR_SOCKET_PATH="$SB/herdr.sock"   # keeps herdr state reads (session.json) in the sandbox
  export SHELL_NAME=zsh
  export NAME_TABS=1 AUTO_INDEX=1 TAB_CONTEXT=0
  unset HOST_PREFIX HOST_PREFIX_SEP HOST_PREFIX_STRIP CLEAR   # per-scenario opt-in
  unset HIDE_SHELL
  unset AUTO_INDEX_WORKSPACES AUTO_INDEX_TABS AUTO_INDEX_AGENTS
  unset HERDR_TAB_ID HERDR_PANE_ID HERDR_PLUGIN_CONTEXT_JSON
  mkdir -p "$XDG_STATE_HOME/herdr-automatic-rename"
  export STATE="$XDG_STATE_HOME/herdr-automatic-rename/state.json"
}
fixture() { cat >"$HERDR_MOCK_DIR/$1"; }   # fixture <name>  (JSON on stdin)
run_engine() { /usr/bin/env bash "$ENGINE" "$@"; }
log() { cat "$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB" 2>/dev/null || true; }

# ======================================================================
# Review finding: the fast path froze a tagged tab when the knob went
# off. The tag was written while HOST_PREFIX=1 (the row says so, the
# design qu8n picked); the next preexec runs with it off. The carry
# guard tested the knob, so core kept the tag, slabel stopped matching
# the stored auto, and ar_name_eligible wrote the user-renamed opt-out:
# the tab wore the stale tag until reset. The tag must come off core
# either way, with only the carry for want= waiting on the knob, and
# the heal has to reach the store: the claim drops `tagged` again.
# ======================================================================
setup
printf '{"t1":{"auto":"nvim","enabled":true,"tagged":true}}\n' >"$STATE"
export HERDR_TAB_ID=t1 HERDR_PANE_ID=p1
fixture tab_t1.json <<JSON
{"result":{"tab":{"tab_id":"t1","label":"${TAG}[1] nvim"}}}
JSON
run_engine preexec "nvim README.md"
check "toggle off: tag comes off in the fast path" "tab rename t1 [1] nvim" "$(log)"
check "toggle off: tab not opted out" "true" "$(jq -r '.t1.enabled' "$STATE" 2>/dev/null)"
check "toggle off: heal drops the tagged mark" "false" "$(jq -r '.t1.tagged // false' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# Review finding: with the feature never on, a hand-typed host-looking
# name is not ours to take off. The user hand-renamed an owned tab to
# "<host>: fish"; ar_tab_strip_prefix peeled the tag with the knob off,
# the base matched the stored auto, and the reconcile renamed the tab to
# "fish". A tag nobody wrote must not be stripped: the label is the
# user's, and the mismatch with auto is the hand rename it records.
# AUTO_INDEX=0 keeps numbering out of the picture, so the assertion is
# exactly "no rename issued".
# ======================================================================
setup
export AUTO_INDEX=0
printf '{"w1:t1":{"auto":"fish","enabled":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[{"tab_id":"w1:t1","label":"${TAG}fish","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
run_engine tab.focused
check "hand host name kept, feature never on" "" "$(log)"
teardown

# ======================================================================
# Toggle on: the first tab gains the tag and the row records it, so a later
# pass with the knob off knows the tag is ours to take back off.
# ======================================================================
setup
export HOST_PREFIX=1
printf '{"w1:t1":{"auto":"nvim","enabled":true}}\n' >"$STATE"
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
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
run_engine tab.focused
check "toggle on: tag goes on the first tab" "tab rename w1:t1 ${TAG}[1] nvim" "$(log)"
check "toggle on: row records the tag" "true" "$(jq -r '.["w1:t1"].tagged // false' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# A pass that moves the tag without computing a name (no process-info to be
# had) must still reach the store: the label carries the tag either way, and
# the row is the only memory that it is ours.
# ======================================================================
setup
export HOST_PREFIX=1
printf '{"w1:t1":{"auto":"nvim","enabled":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[1] nvim","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
# NOTE: no procinfo_p1.json -> no name computed -> the tag rides base0 alone.
run_engine tab.focused
check "nameless pass: tag still goes on" "tab rename w1:t1 ${TAG}[1] nvim" "$(log)"
check "nameless pass: row still records the tag" "true" "$(jq -r '.["w1:t1"].tagged // false' "$STATE" 2>/dev/null)"
check "nameless pass: ownership kept" "nvim true" "$(jq -r '.["w1:t1"] | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# Renumber: the tag follows the first slot. Pass 1 is the steady state (both
# tabs correct, nothing issued). Pass 2 flips the order: the incoming first
# tab gains the tag and its mark, the outgoing one loses both.
# ======================================================================
setup
export HOST_PREFIX=1
printf '{"w1:t1":{"auto":"api","enabled":true,"tagged":true},"w1:t2":{"auto":"web","enabled":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false}
]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"${TAG}[1] api","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"[2] web","pane_count":1,"focused":false}
]}}
JSON
run_engine tab.focused
check "renumber: steady state issues nothing" "" "$(log)"
fixture tabs_w1.json <<JSON
{"result":{"tabs":[
  {"tab_id":"w1:t2","label":"[2] web","pane_count":1,"focused":true},
  {"tab_id":"w1:t1","label":"${TAG}[1] api","pane_count":1,"focused":false}
]}}
JSON
run_engine tab.focused
out=$(log)
check_contains "renumber: incoming first tab tagged" "$out" "tab rename w1:t2 ${TAG}[1] web"
check_contains "renumber: outgoing first tab untagged" "$out" "tab rename w1:t1 [2] api"
check "renumber: marks follow the slots" "false true" \
  "$(jq -r '[.["w1:t1"].tagged // false, .["w1:t2"].tagged // false] | "\(.[0]) \(.[1])"' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# A tag whose spelling changed (the host evaluated differently, strip rules
# edited) heals through the marker: the cut takes the unspellable head off a
# row we tagged, and the label lands on the current spelling.
# ======================================================================
setup
export HOST_PREFIX=1
printf '{"w1:t1":{"auto":"api","enabled":true,"tagged":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"oldhost: [1] api","pane_count":1,"focused":true}]}}
JSON
run_engine tab.focused
check "spelling change: heals to the current tag" "tab rename w1:t1 ${TAG}[1] api" "$(log)"
teardown

# ======================================================================
# The separator was edited mid-session, so the tag on the label is spelled
# the way the config no longer spells and no peel can take it off. A tab the
# plugin still names must heal to the new spelling: the row's receipt plus
# the exact recorded base says the head is ours. Without the residue reader
# the mismatch read as a hand rename, opted the tab out, and the reconcile
# stacked a fresh tag onto the old one, once per edit.
# ======================================================================
setup
export HOST_PREFIX=1 HOST_PREFIX_SEP=" | "
printf '{"w1:t1":{"auto":"fish","enabled":true,"tagged":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[{"tab_id":"w1:t1","label":"${TAG}[1] fish","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"fish","cmdline":"fish"}]}}}
JSON
run_engine tab.focused
check "separator edit: heals to the new spelling" "tab rename w1:t1 ${H} | [1] fish" "$(log)"
check "separator edit: ownership kept" "fish true" \
  "$(jq -r '.["w1:t1"] | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
check "separator edit: tag still recorded" "true" \
  "$(jq -r '.["w1:t1"].tagged // false' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# The same heal with the knob off: the row's `tagged` is what allows the
# strip, and the residue reader what recognizes the head, so the tag comes
# off whole instead of leaving the tab opted out on a label it can no
# longer derive.
# ======================================================================
setup
export HOST_PREFIX_SEP=" | "
printf '{"w1:t1":{"auto":"fish","enabled":true,"tagged":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[{"tab_id":"w1:t1","label":"${TAG}[1] fish","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"fish","cmdline":"fish"}]}}}
JSON
run_engine tab.focused
check "separator edit, knob off: tag comes off whole" "tab rename w1:t1 [1] fish" "$(log)"
check "separator edit, knob off: not opted out" "fish true" \
  "$(jq -r '.["w1:t1"] | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# A tab the plugin no longer names (opted out, the mark still on its row)
# must not grow a tag per separator edit. Its base still starts with the
# machine name, which is a tag in a spelling nobody can take off, so the
# pass leaves the label and the row exactly as they are; reset is the way
# out.
# ======================================================================
setup
export HOST_PREFIX=1 HOST_PREFIX_SEP=" | "
printf '{"w1:t1":{"auto":"","enabled":false,"tagged":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[{"tab_id":"w1:t1","label":"${TAG}[1] fish","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
run_engine tab.focused
check "stacked generations: nothing issued" "" "$(log)"
check "stacked generations: row untouched" "false true" \
  "$(jq -r '.["w1:t1"] | "\(.enabled) \(.tagged // false)"' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# The same heal with numbering off, the shape with no marker behind the tag:
# the reader needs no bracket, only the host-headed front and the exact
# recorded base at the back.
# ======================================================================
setup
export HOST_PREFIX=1 AUTO_INDEX=0 HOST_PREFIX_SEP=" | "
printf '{"w1:t1":{"auto":"fish","enabled":true,"tagged":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[{"tab_id":"w1:t1","label":"${TAG}fish","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
  "foreground_processes":[{"pid":100,"argv0":"fish","cmdline":"fish"}]}}}
JSON
run_engine tab.focused
check "separator edit, no marker: heals without the bracket" "tab rename w1:t1 ${H} | fish" "$(log)"
check "separator edit, no marker: ownership kept" "fish true" \
  "$(jq -r '.["w1:t1"] | "\(.auto) \(.enabled)"' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# Review finding: the fast path peeled the exact tag off the label before
# ar_tag_strip_ok was ever asked, so on a session that never set the knob a
# hand-typed "host: name" lost its head at the next preexec -- the strip
# below the peel was gated, the peel itself was not. The peel must carry the
# same permission the strip does.
# ======================================================================
setup
printf '{"t1":{"auto":"nvim","enabled":true}}\n' >"$STATE"
export HERDR_TAB_ID=t1 HERDR_PANE_ID=p1
fixture tab_t1.json <<JSON
{"result":{"tab":{"tab_id":"t1","label":"${TAG}nvim"}}}
JSON
run_engine preexec "nvim README.md"
check "fast path: hand host-looking name kept, feature never on" "" "$(log)"
check "fast path: recorded as the hand rename it is" "false" "$(jq -r '.t1.enabled' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# Review finding: the residue guard fired with the knob off, because
# ar_tag_head_p never asked the setting or the row. On a machine called Mac
# a hand-renamed "[2] Mac-notes" that moved to the first slot stayed
# "[2] Mac-notes", which breaks the default-off promise: without strip
# permission there is no tag interpretation at all, and the name is
# renumbered like any hand name.
# ======================================================================
setup
printf '{"w1:t1":{"auto":"","enabled":false}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[2] ${H}-notes","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
run_engine tab.focused
check "default off: a hand name starting with the machine name is renumbered" \
  "tab rename w1:t1 [1] ${H}-notes" "$(log)"
teardown

# ======================================================================
# The same hand name with the knob on: the strip permission exists, but the
# row was never tagged, so the head is the user's text and not residue. The
# tab follows its number like any hand name and never gains the tag, where
# the guard used to leave it frozen on the old slot.
# ======================================================================
setup
export HOST_PREFIX=1
printf '{"w1:t1":{"auto":"","enabled":false}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[{"tab_id":"w1:t1","label":"[2] ${H}-notes","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
run_engine tab.focused
check "hand host name, knob on: numbered, never tagged" "tab rename w1:t1 [1] ${H}-notes" "$(log)"
check "hand host name, knob on: row keeps the opt-out" "false" \
  "$(jq -r '.["w1:t1"].enabled' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# The guard's row half, pinned from the knob-off side: strip permission
# granted by a row we tagged (not by the knob) still means a host-headed
# base is residue nobody can spell, and the label and row are left alone.
# ======================================================================
setup
export HOST_PREFIX_SEP=" | "
printf '{"w1:t1":{"auto":"","enabled":false,"tagged":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[{"tab_id":"w1:t1","label":"${TAG}[1] fish","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
run_engine tab.focused
check "knob off, tagged residue: still left alone" "" "$(log)"
check "knob off, tagged residue: row untouched" "false true" \
  "$(jq -r '.["w1:t1"] | "\(.enabled) \(.tagged // false)"' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# Review finding: with the knob ON, ar_tag_strip_ok answered yes without
# reading the row's tagged, so a hand-typed "host: customer" on a tab the
# plugin never tagged lost its head -- the store is the one witness that can
# tell our residue from a hand name, and a hand rename cannot pre-record
# itself. A tag may now come off only a row the store says we tagged (or
# under clear); the knob only ever puts one on.
# ======================================================================
setup
export HOST_PREFIX=1
printf '{"w1:t1":{"auto":"api","enabled":true,"tagged":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"${TAG}[1] api","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"${TAG}customer","pane_count":1,"focused":false}
]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[
  {"pane_id":"p1","tab_id":"w1:t1","focused":true},
  {"pane_id":"p2","tab_id":"w1:t2","focused":false}
]}}
JSON
run_engine tab.focused
check "knob on: hand-typed host name on an untagged tab keeps its head" \
  "tab rename w1:t2 [2] ${TAG}customer" "$(log)"
# And the pass after the opt-out: the numbered hand name is already right, so
# nothing is issued again (idempotent, not just lucky once).
fixture tabs_w1.json <<JSON
{"result":{"tabs":[
  {"tab_id":"w1:t1","label":"${TAG}[1] api","pane_count":1,"focused":true},
  {"tab_id":"w1:t2","label":"[2] ${TAG}customer","pane_count":1,"focused":false}
]}}
JSON
: >"$HERDR_MOCK_LOG"
run_engine tab.focused
check "knob on: the kept hand name is steady on the next pass" "" "$(log)"
teardown

# ======================================================================
# The same finding through the fast path: the peel carried the same knob-only
# permission, so a hand-typed "host: nvim" on an owned untagged tab matched
# the stored auto once the head was off, and the preexec renamed the tab
# under the user's name.
# ======================================================================
setup
export HOST_PREFIX=1
printf '{"t1":{"auto":"nvim","enabled":true}}\n' >"$STATE"
export HERDR_TAB_ID=t1 HERDR_PANE_ID=p1
fixture tab_t1.json <<JSON
{"result":{"tab":{"tab_id":"t1","label":"${TAG}nvim"}}}
JSON
run_engine preexec "nvim README.md"
check "knob on, fast path: hand host-looking name kept" "" "$(log)"
check "knob on, fast path: recorded as the hand rename it is" "false" "$(jq -r '.t1.enabled' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# The price of the row-licensed strip, pinned rather than hidden: a session
# that lost its state file meets its own old tags as strangers. The label is
# numbered like any hand name, keeps the tag it carries, and never grows
# another; clear takes the whole thing off.
# ======================================================================
setup
export HOST_PREFIX=1
rm -f "$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"[1] api"}]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[{"tab_id":"w1:t1","label":"${TAG}[1] api","pane_count":1,"focused":true}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
run_engine tab.focused
check "state loss: numbered once, tag kept, nothing stacked" \
  "tab rename w1:t1 [1] ${TAG}[1] api" "$(log)"
teardown

# ======================================================================
# Residue nobody can derive (the separator config that named the tag is gone,
# and no marker sits behind it) is tolerated, not guessed at: the label keeps
# its text, the row drops the mark, and --clear or reset is the way out.
# ======================================================================
setup
export AUTO_INDEX=0
printf '{"w1:t1":{"auto":"api","enabled":true,"tagged":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture tabs_w1.json <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","label":"oldhost: api","pane_count":1,"focused":true}]}}
JSON
run_engine tab.focused
check "underivable residue: label kept" "" "$(log)"
check "underivable residue: mark dropped" "false" "$(jq -r '.["w1:t1"].tagged // false' "$STATE" 2>/dev/null)"
teardown

# ======================================================================
# Default-off inertness: a session that never set the knob issues nothing and
# leaves the store byte-identical across consecutive passes, which is what
# "inert without configuration" has to mean for a state-carrying feature.
# The first named pass records the workspace field (pre-existing behavior,
# nothing to do with HOST_PREFIX), so the byte-identical claim starts from
# the second pass.
# ======================================================================
setup
printf '{"w1:t1":{"auto":"nvim","enabled":true}}\n' >"$STATE"
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
{"result":{"process_info":{"foreground_process_group_id":200,
  "foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
run_engine tab.focused
: >"$HERDR_MOCK_LOG"
cp "$STATE" "$SB/state.before"
run_engine tab.focused
check "knob off: nothing issued" "" "$(log)"
check "knob off: state byte-identical" "same" \
  "$(cmp -s "$SB/state.before" "$STATE" && printf same || printf changed)"
teardown

# ======================================================================
# --clear is the residue-free way out for a tagged row with the knob off:
# the tag comes off along with the number, and the mark goes with it.
# ======================================================================
setup
export AUTO_INDEX=1
printf '{"w1:t1":{"auto":"api","enabled":true,"tagged":true}}\n' >"$STATE"
fixture workspaces.json <<'JSON'
{"result":{"workspaces":[{"workspace_id":"w1","label":"api"}]}}
JSON
fixture panes.json <<'JSON'
{"result":{"panes":[{"pane_id":"p1","tab_id":"w1:t1","focused":true}]}}
JSON
fixture tabs_w1.json <<JSON
{"result":{"tabs":[{"tab_id":"w1:t1","label":"${TAG}[1] api","pane_count":1,"focused":true}]}}
JSON
run_engine --clear
out=$(log)
check_contains "clear: tag and number come off" "$out" "tab rename w1:t1 api"
check "clear: mark dropped" "false" "$(jq -r '.["w1:t1"].tagged // false' "$STATE" 2>/dev/null)"
teardown

t_summary
