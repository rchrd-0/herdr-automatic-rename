#!/usr/bin/env bash
# Fork reliability regressions, with isolated files and fake CLI calls only.
set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
ENGINE="$here/../automatic-rename.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-fork-safety.XXXXXX")
trap 'rm -rf "$SB"' EXIT
export XDG_STATE_HOME="$SB/state" XDG_CONFIG_HOME="$SB/config"
unset HERDR_SOCKET_PATH HERDR_SESSION HERDR_CLIENT_SOCKET_PATH HERDR_PLUGIN_ROOT HERDR_TAB_ID HERDR_PANE_ID
# shellcheck source=automatic-rename.sh
. "$ENGINE"
# shellcheck source=fork-metadata.sh
. "$here/../fork-metadata.sh"
mkdir -p "$STATE_DIR"
CLEAR=0 NAME_TABS=0 AUTO_INDEX=0
unset AUTO_INDEX_TABS AUTO_INDEX_WORKSPACES AUTO_INDEX_AGENTS
seed_state() {
  printf '{"w1:t1":{"auto":"zsh","enabled":true},"w2:t1":{"auto":"nvim","enabled":true},"closed":{"auto":"old","enabled":true}}' > "$STATE_FILE"
  AR_STATE_ROWS_LOADED=''
  before=$(jq -cS . "$STATE_FILE")
}

# Invalid list envelopes/IDs cannot establish that an unobserved tab closed.
fake_lists() {
  case "$*" in
    'tab list --workspace w1') printf '{"tabs":[{"tab_id":"w1:t1","label":"zsh","pane_count":0}]}' ;;
    'tab list --workspace w2') printf '%s' "$bad_tabs" ;;
    'tab rename '*) printf '%s\n' "$*" >> "$SB/renames" ;;
  esac
}
HERDR=fake_lists
for bad_tabs in '{}' '{"tabs":null}' '{"tabs":{}}' \
  '{"tabs":[{}]}' '{"tabs":[{"tab_id":""}]}' \
  '{"tabs":[{"tab_id":42}]}' '{"tabs":[{"tab_id":"bad id"}]}' \
  '{"tabs":[{"tab_id":"bad\nid"}]}' '{"tabs":[]} {"tabs":[]}'; do
  seed_state
  AR_SEEN_TABS='' AR_TABS_PARTIAL='' AR_HAVE_SNAPSHOT=0
  ar_reconcile_tabs '{"workspaces":[{"workspace_id":"w1"},{"workspace_id":"w2"}]}'
  # shellcheck disable=SC2086  # one argument per validated tab id
  [ -n "$AR_SEEN_TABS" ] && [ -z "$AR_TABS_PARTIAL" ] && ar_state_prune $AR_SEEN_TABS
  check "invalid tabs preserve unseen records: $bad_tabs" "$before" "$(jq -cS . "$STATE_FILE")"
  check "invalid tabs mark pass partial: $bad_tabs" "1" "$AR_TABS_PARTIAL"
done
for bad_ws in '{}' '{"workspaces":null}' '{"workspaces":{}}' \
  '{"workspaces":[{}]}' '{"workspaces":[{"workspace_id":""}]}' \
  '{"workspaces":[{"workspace_id":42}]}' '{"workspaces":[{"workspace_id":"bad id"}]}' \
  '{"workspaces":[]} {"workspaces":[]}'; do
  seed_state
  AR_SEEN_TABS='' AR_TABS_PARTIAL='' AR_HAVE_SNAPSHOT=0
  ar_reconcile_tabs "$bad_ws"
  check "invalid workspaces preserve records: $bad_ws" "$before" "$(jq -cS . "$STATE_FILE")"
  check "invalid workspaces mark pass partial: $bad_ws" "1" "$AR_TABS_PARTIAL"
done
for bad_snapshot in '{}' '{"result":{"tabs":null}}' '{"result":{"tabs":{}}}' \
  '{"result":{"tabs":[{"tab_id":"w2:t1"}]}}' \
  '{"result":{"tabs":[{"tab_id":"w2:t1","workspace_id":"bad id"}]}}'; do
  seed_state
  AR_SEEN_TABS='' AR_TABS_PARTIAL='' AR_HAVE_SNAPSHOT=1
  AR_SNAP_TABS_JSON=$bad_snapshot
  ar_reconcile_tabs '{"workspaces":[{"workspace_id":"w1"},{"workspace_id":"w2"}]}'
  check "incomplete snapshot preserves records: $bad_snapshot" "$before" "$(jq -cS . "$STATE_FILE")"
  check "incomplete snapshot marks pass partial: $bad_snapshot" "1" "$AR_TABS_PARTIAL"
