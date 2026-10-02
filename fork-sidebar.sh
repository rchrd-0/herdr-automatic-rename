#!/usr/bin/env bash
# Optional sidebar identity. This module reports tokens; it never renames a
# workspace or changes naming ownership. Source after fork-metadata.sh.

# Validate whole inventories before using IDs in CLI calls or row transports.
ar_sidebar_inventory() { # <workspace|pane> <JSON>
  printf '%s' "$2" | jq -c -s --arg kind "$1" '
    def id: type == "string" and length > 0 and (test("[[:space:][:cntrl:]]") | not);
    if length == 1 then .[0] else error("expected one response") end
    | (if $kind == "workspace" then (.result.workspaces // .workspaces)
       else (.result.panes // .panes) end)
    | if type != "array" then error("missing inventory") else . end
    | if $kind == "workspace" then
        if all(.[]; type == "object" and (.workspace_id | id)
            and (.label | type == "string")
            and ((.tokens // {}) | type == "object")
            and ((.worktree // {}) | type == "object")
            and (all([.worktree.checkout_path,.worktree.repo_name,.worktree.repo_root][];
                     . == null or (type == "string" and (test("[[:cntrl:]]") | not))))
            and (.worktree.is_linked_worktree == null or
                 (.worktree.is_linked_worktree | type) == "boolean")) then .
        else error("invalid workspace inventory") end
      else
        map(. + {workspace_id: (.workspace_id //
          (if (.tab_id | type) == "string" and (.tab_id | contains(":"))
           then (.tab_id | split(":")[0]) else null end))})
        | if all(.[]; type == "object" and (.pane_id | id)
            and (.workspace_id | id) and ((.tokens // {}) | type == "object")) then .
          else error("invalid pane inventory") end
      end' 2>/dev/null
}

# Patch only these two keys. Empty context removes an old value; matching
# inventory values avoid a CLI round trip. Other metadata remains untouched.
ar_sidebar_report() { # <workspace|pane> <id> <tokens JSON> <label> <context> [clear]
  local scope=$1 id=$2 tokens=$3 label=$4 context=$5 clear=${6:-0} changes key value
  local -a args
  changes=$(printf '%s' "$tokens" | jq -r --arg label "$label" --arg ctx "$context" \
    --arg clear "$clear" '
    . as $old | [["ar_workspace_label",$label],["ar_checkout_context",$ctx]][]
    | .[0] as $key | (if $clear == "1" then "" else .[1] end) as $value
    | select(if $value == "" then ($old | has($key)) else $old[$key] != $value end)
    | [$key,$value] | join([31]|implode)' 2>/dev/null) || { ar_trace "$id sidebar token comparison failed"; return 1; }
  [ -n "$changes" ] || return 0
  args=("$scope" report-metadata "$id" --source herdr-automatic-rename)
  while IFS=$AR_ROW_SEP read -r key value; do
    if [ -n "$value" ]; then args+=(--token "$key=$value")
    else args+=(--clear-token "$key")
    fi
  done <<< "$changes"
  "$HERDR" "${args[@]}" >/dev/null 2>&1 || { ar_trace "$id sidebar metadata update failed; retry next event"; return 1; }
}

# Read HEAD afresh. A hash-like branch is still a branch, and a rebase's saved
# symbolic head is still its branch. Only a genuinely detached commit gets @.
ar_sidebar_branch() { # <checkout path>; publishes AR_SIDEBAR_BRANCH
  local head state symbolic=0
  AR_SIDEBAR_BRANCH=""
  ar_git_head "$1" || return 1
  AR_SIDEBAR_BRANCH=$AR_GIT_HEAD
  ar_git_line "$AR_GIT_DIR/HEAD" || return 1
  head=$AR_GIT_LINE
  case "$head" in
    'ref: refs/heads/'?*) symbolic=1; AR_SIDEBAR_BRANCH=${head#ref: refs/heads/} ;;
  esac
  if [ "$symbolic" = "0" ]; then
    for state in rebase-merge rebase-apply; do
      if ar_git_line "$AR_GIT_DIR/$state/head-name"; then
        case "$AR_GIT_LINE" in
          refs/heads/?*) symbolic=1; AR_SIDEBAR_BRANCH=${AR_GIT_LINE#refs/heads/}; break ;;
        esac
      fi
    done
  fi
  if [ "$symbolic" != "1" ]; then
    case ${#head} in 40|64) ;; *) return 1 ;; esac
    case "$head" in *[!0-9a-fA-F]*) return 1 ;; esac
    AR_SIDEBAR_BRANCH="detached@${head:0:7}"
  fi
  case "$AR_SIDEBAR_BRANCH" in *[[:cntrl:]]*) AR_SIDEBAR_BRANCH=""; return 1 ;; esac
  return 0
}

ar_sidebar_sync() { # <workspace-list JSON> [only workspace id]
  local wsjson=$1 only=${2:-} ws panes rows wid label linked checkout repo root tokens
  local positions identities panedirs k v sure pos base derived enabled auto _unused
  local branch shown context manual pane_rows pid ptokens clear=0 scope inventory
  local AR_SIDEBAR_BRANCH=""
  ws=$(ar_sidebar_inventory workspace "$wsjson") || { ar_trace 'sidebar workspace inventory invalid; skipped'; return 0; }
  panes=$(ar_sidebar_inventory pane "${AR_PANES_JSON:-}") || { ar_trace 'sidebar pane inventory invalid; skipped'; return 0; }
  [ "${SIDEBAR_CONTEXT:-0}" = "1" ] && [ "${CLEAR:-0}" != "1" ] || clear=1
  if [ "$clear" = "1" ]; then
    # The default-off path with no existing tokens does no version or Git reads.
    printf '%s\n%s' "$ws" "$panes" | jq -e --arg w "$only" '
      .[] | select($w == "" or .workspace_id == $w)
      | (.tokens // {}) | has("ar_workspace_label") or has("ar_checkout_context")
      | select(.)' >/dev/null 2>&1 || return 0
  fi
  ar_tab_metadata_ok || return 0
  if [ "$clear" = "1" ]; then
    for scope in workspace pane; do
      if [ "$scope" = "workspace" ]; then inventory=$ws; else inventory=$panes; fi
      rows=$(printf '%s' "$inventory" | jq -r --arg w "$only" --arg kind "$scope" '
        .[] | select($w == "" or .workspace_id == $w)
        | [(if $kind == "workspace" then .workspace_id else .pane_id end),
           ((.tokens // {})|tojson)] | join([31]|implode)' 2>/dev/null) \
        || { ar_trace "sidebar $scope clear inventory failed"; continue; }
      while IFS=$AR_ROW_SEP read -r pid ptokens; do
        [ -n "$pid" ] || continue
        ar_sidebar_report "$scope" "$pid" "$ptokens" "" "" 1 || true
      done <<< "$rows"
    done
    return 0
  fi
  rows=$(printf '%s' "$ws" | jq -r "$AR_JQ_CLEAN"'
    .[] | [ .workspace_id, (.label|clean), ((.worktree.is_linked_worktree // false)|tostring),
      (.worktree.checkout_path // ""), (.worktree.repo_name // ""), (.worktree.repo_root // ""),
      ((.tokens // {})|tojson)] | join([31]|implode)' 2>/dev/null) || { ar_trace 'sidebar workspace rows failed'; return 0; }
  if [ "$clear" != "1" ]; then
    positions=$(ar_workspace_positions "$wsjson" "$(ar_collapsed_spaces)") || { ar_trace 'sidebar visible positions failed'; return 0; }
    identities=$(ar_workspace_identities)
    panedirs=$(ar_workspace_pane_dirs "$wsjson")
    ar_state_rows
  fi
  while IFS=$AR_ROW_SEP read -r wid label linked checkout repo root tokens; do
    [ -n "$wid" ] || continue
    [ -z "$only" ] || [ "$wid" = "$only" ] || continue
    shown="" context=""
    if [ "$clear" != "1" ]; then
      # The engine can settle a workspace name after fetching wsjson. Its map
      # contains actual display labels, rather than the bases tabs dedupe on.
      while IFS=$AR_ROW_SEP read -r k v; do
        [ "$k" = "$wid" ] && { label=$v; break; }
      done <<< "${AR_SIDEBAR_LABELS:-}"
      if [ -z "$checkout" ]; then
        while IFS=$AR_ROW_SEP read -r k v; do
          if [ "$k" = "$wid" ]; then checkout=$v; break; fi
        done <<< "$identities"
      fi
      if [ -z "$checkout" ]; then
        # An unfocused split with several active-tab panes has no authoritative
        # cwd. Refuse its arbitrary first-pane fallback instead of inventing a
        # branch for the whole workspace.
        while IFS=$AR_ROW_SEP read -r k v sure; do
          if [ "$k" = "$wid" ] && [ "$sure" = "1" ]; then checkout=$v; break; fi
        done <<< "$panedirs"
      fi
      # Never interpret malformed paths against the plugin process directory.
      case "$checkout" in /*) ;; *) checkout="" ;; esac
      case "$checkout$repo$root" in *[[:cntrl:]]*) ar_trace "$wid sidebar identity contains controls; skipped"; continue ;; esac
      base=$(ar_strip_prefix "$label")
      derived=""
      [ -z "$checkout" ] || derived=$(ar_project_base "$checkout")
      branch=""
      if [ -n "$checkout" ] && ar_sidebar_branch "$checkout"; then branch=$AR_SIDEBAR_BRANCH
      elif [ "$linked" = "true" ]; then
        branch="worktree:${checkout:-${root:-$wid}}"
        ar_trace "$wid sidebar branch unavailable; using explicit checkout identity"
      fi
      [ -n "$repo" ] || { [ -z "$root" ] || repo=${root%/}; repo=${repo##*/}; }
      [ -n "$repo" ] || repo=${derived:-$base}
      manual=1
      IFS=$AR_ROW_SEP read -r enabled auto _unused <<< "$(ar_state_fields "ws:$wid")"
      if [ -z "${AR_STATE_ROWS_BAD:-}" ] && [ "$enabled" != "false" ]; then
        if { [ "$enabled" = "true" ] && [ "$base" = "$auto" ]; } \
           || { [ -n "$derived" ] && [ "$base" = "$derived" ]; } \
           || { [ -n "$branch" ] && [ "$base" = "${branch#worktree/}" ]; }; then manual=0; fi
      fi
      shown=$base
      if [ "$linked" = "true" ]; then
        context=$repo
        if [ "$manual" = "0" ] && [ -n "$branch" ]; then shown=${branch#worktree/}
        elif [ -n "$branch" ]; then context="$repo:$branch"
        fi
      else context=$branch
      fi
      pos=0
      while IFS=$AR_ROW_SEP read -r k v sure; do
        [ "$k" = "$wid" ] && { pos=$sure; break; }
      done <<< "$positions"
      shown=$(ar_desired workspaces "$pos" "$shown")
    fi
    ar_sidebar_report workspace "$wid" "$tokens" "$shown" "$context" "$clear" || true
    pane_rows=$(printf '%s' "$panes" | jq -r --arg w "$wid" '
      .[] | select(.workspace_id == $w)
      | [.pane_id, ((.tokens // {})|tojson)] | join([31]|implode)' 2>/dev/null) \
      || { ar_trace "$wid sidebar pane rows failed"; continue; }
    while IFS=$AR_ROW_SEP read -r pid ptokens; do
      [ -n "$pid" ] || continue
      ar_sidebar_report pane "$pid" "$ptokens" "$shown" "$context" "$clear" || true
    done <<< "$pane_rows"
  done <<< "$rows"
}

# Prompt refresh targets the caller's workspace, never the UI's current focus.
# A fresh inventory is necessary because a checkout can change without an event.
ar_sidebar_refresh_current() {
  local wid=${HERDR_WORKSPACE_ID:-} snap ws pn
  local AR_PANES_JSON AR_SIDEBAR_LABELS=""
  [ "${SIDEBAR_CONTEXT:-0}" = "1" ] && [ "${CLEAR:-0}" != "1" ] || return 0
  ar_tab_metadata_ok || return 0
  if [ -z "$wid" ]; then
    case "${HERDR_TAB_ID:-}" in *:*) wid=${HERDR_TAB_ID%%:*} ;; *) return 0 ;; esac
  fi
  case "$wid" in ""|*[[:space:][:cntrl:]]*) ar_trace 'sidebar prompt workspace id invalid'; return 0 ;; esac
  snap=$("$HERDR" api snapshot 2>/dev/null) || snap=""
  if printf '%s' "$snap" | jq -e -s 'length == 1 and (.[0] | (.result.snapshot // .snapshot)
      | (.workspaces|type == "array") and (.panes|type == "array"))' >/dev/null 2>&1; then
    ws=$(printf '%s' "$snap" | jq -c '{result:{workspaces:(.result.snapshot // .snapshot).workspaces}}')
    pn=$(printf '%s' "$snap" | jq -c '{result:{panes:(.result.snapshot // .snapshot).panes}}')
    if ! ar_sidebar_inventory workspace "$ws" >/dev/null || ! ar_sidebar_inventory pane "$pn" >/dev/null; then snap=""; fi
  else snap=""
  fi
  if [ -z "$snap" ]; then
    ws=$("$HERDR" workspace list 2>/dev/null) || { ar_trace 'sidebar prompt workspace read failed'; return 0; }
    pn=$("$HERDR" pane list 2>/dev/null) || { ar_trace 'sidebar prompt pane read failed'; return 0; }
  fi
  AR_PANES_JSON=$pn
  ar_sidebar_sync "$ws" "$wid"
}
