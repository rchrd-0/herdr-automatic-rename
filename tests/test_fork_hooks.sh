#!/usr/bin/env bash
# Existing fork hooks remain loaded after an engine update. Their explicit cwd
# and fourth-argument shell marker must work with upstream context labels.
set -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
ENGINE="$here/../automatic-rename.sh"
MOCK="$here/mocks/herdr"
SEP=$(printf ' \342\200\272 ')

setup() {
  SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-fork-hooks.XXXXXX")
  export HERDR_MOCK_DIR="$SB/fixtures" HERDR_MOCK_LOG="$SB/renames.log"
  mkdir -p "$HERDR_MOCK_DIR" "$SB/state/herdr-automatic-rename"
  : > "$HERDR_MOCK_LOG"
  export HERDR_BIN_PATH="$MOCK" HERDR_PLUGIN_ROOT="${ENGINE%/*}"
  export XDG_STATE_HOME="$SB/state" XDG_CONFIG_HOME="$SB/config"
  export HERDR_SOCKET_PATH="$SB/herdr.sock" HERDR_CONFIG_FILE="$SB/herdr.toml"
  export HERDR_AUTOMATIC_RENAME_CONFIG="$SB/config.sh"
  export HERDR_TAB_ID=w1:t1 HERDR_PANE_ID=p1 SHELL_NAME=zsh
  export NAME_TABS=1 AUTO_INDEX=1 TAB_CONTEXT=1 SHOW_BRANCH=0 AGENT_TITLES=0
  export ICONS_ENABLED=0 HIDE_SHELL=0 AUTO_INDEX_WORKSPACES=0
  unset HERDR_SESSION HERDR_CLIENT_SOCKET_PATH HERDR_MOCK_FAIL_RENAME
  unset HERDR_MOCK_FAIL_VERB HERDR_MOCK_RERUN_ONCE HERDR_MOCK_TAB_GONE_AFTER
  unset HERDR_MOCK_NO_VERSION HERDR_MOCK_VERSION HOST_PREFIX HERDR_PLUGIN_CONTEXT_JSON
  printf '%s' '{"w1:t1":{"auto":"zsh","enabled":true,"ws":"elsewhere"}}' \
    > "$SB/state/herdr-automatic-rename/state.json"
  fixture tab_w1:t1.json <<'JSON'
{"result":{"tab":{"tab_id":"w1:t1","label":"[1] zsh"}}}
JSON
}
fixture() { cat > "$HERDR_MOCK_DIR/$1"; }
log() { cat "$HERDR_MOCK_LOG"; }
teardown() { rm -rf "$SB"; }

setup
/bin/bash "$ENGINE" preexec 'nvim README.md' /work/project
check "old external hook uses explicit cwd with upstream labels" \
  "tab rename w1:t1 [1] project${SEP}nvim" "$(log)"
check "old external hook records composed ownership" "project${SEP}nvim" \
  "$(jq -r '."w1:t1".auto' "$SB/state/herdr-automatic-rename/state.json")"
teardown

setup
/bin/bash "$ENGINE" precmd fish /work/project
check "old prompt hook uses explicit cwd and calling shell" \
  "tab rename w1:t1 [1] project${SEP}fish" "$(log)"
teardown

setup
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
"foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
/bin/bash "$ENGINE" preexec v /work/project shell
check "old fourth-argument marker samples the real process" \
  "tab rename w1:t1 [1] project${SEP}nvim" "$(log)"
teardown

setup
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":200,
"foreground_processes":[{"pid":200,"argv0":"nvim","cmdline":"nvim README.md"}]}}}
JSON
mkdir -p "$SB/project"
(cd "$SB/project" && /bin/bash "$ENGINE" preexec v shell)
check "upstream third-argument marker still uses inherited cwd" \
  "tab rename w1:t1 [1] project${SEP}nvim" "$(log)"
teardown

setup
/bin/bash "$ENGINE" precmd zsh /work/new-project
check "new prompt writes its directory first" \
  "tab rename w1:t1 [1] new-project${SEP}zsh" "$(log)"
fixture tab_w1:t1.json <<JSON
{"result":{"tab":{"tab_id":"w1:t1","label":"[1] new-project${SEP}zsh"}}}
JSON
fixture procinfo_p1.json <<'JSON'
{"result":{"process_info":{"foreground_process_group_id":100,
"foreground_processes":[{"pid":100,"argv0":"-zsh","cmdline":"-zsh"}]}}}
JSON
: > "$HERDR_MOCK_LOG"
/bin/bash "$ENGINE" preexec 'cd /work/new-project' /work/old-project shell
check "delayed sampled shell cannot restore the old cwd" '' "$(log)"
check "delayed sample retains latest prompt ownership" "new-project${SEP}zsh" \
  "$(jq -r '."w1:t1".auto' "$SB/state/herdr-automatic-rename/state.json")"
teardown

# A synchronous rename callback inspects the same file a real event handler
# reads before the rename command returns. Use sourced engine functions so the
# callback can exercise ar_own_rename directly without an asynchronous race.
setup
# shellcheck source=naming.sh
. "$here/../naming.sh"
# shellcheck source=automatic-rename.sh
. "$ENGINE"
mkdir -p "$STATE_DIR"
review_herdr() {
  local group=$1 action=$2
  shift 2
  case "$group $action" in
    'tab get') cat "$HERDR_MOCK_DIR/tab_$1.json" ;;
    'tab rename')
      jq -n --arg t "$1" --arg l "$2" '{result:{tab:{tab_id:$t,label:$l}}}' \
        > "$HERDR_MOCK_DIR/tab_$1.json"
      if ar_own_rename "$1"; then printf owned >> "$SB/synchronous"; fi
      ;;
    *) return 1 ;;
  esac
}
HERDR=review_herdr
ar_name_eligible w1:t1 zsh
ar_rename_owned_tab w1:t1 "project${SEP}nvim" '[1] zsh' \
  "[1] project${SEP}nvim" elsewhere 0
check "synchronous event already recognizes new ownership" owned \
  "$(cat "$SB/synchronous" 2>/dev/null)"
check_rc "normal claim is recognized after rename returns" 0 \
  "$(ar_own_rename w1:t1; printf '%s' "$?")"

HOST_PREFIX=1
tag=$(ar_host_tag)
ar_state_set w1:t1 "project${SEP}nvim" true elsewhere true
ar_name_eligible w1:t1 "project${SEP}nvim"
: > "$SB/synchronous"
ar_rename_owned_tab w1:t1 "project${SEP}vim" "[1] project${SEP}nvim" \
  "${tag}[1] project${SEP}vim" elsewhere 1
check "synchronous host-tagged event recognizes new ownership" owned \
  "$(cat "$SB/synchronous" 2>/dev/null)"
check_rc "host tag is peeled from a recorded tagged claim" 0 \
  "$(ar_own_rename w1:t1; printf '%s' "$?")"
fixture tab_w1:t1.json <<'JSON'
{"result":{"tab":{"tab_id":"w1:t1","label":"[1] manual notes"}}}
JSON
check_rc "manual name cannot be mistaken for self rename" 1 \
  "$(ar_own_rename w1:t1; printf '%s' "$?")"
printf '%s' '{"w1:t1":{"auto":"manual notes","enabled":true,"seeded":true,"tagged":true}}' \
  > "$STATE_FILE"
AR_STATE_ROWS_LOADED=''
check_rc "seeded host-tagged record is not established ownership" 1 \
  "$(ar_own_rename w1:t1; printf '%s' "$?")"
teardown

t_summary