done
# A subsequent complete read still prunes a genuinely closed tab.
seed_state
bad_tabs='{"tabs":[{"tab_id":"w2:t1","label":"nvim","pane_count":0}]}'
AR_SEEN_TABS='' AR_TABS_PARTIAL='' AR_HAVE_SNAPSHOT=0
ar_reconcile_tabs '{"workspaces":[{"workspace_id":"w1"},{"workspace_id":"w2"}]}'
# shellcheck disable=SC2086  # one argument per validated tab id
ar_state_prune $AR_SEEN_TABS
check "complete read still prunes closed tab" "false" "$(jq 'has("closed")' "$STATE_FILE")"

# jq's invocation/filter failures are different from bad JSON (4/5).
for jq_rc in 2 3 137; do
  seed_state
  jq() { return "$jq_rc"; }
  ar_state_set fresh vim true
  check_rc "jq $jq_rc refuses state write" 1 $?
  ar_state_load
  check "jq $jq_rc leaves ownership unknown" "1" "$AR_STATE_ROWS_BAD"
  unset -f jq
  check "jq $jq_rc preserves state bytes" "$before" "$(jq -cS . "$STATE_FILE")"
done
rm "$STATE_FILE"
mkdir "$STATE_FILE"
ar_state_set fresh vim true
check_rc "directory at state.json refuses writes" 1 $?
check "directory at state.json gets no nested state file" "0" \
  "$(find "$STATE_FILE" -type f | wc -l | tr -d ' ')"
rmdir "$STATE_FILE"

# Failed migration confirmation/deletion must deny naming and keep provenance.
seeded_state() {
  printf '{"w1:t1":{"auto":"nvim","enabled":true,"ws":"api","tagged":true,"seeded":true}}' > "$STATE_FILE"
  AR_STATE_ROWS_LOADED=''
}
seeded_state
saved_set=$(declare -f ar_state_set)
ar_state_set() { return 1; }
ar_name_eligible w1:t1 nvim
check_rc "failed seeded confirmation denies naming" 1 $?
check "failed confirmation retains marker" "true" "$(jq -r '."w1:t1".seeded' "$STATE_FILE")"
eval "$saved_set"
seeded_state
saved_del=$(declare -f ar_state_del)
ar_state_del() { return 1; }
ar_name_eligible w1:t1 1
check_rc "failed seeded deletion denies naming" 1 $?
check "failed deletion retains original claim" "nvim" "$(jq -r '."w1:t1".auto' "$STATE_FILE")"
eval "$saved_del"

# Transaction rollback restores the entire state, including extended fields.
seeded_state
ar_state_set sibling zsh true
before=$(jq -cS . "$STATE_FILE")
: > "$SB/renames"
reject_rename() {
  printf '%s\n' "$*" >> "$SB/renames"
  printf 'seen-auto=%s\n' "$(jq -r '."w1:t1".auto' "$STATE_FILE")" >> "$SB/renames"
  return 1
}
HERDR=reject_rename
AR_STATE_KEY='' AR_FORCE_TAB=w1:t1 AR_FORCE_ADOPTED=''
ar_rename_owned_tab w1:t1 htop nvim htop changed 0
check_rc "rejected rename returns failure" 1 $?
check "rollback preserves ws tagged seeded and other records" "$before" "$(jq -cS . "$STATE_FILE")"
check "rollback removes false reset success" "" "$AR_FORCE_ADOPTED"
check_contains "rename sees successfully published ownership" "$(cat "$SB/renames")" "seen-auto=htop"
check_contains "rename was attempted after publication" "$(cat "$SB/renames")" "tab rename w1:t1 htop"
: > "$SB/renames"
ar_state_set() { return 1; }
ar_rename_owned_tab w1:t1 htop nvim htop changed 0
check_rc "failed ownership write refuses rename" 1 $?
check "failed ownership write calls no rename" "" "$(cat "$SB/renames")"
check "failed ownership write leaves store intact" "$before" "$(jq -cS . "$STATE_FILE")"
eval "$saved_set"
unset AR_FORCE_TAB

