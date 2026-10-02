#!/usr/bin/env bash
# File-backed Git identity and token lifecycle without any live Herdr or git.
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-sidebar-unit.XXXXXX")
export XDG_STATE_HOME="$SB/state" XDG_CONFIG_HOME="$SB/config"
export HERDR_SOCKET_PATH="$SB/herdr.sock" HERDR_PLUGIN_ROOT="$here/.."
unset HERDR_SESSION
# shellcheck source=automatic-rename.sh
. "$here/../automatic-rename.sh"
# shellcheck source=naming.sh
. "$here/../naming.sh"
# shellcheck source=git.sh
. "$here/../git.sh"
# shellcheck source=fork-metadata.sh
. "$here/../fork-metadata.sh"
# shellcheck source=fork-sidebar.sh
. "$here/../fork-sidebar.sh"
mkdir -p "$STATE_DIR" "$SB/repo/.git/worktrees/checkout" "$SB/checkout" "$SB/rogue/.git"
printf 'ref: refs/heads/main\n' > "$SB/repo/.git/HEAD"
printf 'ref: refs/heads/worktree/issue/full-long-branch-name\n' > "$SB/repo/.git/worktrees/checkout/HEAD"
printf '../..\n' > "$SB/repo/.git/worktrees/checkout/commondir"
printf 'gitdir: %s\n' "$SB/repo/.git/worktrees/checkout" > "$SB/checkout/.git"
printf 'ref: refs/heads/wrong-project\n' > "$SB/rogue/.git/HEAD"
LOG="$SB/log"; : > "$LOG"
sidebar_mock() { printf '%s\n' "$*" >> "$LOG"; }
HERDR=sidebar_mock
ar_tab_metadata_ok() { return 0; }
ar_collapsed_spaces() { printf '[]'; }
ws=$(jq -nc --arg repo "$SB/repo" --arg co "$SB/checkout" '{workspaces:[
  {workspace_id:"w1",label:"repo",worktree:{repo_key:($repo+"/.git"),repo_root:$repo,repo_name:"repo",checkout_path:$repo,is_linked_worktree:false}},
  {workspace_id:"w2",label:"checkout",worktree:{repo_key:($repo+"/.git"),repo_root:$repo,repo_name:"repo",checkout_path:$co,is_linked_worktree:true}}]}')
AR_PANES_JSON=$(jq -nc --arg rogue "$SB/rogue" '{panes:[
  {pane_id:"p1",workspace_id:"w1",tab_id:"w1:t1",cwd:$rogue},
  {pane_id:"p2",workspace_id:"w2",tab_id:"w2:t1",cwd:$rogue},
  {pane_id:"p3",workspace_id:"w2",tab_id:"w2:t2",cwd:$rogue}]}')
SIDEBAR_CONTEXT=1 AUTO_INDEX=1 CLEAR=0
unset AUTO_INDEX_WORKSPACES
ar_sidebar_sync "$ws"
out=$(cat "$LOG")
check_contains "main label keeps numbered repository" "$out" '--token ar_workspace_label=[1] repo'
check_contains "main context includes trunk branch" "$out" '--token ar_checkout_context=main'
check_contains "linked label uses complete branch without convention" "$out" '--token ar_workspace_label=[2] issue/full-long-branch-name'
check_contains "linked context carries repository" "$out" '--token ar_checkout_context=repo'
check_contains "all panes of the linked checkout are reported" "$out" 'pane report-metadata p3'
check_absent "checkout metadata wins over unrelated pane cwd" "$out" wrong-project
check "sidebar reporting does not create ownership" no "$([ -e "$STATE_FILE" ] && printf yes || printf no)"

: > "$LOG"
ws_cached=$(printf '%s' "$ws" | jq '.workspaces[1].tokens={ar_workspace_label:"[2] issue/full-long-branch-name",ar_checkout_context:"repo"}')
panes_saved=$AR_PANES_JSON
AR_PANES_JSON=$(printf '%s' "$AR_PANES_JSON" | jq '.panes |= map(if .workspace_id == "w2" then .tokens={ar_workspace_label:"[2] issue/full-long-branch-name",ar_checkout_context:"repo"} else . end)')
ar_sidebar_sync "$ws_cached" w2
check "identical workspace and pane tokens are no-op" '' "$(cat "$LOG")"
AR_PANES_JSON=$panes_saved

