#!/usr/bin/env bash
# Exercise the public event and prompt entry points with isolated inventories.
set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
ENGINE="$here/../automatic-rename.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-sidebar-integration.XXXXXX")
trap 'rm -rf "$SB"' EXIT
export XDG_STATE_HOME="$SB/state" XDG_CONFIG_HOME="$SB/config"
export HERDR_SOCKET_PATH="$SB/herdr.sock" HERDR_AUTOMATIC_RENAME_CONFIG="$SB/config.sh"
export HERDR_MOCK_DIR="$SB/fixtures" HERDR_MOCK_LOG="$SB/log"
export AR_FORK_TEST_MOCK="$here/mocks/herdr"
unset HERDR_SESSION HERDR_PLUGIN_ROOT HERDR_PLUGIN_CONTEXT_JSON
export HERDR_WORKSPACE_ID=w2 HERDR_TAB_ID=w2:t1 HERDR_PANE_ID=p2
mkdir -p "$HERDR_MOCK_DIR" "$SB/repo/.git/worktrees/linked" "$SB/linked"
printf 'ref: refs/heads/dev\n' > "$SB/repo/.git/HEAD"
printf 'ref: refs/heads/feature/one\n' > "$SB/repo/.git/worktrees/linked/HEAD"
printf '../..\n' > "$SB/repo/.git/worktrees/linked/commondir"
printf 'gitdir: %s\n' "$SB/repo/.git/worktrees/linked" > "$SB/linked/.git"
cat > "$SB/herdr" <<'MOCK'
#!/usr/bin/env bash
if { [ "$1" = pane ] || [ "$1" = workspace ]; } && [ "$2" = report-metadata ]; then
  printf '%s\n' "$*" >> "$HERDR_MOCK_LOG"
  [ "${SIDEBAR_TEST_FAIL:-0}" != 1 ]
  exit $?
fi
exec "$AR_FORK_TEST_MOCK" "$@"
MOCK
chmod +x "$SB/herdr"
export HERDR_BIN_PATH="$SB/herdr" HERDR_MOCK_VERSION=0.9.3
cat > "$HERDR_AUTOMATIC_RENAME_CONFIG" <<'CONFIG'
NAME_TABS=0
AUTO_INDEX=0
SIDEBAR_CONTEXT=1
CONFIG
jq -n --arg repo "$SB/repo" --arg linked "$SB/linked" '{result:{snapshot:{
  workspaces:[
    {workspace_id:"w1",label:"repo",worktree:{repo_key:($repo+"/.git"),repo_root:$repo,repo_name:"repo",checkout_path:$repo,is_linked_worktree:false}},
    {workspace_id:"w2",label:"linked",worktree:{repo_key:($repo+"/.git"),repo_root:$repo,repo_name:"repo",checkout_path:$linked,is_linked_worktree:true}}],
  tabs:[],agents:[],panes:[
    {pane_id:"p1",tab_id:"w1:t1",workspace_id:"w1",tokens:{unrelated:"keep"}},
    {pane_id:"p2",tab_id:"w2:t1",workspace_id:"w2",tokens:{tab_number:"1",unrelated:"keep"}}]}}}' > "$HERDR_MOCK_DIR/snapshot.json"
run() { : > "$HERDR_MOCK_LOG"; bash "$ENGINE" "$1"; }
run tab.moved
out=$(cat "$HERDR_MOCK_LOG")
check_contains "event populates main workspace context" "$out" 'workspace report-metadata w1 --source herdr-automatic-rename --token ar_workspace_label=repo --token ar_checkout_context=dev'
check_contains "event populates linked pane identity" "$out" 'pane report-metadata p2 --source herdr-automatic-rename --token ar_workspace_label=feature/one --token ar_checkout_context=repo'
check_absent "sidebar alone does not rename workspaces" "$out" 'workspace rename'
check_absent "unrelated metadata survives integration" "$out" '--clear-token unrelated'

printf 'ref: refs/heads/feature/two\n' > "$SB/repo/.git/worktrees/linked/HEAD"
run precmd
out=$(cat "$HERDR_MOCK_LOG")
check_contains "prompt sees changed branch with naming and indexing off" "$out" '--token ar_workspace_label=feature/two'
check_absent "prompt does not touch another workspace" "$out" 'report-metadata w1'
check_absent "prompt does not touch another workspace pane" "$out" 'report-metadata p1'
check_absent "prompt does not touch tab numbering" "$out" tab_number
unset HERDR_WORKSPACE_ID
run precmd
check_contains "prompt derives workspace from tab ID" "$(cat "$HERDR_MOCK_LOG")" 'workspace report-metadata w2'

jq '.result.snapshot | {result:{workspaces:.workspaces}}' "$HERDR_MOCK_DIR/snapshot.json" > "$HERDR_MOCK_DIR/workspaces.json"
jq '.result.snapshot | {result:{panes:.panes}}' "$HERDR_MOCK_DIR/snapshot.json" > "$HERDR_MOCK_DIR/panes.json"
cp "$HERDR_MOCK_DIR/snapshot.json" "$SB/snapshot.json"
printf '{bad\n' > "$HERDR_MOCK_DIR/snapshot.json"
run precmd
check_contains "prompt uses list fallback for malformed snapshot" "$(cat "$HERDR_MOCK_LOG")" '--token ar_workspace_label=feature/two'
run tab.moved
check_contains "event uses list fallback" "$(cat "$HERDR_MOCK_LOG")" '--token ar_checkout_context=dev'

export SIDEBAR_TEST_FAIL=1
run precmd
check_rc "metadata failure does not fail prompt" 0 $?
unset SIDEBAR_TEST_FAIL
run precmd
check_contains "next prompt retries failed metadata" "$(cat "$HERDR_MOCK_LOG")" '--token ar_workspace_label=feature/two'

jq '.result.snapshot.workspaces[1].tokens={ar_workspace_label:"feature/two",ar_checkout_context:"repo"}
 | .result.snapshot.panes[1].tokens += {ar_workspace_label:"feature/two",ar_checkout_context:"repo"}' "$SB/snapshot.json" > "$HERDR_MOCK_DIR/snapshot.json"
run precmd
check "unchanged prompt writes nothing" '' "$(cat "$HERDR_MOCK_LOG")"
run clear
out=$(cat "$HERDR_MOCK_LOG")
check_contains "clear removes workspace sidebar tokens" "$out" 'workspace report-metadata w2 --source herdr-automatic-rename --clear-token ar_workspace_label --clear-token ar_checkout_context'
check_contains "clear removes pane sidebar tokens" "$out" 'pane report-metadata p2 --source herdr-automatic-rename --clear-token ar_workspace_label --clear-token ar_checkout_context'
check_absent "clear retains unrelated metadata" "$out" '--clear-token unrelated'
printf '\nSIDEBAR_CONTEXT=0\n' >> "$HERDR_AUTOMATIC_RENAME_CONFIG"
run tab.moved
check_contains "disable removes stale identity on event" "$(cat "$HERDR_MOCK_LOG")" '--clear-token ar_workspace_label'
export HERDR_MOCK_VERSION=0.7.9
run tab.moved
check_absent "older Herdr is not sent unsupported tokens" "$(cat "$HERDR_MOCK_LOG")" report-metadata

t_summary
