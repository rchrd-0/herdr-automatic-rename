#!/usr/bin/env bash
# Fork metadata integration against fixtures only, including per-kind toggles.
set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
ENGINE="$here/../automatic-rename.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-fork-metadata.XXXXXX")
trap 'rm -rf "$SB"' EXIT
export XDG_STATE_HOME="$SB/state" XDG_CONFIG_HOME="$SB/config"
export HERDR_SOCKET_PATH="$SB/herdr.sock"
export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/config.sh"
export HERDR_MOCK_DIR="$SB/fixtures" HERDR_MOCK_LOG="$SB/log"
export AR_FORK_TEST_MOCK="$here/mocks/herdr"
unset HERDR_SESSION HERDR_TAB_ID HERDR_PANE_ID HERDR_PLUGIN_ROOT HERDR_PLUGIN_CONTEXT_JSON
mkdir -p "$HERDR_MOCK_DIR"
# Keep the shared upstream mock unchanged; add only metadata support here.
cat > "$SB/herdr" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" = pane ] && [ "$2" = report-metadata ]; then
  printf '%s' "$1" >> "$HERDR_MOCK_LOG"
  shift
  for arg in "$@"; do printf ' %s' "$arg" >> "$HERDR_MOCK_LOG"; done
  printf '\n' >> "$HERDR_MOCK_LOG"
  exit 0
fi
exec "$AR_FORK_TEST_MOCK" "$@"
MOCK
chmod +x "$SB/herdr"
export HERDR_BIN_PATH="$SB/herdr"
# shellcheck source=automatic-rename.sh
. "$ENGINE"
# shellcheck source=fork-metadata.sh
. "$here/../fork-metadata.sh"
export HERDR_MOCK_VERSION=0.7.9
ar_tab_metadata_ok; check_rc "old Herdr skips custom metadata" 1 $?
export HERDR_MOCK_VERSION=0.8.0
ar_tab_metadata_ok; check_rc "Herdr 0.8 supports custom metadata" 0 $?
export HERDR_MOCK_VERSION=1.0.0
ar_tab_metadata_ok; check_rc "later Herdr supports custom metadata" 0 $?
export HERDR_MOCK_NO_VERSION=1
ar_tab_metadata_ok; check_rc "unknown version skips custom metadata" 1 $?
unset HERDR_MOCK_NO_VERSION

# Ten tabs, two panes in the first tab, an already-correct third pane, and
# a stale ninth-position token in the unreachable tenth tab.
jq -n '{result:{snapshot:{
  workspaces:[{workspace_id:"w1",label:"api"}],
  tabs:[range(1;11) | {tab_id:("t" + tostring),workspace_id:"w1",label:"notes",pane_count:0}],
  panes:[{pane_id:"p1",tab_id:"t1",tokens:{other:"keep"}},
         {pane_id:"p2",tab_id:"t1",tokens:{}},
         {pane_id:"p3",tab_id:"t2",tokens:{tab_number:"2",other:"keep"}},
         {pane_id:"p10",tab_id:"t10",tokens:{tab_number:"9"}},
         {pane_id:"foreign",tab_id:"missing",tokens:{other:"keep"}}],
  agents:[]}}}' > "$HERDR_MOCK_DIR/snapshot.json"
export NAME_TABS=0 AUTO_INDEX=1 AUTO_INDEX_WORKSPACES=0 AUTO_INDEX_AGENTS=0
export HERDR_MOCK_VERSION=0.8.0
run() { : > "$HERDR_MOCK_LOG"; bash "$ENGINE" "$1"; }
run tab.moved
out=$(cat "$HERDR_MOCK_LOG")
check_contains "all panes: first pane gets plain position" "$out" \
  "pane report-metadata p1 --source herdr-automatic-rename --token tab_number=1"
check_contains "all panes: second pane gets same position" "$out" \
  "pane report-metadata p2 --source herdr-automatic-rename --token tab_number=1"
check_absent "correct token is not rewritten" "$out" "pane report-metadata p3"
check_contains "position ten clears stale token" "$out" \
  "pane report-metadata p10 --source herdr-automatic-rename --clear-token tab_number"
check_absent "unrelated token is untouched" "$out" "--clear-token other"
check_absent "pane with only unrelated metadata is untouched" "$out" "pane report-metadata foreign"

export AUTO_INDEX_TABS=0
run tab.moved
out=$(cat "$HERDR_MOCK_LOG")
check_contains "tabs off clears existing token" "$out" \
  "pane report-metadata p3 --source herdr-automatic-rename --clear-token tab_number"
check_absent "tabs off reports no new token" "$out" "--token tab_number="
check_absent "tabs off preserves unrelated tokens" "$out" "--clear-token other"

export AUTO_INDEX=0 AUTO_INDEX_TABS=1
run tab.moved
check_contains "tabs override enables metadata with global off" "$(cat "$HERDR_MOCK_LOG")" \
  "pane report-metadata p1 --source herdr-automatic-rename --token tab_number=1"
run clear
out=$(cat "$HERDR_MOCK_LOG")
check_contains "clear removes tab token" "$out" \
  "pane report-metadata p3 --source herdr-automatic-rename --clear-token tab_number"
check_absent "clear reports no new token" "$out" "--token tab_number="
check_absent "clear preserves unrelated tokens" "$out" "--clear-token other"

export HERDR_MOCK_VERSION=0.7.9
run tab.moved
check_absent "old Herdr issues no unsupported metadata calls" "$(cat "$HERDR_MOCK_LOG")" "pane report-metadata"

# The separate-list fallback also fetches panes when naming is disabled.
jq '.result.snapshot | {result:{workspaces:.workspaces}}' "$HERDR_MOCK_DIR/snapshot.json" > "$HERDR_MOCK_DIR/workspaces.json"
jq '.result.snapshot | {result:{tabs:.tabs}}' "$HERDR_MOCK_DIR/snapshot.json" > "$HERDR_MOCK_DIR/tabs_w1.json"
jq '.result.snapshot | {result:{panes:.panes}}' "$HERDR_MOCK_DIR/snapshot.json" > "$HERDR_MOCK_DIR/panes.json"
rm "$HERDR_MOCK_DIR/snapshot.json"
export HERDR_MOCK_VERSION=0.8.0
run tab.moved
check_contains "fallback fetches pane inventory for metadata alone" "$(cat "$HERDR_MOCK_LOG")" \
  "pane report-metadata p1 --source herdr-automatic-rename --token tab_number=1"
t_summary