# Migration is checked under the lock, and skipped for numbering-only/clear.
# Stubs record ordering without exercising lock timing or sleeping.
run_order() (
  NAME_TABS=$1 CLEAR=$2
  ar_lock() { held=1; printf 'lock\n'; }
  ar_unlock() { held=0; }
  ar_state_seed() { printf 'seed-held=%s\n' "$held"; return 0; }
  ar_reconcile() { printf 'pass\n'; }
  ar_fast_once() { printf 'pass\n'; }
  held=0
  ar_run full
)
check "migration runs only after acquiring lock" $'lock\nseed-held=1\npass' "$(run_order 1 0)"
check "naming off skips migration" $'lock\npass' "$(run_order 0 0)"
check "clear skips migration" $'lock\npass' "$(run_order 1 1)"
failed_seed_order=$(
  NAME_TABS=1 CLEAR=0
  ar_lock() { printf 'lock\n'; }
  ar_unlock() { :; }
  ar_state_seed() { printf 'seed-failed\n'; return 1; }
  ar_reconcile() { printf 'unexpected-pass\n'; }
  ar_run full
  printf 'status=%s\n' "$?"
)
check "failed migration stops the pass" $'lock\nseed-failed\nstatus=1' "$failed_seed_order"
# A raw snapshot missing either required list must use the per-list fallback.
fake_snapshot() {
  case "$*" in
    'api snapshot') printf '%s' "$raw_snapshot" ;;
    'workspace list') printf '{"workspaces":[]}' ;;
  esac
}
for raw_snapshot in '{"snapshot":{"workspaces":[]}}' '{"snapshot":{"tabs":[]}}'; do
  picked=$(
    HERDR=fake_snapshot NAME_TABS=0 AUTO_INDEX=0
    ar_ws_pass() { return 1; }
    ar_reconcile
    printf '%s' "$AR_HAVE_SNAPSHOT"
  )
  check "missing raw snapshot array selects fallback: $raw_snapshot" "0" "$picked"
done

# Fixed byte hashes independently computed with Python pin path derivation.
check "root API socket retains root slash in client endpoint" \
  "$XDG_STATE_HOME/herdr/client-shell/local-5644b7309698c595.json" \
  "$(HERDR_SOCKET_PATH=/herdr.sock ar_herdr_client_prefs)"
check "client override applies without an API socket" \
  "$XDG_STATE_HOME/herdr/client-shell/local-79f171d148cbdf3f.json" \
  "$(HERDR_SOCKET_PATH='' HERDR_CLIENT_SOCKET_PATH=/tmp/legacy.sock ar_herdr_client_prefs)"
check "API override wins over client override" \
  "$XDG_STATE_HOME/herdr/client-shell/local-703527de6d516edd.json" \
  "$(HERDR_SOCKET_PATH=/tmp/hs/herdr.sock HERDR_CLIENT_SOCKET_PATH=/tmp/legacy.sock ar_herdr_client_prefs)"
HERDR_SOCKET_PATH="$SB/session/herdr.sock"
mkdir -p "$SB/session"
prefs=$(ar_herdr_client_prefs)
mkdir -p "${prefs%/*}"
printf '{"collapsed_groups":["client"]}\n{"collapsed_groups":[]}' > "$prefs"
printf '{"collapsed_space_keys":["legacy"]}' > "$SB/session/session.json"
check "multiple preference documents fall back to session collapse" '["legacy"]' "$(ar_collapsed_spaces)"
printf '{"collapsed_space_keys":["legacy"]}\n{}' > "$SB/session/session.json"
check "multiple session documents yield safe empty collapse" '[]' "$(ar_collapsed_spaces)"

# A preloaded empty named-session store must not outlive successful seeding.
seed_cache=$(
  STATE_DIR="$SB/cache-session"
  STATE_FILE="$STATE_DIR/state.json"
  AR_LEGACY_STATE_FILE="$SB/cache-legacy.json"
  mkdir -p "$STATE_DIR"
  printf '{"t1":{"auto":"nvim","enabled":true}}' > "$AR_LEGACY_STATE_FILE"
  AR_STATE_ROWS_LOADED=''
  ar_state_rows
  ar_state_seed
  ar_name_eligible t1 nvim
  printf 'eligible=%s enabled=%s' "$?" "$(ar_state_get t1 enabled)"
)
check "migration invalidates an already-loaded empty store" 'eligible=0 enabled=true' "$seed_cache"

t_summary