ar_state_set ws:w2 '' false
before=$(cat "$STATE_FILE")
: > "$LOG"
ar_sidebar_sync "$ws" w2
out=$(cat "$LOG")
check_contains "explicit opt-out keeps original linked label" "$out" '--token ar_workspace_label=[2] checkout'
check_contains "manual linked context includes both repo and raw branch" "$out" '--token ar_checkout_context=repo:worktree/issue/full-long-branch-name'
check "sidebar reporting never changes opt-out state" "$before" "$(cat "$STATE_FILE")"
ar_state_del ws:w2
ws_manual=$(printf '%s' "$ws" | jq '.workspaces[1].label="my notes"')
: > "$LOG"
ar_sidebar_sync "$ws_manual" w2
check_contains "unowned custom label remains visible" "$(cat "$LOG")" '--token ar_workspace_label=[2] my notes'

printf 'ref: refs/heads/deadbee\n' > "$SB/repo/.git/worktrees/checkout/HEAD"
: > "$LOG"
ar_sidebar_sync "$ws" w2
check_contains "hash-like named branch is not detached" "$(cat "$LOG")" '--token ar_workspace_label=[2] deadbee'
printf '0123456789012345678901234567890123456789\n' > "$SB/repo/.git/worktrees/checkout/HEAD"
: > "$LOG"
ar_sidebar_sync "$ws" w2
check_contains "detached linked checkout is explicit" "$(cat "$LOG")" '--token ar_workspace_label=[2] detached@0123456'
mkdir -p "$SB/repo/.git/worktrees/checkout/rebase-merge"
printf 'refs/heads/rebase/full-name\n' > "$SB/repo/.git/worktrees/checkout/rebase-merge/head-name"
: > "$LOG"
ar_sidebar_sync "$ws" w2
check_contains "rebase preserves complete branch identity" "$(cat "$LOG")" '--token ar_workspace_label=[2] rebase/full-name'
rm -rf "$SB/repo/.git/worktrees/checkout/rebase-merge"
rm "$SB/repo/.git/worktrees/checkout/HEAD"
: > "$LOG"
ar_sidebar_sync "$ws" w2
check_contains "unreadable linked HEAD uses explicit checkout fallback" "$(cat "$LOG")" "--token ar_workspace_label=[2] worktree:$SB/checkout"

printf 'ref: refs/heads/fresh-branch\n' > "$SB/repo/.git/worktrees/checkout/HEAD"
AR_SIDEBAR_LABELS="w2${AR_ROW_SEP}new manual name"
: > "$LOG"
ar_sidebar_sync "$ws" w2
check_contains "settled label map avoids stale original name" "$(cat "$LOG")" '--token ar_workspace_label=[2] new manual name'
unset AR_SIDEBAR_LABELS
AUTO_INDEX_WORKSPACES=0
: > "$LOG"
ar_sidebar_sync "$ws" w2
check_contains "scope override disables identity numbering" "$(cat "$LOG")" '--token ar_workspace_label=fresh-branch'
check_absent "scope override removes numbered display" "$(cat "$LOG")" '--token ar_workspace_label=[2]'
unset AUTO_INDEX_WORKSPACES
ar_collapsed_spaces() { printf '["%s/.git"]' "$SB/repo"; }
: > "$LOG"
ar_sidebar_sync "$ws" w2
check_contains "collapsed hidden checkout carries no jump number" "$(cat "$LOG")" '--token ar_workspace_label=fresh-branch'
check_absent "collapsed hidden checkout omits stale number" "$(cat "$LOG")" '--token ar_workspace_label=[2]'

# With no checkout metadata or persisted identity, two unfocused split panes in
# the active tab cannot choose a workspace-wide branch on the user's behalf.
fallback_ws='{"workspaces":[{"workspace_id":"w3","label":"repo","active_tab_id":"w3:t1"}]}'
AR_PANES_JSON=$(jq -nc --arg repo "$SB/repo" --arg rogue "$SB/rogue" '{panes:[
  {pane_id:"p4",workspace_id:"w3",tab_id:"w3:t1",cwd:$repo,focused:false},
  {pane_id:"p5",workspace_id:"w3",tab_id:"w3:t1",cwd:$rogue,focused:false}]}')
