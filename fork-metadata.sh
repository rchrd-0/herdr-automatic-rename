#!/usr/bin/env bash
# Fork extension: expose each pane's tab jump position as sidebar metadata.
# Source after automatic-rename.sh defines its version helpers; reconciles use
# the cached AR_PANES_JSON and the tab-specific ar_index_on predicate.

AR_METADATA_SOURCE="herdr-automatic-rename"
AR_TAB_NUMBER_TOKEN="tab_number"

# ar_tab_metadata_ok -> 0 when pane custom metadata and row tokens are available.
# `pane report-metadata` arrived in herdr 0.8.0. An unreadable version disables
# reporting so older installations keep working without rejected CLI calls.
ar_tab_metadata_ok() {
  local v
  v=$(ar_herdr_version) || return 1
  ! ar_version_lt "$v" "0.8.0"
}

# ar_clear_tab_number_tokens [tab_id]
# Remove this plugin's tab-number token from panes that currently carry it.
# With a tab id, limit the clear to panes in that tab; without one, clear every
# cached pane. Other custom metadata sources and tokens are left untouched.
ar_clear_tab_number_tokens() {
  local tid="${1:-}" rows pid
  rows=$(printf '%s' "$AR_PANES_JSON" | jq -r \
    --arg t "$tid" --arg token "$AR_TAB_NUMBER_TOKEN" '
      (.result.panes // .panes // [])[]
      | select($t == "" or .tab_id == $t)
      | select((.tokens // {}) | has($token))
      | .pane_id // empty
    ' 2>/dev/null)
  [ -n "$rows" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    "$HERDR" pane report-metadata "$pid" \
      --source "$AR_METADATA_SOURCE" \
      --clear-token "$AR_TAB_NUMBER_TOKEN" >/dev/null 2>&1 || ar_trace "$pid tab-number metadata update failed; retry on next reconcile"
  done <<< "$rows"
}

# ar_sync_tab_number_token <tab_id> <position>
# Publish a plain 1-9 tab position to every pane in the tab, skipping panes whose
# cached token is already correct. Positions past 9 have no jump key, so clear a
# stale value instead of reporting an unreachable number.
ar_sync_tab_number_token() {
  local tid=$1 pos=$2 rows pid
  if [ "$pos" -lt 1 ] || [ "$pos" -gt 9 ]; then
    ar_clear_tab_number_tokens "$tid"
    return 0
  fi
  rows=$(printf '%s' "$AR_PANES_JSON" | jq -r \
    --arg t "$tid" --arg token "$AR_TAB_NUMBER_TOKEN" --arg want "$pos" '
      (.result.panes // .panes // [])[]
      | select(.tab_id == $t)
      | select((((.tokens // {})[$token]) // "") != $want)
      | .pane_id // empty
    ' 2>/dev/null)
  [ -n "$rows" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    "$HERDR" pane report-metadata "$pid" \
      --source "$AR_METADATA_SOURCE" \
      --token "$AR_TAB_NUMBER_TOKEN=$pos" >/dev/null 2>&1 || ar_trace "$pid tab-number metadata update failed; retry on next reconcile"
  done <<< "$rows"
}