: > "$LOG"
ar_sidebar_sync "$fallback_ws" w3
out=$(cat "$LOG")
check_absent "ambiguous active split cannot choose first pane branch" "$out" '--token ar_checkout_context=main'
check_absent "ambiguous active split cannot choose other pane branch" "$out" wrong-project
check_absent "ambiguous active split has no invented context" "$out" '--token ar_checkout_context='

# Persisted workspace identity remains authoritative even when its panes differ.
jq -n --arg cwd "$SB/repo" '{workspaces:[{id:"w3",identity_cwd:$cwd}]}' > "$SB/session.json"
: > "$LOG"
ar_sidebar_sync "$fallback_ws" w3
check_contains "persisted identity takes precedence over ambiguous split" "$(cat "$LOG")" '--token ar_checkout_context=main'
rm "$SB/session.json"

# Without persistence, a genuinely focused pane supplies an unambiguous fallback.
AR_PANES_JSON=$(printf '%s' "$AR_PANES_JSON" | jq '.panes[1].focused=true')
: > "$LOG"
ar_sidebar_sync "$fallback_ws" w3
check_contains "focused pane fallback keeps its authoritative branch" "$(cat "$LOG")" '--token ar_checkout_context=wrong-project'
AR_PANES_JSON=$panes_saved

SIDEBAR_CONTEXT=0
ar_git_head() { printf called >> "$SB/git-called"; return 1; }
: > "$LOG"
ar_sidebar_sync "$ws"
check "default off without tokens issues no commands" '' "$(cat "$LOG")"
check "default off does not read branches" no "$([ -e "$SB/git-called" ] && printf yes || printf no)"
ws_clear=$(printf '%s' "$ws" | jq '.workspaces[0].tokens={ar_workspace_label:"old",ar_checkout_context:"main",unrelated:"keep"}')
AR_PANES_JSON=$(printf '%s' "$panes_saved" | jq '.panes[0].tokens={ar_workspace_label:"old",ar_checkout_context:"main",tab_number:"1",unrelated:"keep"}')
ar_sidebar_sync "$ws_clear"
out=$(cat "$LOG")
check_contains "off clears workspace identity keys" "$out" 'workspace report-metadata w1 --source herdr-automatic-rename --clear-token ar_workspace_label --clear-token ar_checkout_context'
check_contains "off clears pane identity keys" "$out" 'pane report-metadata p1 --source herdr-automatic-rename --clear-token ar_workspace_label --clear-token ar_checkout_context'
check_absent "off leaves tab-number token alone" "$out" tab_number
check_absent "off leaves unrelated token alone" "$out" unrelated
check "off with old tokens still avoids branch reads" no "$([ -e "$SB/git-called" ] && printf yes || printf no)"

: > "$LOG"
SIDEBAR_CONTEXT=1
ar_sidebar_sync '{"workspaces":[{"workspace_id":"bad id","label":"x"}]}'
check "invalid workspace IDs never reach CLI" '' "$(cat "$LOG")"
check_rc "invalid checkout field shape is refused" 1 \
  "$(if ar_sidebar_inventory workspace '{"workspaces":[{"workspace_id":"w1","label":"x","worktree":{"checkout_path":42}}]}' >/dev/null; then printf 0; else printf 1; fi)"

# Validate raw worktree strings before creating newline/unit-separator rows.
# Invalid data must not patch metadata or even read a checkout's Git files.
before=$(cat "$STATE_FILE")
for field in checkout_path repo_name repo_root; do
  for control in $'\n' $'\t' $'\037'; do
    invalid=$(printf '%s' "$ws" | jq --arg f "$field" --arg bad "/bad${control}path" \
      '.workspaces[1].worktree[$f]=$bad')
    check_rc "$field rejects control byte before transport" 1 \
      "$(if ar_sidebar_inventory workspace "$invalid" >/dev/null; then printf 0; else printf 1; fi)"
    : > "$LOG"
    ar_sidebar_sync "$invalid"
    check "$field invalid data makes no metadata changes" '' "$(cat "$LOG")"
    check "$field invalid data preserves naming ownership" "$before" "$(cat "$STATE_FILE")"
  done
done
check "invalid worktree data never reaches Git reads" no \
  "$([ -e "$SB/git-called" ] && printf yes || printf no)"

rm -rf "$SB"
t_summary
