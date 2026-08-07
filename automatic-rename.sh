#!/usr/bin/env bash
#
# herdr-automatic-rename - one plugin, two toggleable features:
#
#   NAME_TABS=1   auto-name each tab after its foreground program, or the shell
#                 name at a bare prompt (manual renames opt a tab out). Applies
#                 to tabs only.
#   AUTO_INDEX=1  prefix each workspace, tab, and agent with the 1-9 number of
#                 its jump keybind (switch_workspace/switch_tab/focus_agent) as
#                 "[N] <base>". Applies to workspaces, tabs, and agents -- except
#                 agents, which are numbered only on herdr < 0.7.5 (newer herdr
#                 rejects a bracketed agent name outright, see ar_agent_prefix_ok)
#                 and only when the panel is grouped-sorted ("priority" sort
#                 reorders the panel behind an API we can't read, see
#                 ar_agent_sort). Agent prefixes are stripped in both cases.
#
# Both default on and are configured in config.sh ($HERDR_AUTOMATIC_RENAME_CONFIG). A
# single unified reconcile drives both: one pass computes a tab's base name and
# its "[N]" prefix together and issues one rename per item, so a brand-new tab
# settles at "[3] zsh" in a single rename with no placeholder flicker.
#
# Invoked several ways, all routing through ar_run:
#   * herdr [[events]] hooks:     automatic-rename.sh <event.name>
#   * shell preexec/precmd hooks: automatic-rename.sh preexec "<cmdline>"
#                                 automatic-rename.sh precmd [<shell-name>]
#   * the "reset" action:         automatic-rename.sh reset      (re-adopt active tab)
#   * the "clear" action:         automatic-rename.sh --clear    (strip all prefixes)
#
# The live per-command hooks ship with the plugin under shell/ (hook.zsh,
# hook.bash, hook.fish); each passes its own shell name to precmd so a bare
# prompt in a bash/fish pane reads "bash"/"fish" rather than $SHELL.
#
# herdr has no per-tab metadata and no auto/manual flag, so the manual-rename
# exclusion is tracked here: a JSON state file remembers the last base we set
# per tab_id and whether auto-naming is still enabled for it. Config and state
# live at FIXED paths (not $HERDR_PLUGIN_{CONFIG,STATE}_DIR) so the herdr-invoked
# and shell-invoked runs share one store: the preexec/precmd runs are launched by
# the shell, not herdr, and never receive the HERDR_PLUGIN_* env vars. Needs jq.
#
# Targets bash 3.2 (macOS /bin/bash): no associative arrays, no namerefs.

# Resolve our own directory so `. "$AR_ROOT/naming.sh"` works whether herdr runs
# us (HERDR_PLUGIN_ROOT is set), we are executed directly, or we are SOURCED by
# the test suite. BASH_SOURCE[0] points at this file in all three cases; $0 would
# be the test runner when sourced.
AR_ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
HERDR="${HERDR_BIN_PATH:-herdr}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-automatic-rename"
STATE_FILE="$STATE_DIR/state.json"
LOCK_DIR="$STATE_DIR/lock"
RERUN_FLAG="$STATE_DIR/rerun"
CONFIG_FILE="${HERDR_AUTOMATIC_RENAME_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-automatic-rename/config.sh}"

# The prerequisite checks, config + naming load, toggle defaults, mode parse, and
# dispatch all live in ar_main (bottom of file) so that sourcing this file for
# unit tests loads ONLY the function definitions and touches nothing at runtime.

# ======================================================================
# prefix helpers (the "[N] " contract, shared by both features)
# ======================================================================

# ar_strip_prefix <label> -> label with a leading "[<digits>] " removed. Only
# strips when the bracketed part is all digits (so user text like "[wip] foo" is
# left untouched), and removes the EXACT reconstructed "[num] " literal so this
# is the precise inverse of ar_index_prefix (a malformed label such as "[1]x] foo"
# is left alone by both, never diverging).
#
# The "[N]" prefix may also stand alone, with an empty base: that is the label a
# numbered HIDE_SHELL tab carries, and without accepting it here a hidden tab would
# read its own "[3]" back as a hand-typed base and opt out.
#
# Workspaces and agents share these helpers, so a row labeled exactly "[N]" strips
# to "" for them too. Both numbering paths guard on a non-empty base and leave such
# a row alone; the agent revert path does not, and would rename it to "". Only a
# tab is ever numbered with an empty base, so reaching that needs a hand-typed "[3]".
ar_strip_prefix() {
  local s=$1 num
  case "$s" in
    \[[0-9]*\]\ *|\[[0-9]*\])
      num=${s#\[}; num=${num%%\]*}
      case "$num" in
        ''|*[!0-9]*)   printf '%s' "$s" ;;
        *)
          if [ "$s" = "[$num]" ]; then printf ''
          else printf '%s' "${s#"[$num] "}"
          fi ;;
      esac
      ;;
    *) printf '%s' "$s" ;;
  esac
}

# ar_index_prefix <label> -> the leading "[<digits>] " or "" when absent. Used by
# the fast path to carry an existing number forward without recomputing position.
ar_index_prefix() {
  local s=$1 num
  case "$s" in
    \[[0-9]*\]\ *|\[[0-9]*\])
      num=${s#\[}; num=${num%%\]*}
      case "$num" in
        ''|*[!0-9]*) printf '' ;;
        *)           printf '[%s] ' "$num" ;;
      esac
      ;;
    *) printf '' ;;
  esac
}

# ar_desired <position> <base> -> the label this item should have.
#   --clear             -> always the bare base (strip numbering)
#   AUTO_INDEX off       -> bare base (self-heals a stale prefix as items reconcile)
#   AUTO_INDEX on, 1..9  -> "[N] base"
# Any other position -> bare base, because no keybind reaches the item: it sits
# past the 9th slot, or (position 0) the sidebar does not render it at all, which
# is how ar_workspace_positions reports a row hidden inside a collapsed space.
ar_desired() {
  local n=$1 base=$2
  if [ "$CLEAR" = "1" ] || [ "$AUTO_INDEX" != "1" ]; then printf '%s' "$base"; return; fi
  if [ "$n" -ge 1 ] && [ "$n" -le 9 ]; then
    # An empty base (a HIDE_SHELL tab) is numbered "[3]", not "[3] " -- herdr
    # would drop the trailing space anyway, and ar_strip_prefix reads the bare
    # form back as the empty base it came from.
    printf '[%d]%s' "$n" "${base:+ $base}"
  else
    printf '%s' "$base"
  fi
}

# A label counts as "unnamed" -- fair game for FIRST-TIME auto-naming, and the
# form herdr hands back to a tab we deliberately left label-less -- when it is
# empty or a plain integer, because herdr's generated tab labels are small
# integers ("1", "2"...). Callers for which an empty label is instead a finished
# answer gate on a non-empty argument first; ar_reconcile_tabs' placeholder skip
# does exactly that.
ar_is_placeholder() {
  [ -z "$1" ] && return 0
  case "$1" in
    *[!0-9]*) return 1 ;;
    *)        return 0 ;;
  esac
}

# ======================================================================
# cross-invocation lock (mkdir is atomic; 30s steal window)
# ======================================================================
# An ownership token stamped inside the lock dir means ar_unlock only ever
# removes OUR lock, never one another run re-created after a steal, so the
# release-recheck-reacquire dance in ar_run is safe. 30s is comfortably longer
# than any normal full pass, so a slow run is not stolen out from under itself.
AR_LOCK_TOKEN="$$-${RANDOM:-0}-$(date +%s 2>/dev/null || echo 0)"
ar_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$AR_LOCK_TOKEN" > "$LOCK_DIR/owner" 2>/dev/null
    return 0
  fi
  local now mt age
  now=$(date +%s 2>/dev/null || echo 0)
  mt=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo "$now")
  age=$(( now - mt ))
  if [ "$age" -gt 30 ]; then
    rm -f "$LOCK_DIR/owner" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s' "$AR_LOCK_TOKEN" > "$LOCK_DIR/owner" 2>/dev/null
      return 0
    fi
  fi
  return 1
}
ar_unlock() {
  [ "$(cat "$LOCK_DIR/owner" 2>/dev/null)" = "$AR_LOCK_TOKEN" ] || return 0
  rm -f "$LOCK_DIR/owner" 2>/dev/null
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# ======================================================================
# naming state (atomic temp+mv; jq keyed by tab_id; only NAME_TABS uses it)
# ======================================================================
ar_state_get() { # <tab_id> <field>
  [ -f "$STATE_FILE" ] || return 0
  # NOT `.[$t][$f] // empty`: `//` treats a boolean `false` as absent, so the
  # `enabled` flag would read back as "" and an opted-out tab would look
  # first-seen on every pass (re-adopting a deliberately numeric name). Emit the
  # value unless it is genuinely null/missing.
  jq -r --arg t "$1" --arg f "$2" '.[$t][$f] as $v | if $v == null then empty else $v end' \
    "$STATE_FILE" 2>/dev/null
}
ar_state_set() { # <tab_id> <auto-name> <enabled true|false>
  local base tmp
  base='{}'
  [ -f "$STATE_FILE" ] && base=$(cat "$STATE_FILE" 2>/dev/null)
  [ -n "$base" ] || base='{}'
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 0
  if printf '%s' "$base" | jq --arg t "$1" --arg a "$2" --argjson e "$3" \
       '.[$t] = {auto: $a, enabled: $e}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
  fi
}
ar_state_del() { # <tab_id>
  [ -f "$STATE_FILE" ] || return 0
  local tmp
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 0
  if jq --arg t "$1" 'del(.[$t])' "$STATE_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
  fi
}
ar_state_prune() { # <keep tab_ids...> - drop entries for tabs that no longer exist
  [ -f "$STATE_FILE" ] || return 0
  local keep tmp
  keep=$(printf '%s\n' "$@" | jq -R . | jq -s .) || return 0
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 0
  if jq --argjson keep "$keep" \
       'with_entries(select(.key as $k | $keep | index($k)))' "$STATE_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
  fi
}

# ar_name_eligible <tab_id> <base label, prefix already stripped>
# The manual-rename exclusion state machine. Returns 0 (eligible for auto-naming)
# or 1 (leave the base alone). May write opt-out state as a side effect. Needs no
# computed name, so an opted-out tab costs no process-info call.
ar_name_eligible() {
  local tab=$1 slabel=$2 enabled auto
  enabled=$(ar_state_get "$tab" enabled)
  auto=$(ar_state_get "$tab" auto)
  if [ -n "${AR_FORCE_TAB:-}" ] && [ "$tab" = "$AR_FORCE_TAB" ]; then
    return 0                                    # reset forces re-adoption
  elif [ -z "$enabled" ]; then
    # First time we see this tab: adopt herdr's generated placeholder label
    # (empty or a bare integer); anything else was named by hand -> opt out.
    if ar_is_placeholder "$slabel"; then return 0
    else ar_state_set "$tab" "" false; return 1
    fi
  elif [ "$enabled" = "false" ]; then
    # Opted out. Re-adopt ONLY on an explicit clear (empty label); a numeric
    # label is a deliberate name, not a reset (use the reset action for that).
    if [ -z "$slabel" ]; then return 0
    else return 1
    fi
  else
    # We own it; keep updating while the base still matches what we last set.
    if [ "$slabel" = "$auto" ]; then return 0
    elif [ -z "$slabel" ]; then return 0        # user cleared it -> re-adopt
    # A HIDE_SHELL tab is owned with an EMPTY auto name, and herdr may hand a
    # label-less tab its generated number back (a restored session, its own
    # relabeling). Reading that as a hand rename would freeze the tab on the
    # number and stop naming it once a real program starts, so keep ownership.
    elif [ -z "$auto" ] && ar_is_placeholder "$slabel"; then return 0
    else ar_state_set "$tab" "" false; return 1 # user renamed -> opt out
    fi
  fi
}

# ======================================================================
# tab-name computation (herdr-touching; feeds ar_format from naming.sh)
# ======================================================================

# ar_resolve_pane <tab_id> <pane_count> <focused> -> TSV "pane_id<TAB>cwd".
# The sole pane of a single-pane tab, else the globally focused pane for the
# focused tab. A background multi-pane tab exposes no active pane over the socket
# and returns empty fields (its name is left as-is until it is next focused).
# Reads pane identity and foreground cwd from the cached $AR_PANES_JSON so name
# computation never needs another herdr request.
ar_resolve_pane() {
  local tid=$1 pc=$2 foc=$3
  printf '%s' "$AR_PANES_JSON" | jq -r --arg t "$tid" --arg pc "$pc" --arg foc "$foc" '
    (.result.panes // .panes // []) as $p
    | ($p | map(select(.tab_id == $t))) as $tp
    | (if $pc == "1" then $tp[0]
       elif $foc == "true" then (($p | map(select(.focused)) | .[0]) // $tp[0])
       else null end)
    | if . == null then ["", ""]
      else [(.pane_id // ""), (.foreground_cwd // .cwd // "")]
      end
    | @tsv
  ' 2>/dev/null
}

# ar_pane_program <pane_id> -> TSV "program<TAB>cmdline".
# The foreground command is the process-group leader (pid == group id). At a bare
# prompt the leader IS the login shell, whose argv0 ("-zsh") strips to "zsh".
#
# program comes from how the process was INVOKED, preferring .argv0, then argv[0].
# .name is the last resort because it is the on-disk executable, which is often
# not what the user typed: agents like claude report a version string there, and
# on NixOS a wrapped program reports the internal ".<prog>-wrapped" binary while
# argv[0] still holds the real name (issue #6). herdr only emits .argv0 on some
# platforms -- Linux builds send argv/cmdline/name alone -- so argv[0] is what
# keeps those from falling through to .name.
# A login shell's leading "-" is removed and any path stripped.
ar_pane_program() {
  local out
  out=$("$HERDR" pane process-info --pane "$1" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '
    (.result.process_info // .process_info) as $pi
    | ($pi.foreground_process_group_id) as $g
    | ($pi.foreground_processes // []) as $fp
    | ($fp | map(select(.pid == $g)) | first) as $p
    | if ($p == null) then
        ["", ""]
      else
        [ (($p.argv0 // (($p.argv // [])[0]) // $p.name // "") | sub("^-"; "") | split("/") | last),
          ($p.cmdline // (($p.argv // []) | join(" "))) ]
      end
    | @tsv
  ' 2>/dev/null
}

# ar_tab_name <tab_id> <pane_count> <focused> -> computed base name on stdout.
# Returns 1 when the name can't be computed (no resolvable pane, process-info
# failure); a successful HIDE_SHELL computation returns 0 with EMPTY output, so
# the caller must read the status, not the string, to tell the two apart.
ar_tab_name() {
  local pane_data pane="" cwd="" info prog="" cmd=""
  pane_data=$(ar_resolve_pane "$1" "$2" "$3")
  IFS=$'\t' read -r pane cwd <<< "$pane_data"
  [ -n "$pane" ] || return 1
  # process-info can fail transiently (pane closing, socket hiccup) or resolve no
  # foreground process; both leave prog empty. Fail so the caller keeps the tab's
  # current name, rather than falling through to ar_format "" "" -> $SHELL_NAME
  # and clobbering (e.g.) an "nvim" tab with "zsh" on a blip.
  info=$(ar_pane_program "$pane") || return 1
  IFS=$'\t' read -r prog cmd <<< "$info"
  [ -n "$prog" ] || return 1
  ar_format "$prog" "$cmd" "$cwd"
}

# ======================================================================
# reconcilers
# ======================================================================

# ar_herdr_session_dir -> the directory herdr keeps this session's state in: the
# config dir for the default session, ~/.config/herdr/sessions/<name>/ for a named
# one. Both session.json and that session's config.toml live there, and herdr puts
# the API socket there too and exports HERDR_SOCKET_PATH into plugin commands AND
# pane environments, so stripping the socket's filename names the right directory
# from the herdr-invoked pass and the shell hooks alike. Falls back to the default
# session's dir when the variable is unset.
ar_herdr_session_dir() {
  if [ -n "${HERDR_SOCKET_PATH:-}" ]; then
    printf '%s' "${HERDR_SOCKET_PATH%/*}"
  else
    printf '%s/herdr' "${XDG_CONFIG_HOME:-$HOME/.config}"
  fi
}

# ar_collapsed_spaces -> JSON array of the space keys (repo_key strings) whose
# sidebar group is collapsed right now. herdr exposes collapse NOWHERE in the API
# (no field on workspace list / api snapshot, no event, protocol 17), and stores
# it only as session.json's top-level collapsed_space_keys, so we read that file
# the way ar_agent_sort reads config.toml. See docs/ARCHITECTURE.md for why that
# leaves the numbers up to herdr's 5-second save debounce behind a collapse. A
# missing or unreadable file means "nothing collapsed", which is how the plugin
# behaved before it read this at all.
ar_collapsed_spaces() {
  jq -c '[ .collapsed_space_keys[]? | strings ]' \
    "$(ar_herdr_session_dir)/session.json" 2>/dev/null || printf '[]'
}

# ar_workspace_positions <workspace-list-json> <collapsed-spaces-json>
#   -> one "<workspace_id>\t<label>\t<position>" row per workspace, where position
#      is its 1-based slot in herdr's VISIBLE sidebar order, or 0 when the sidebar
#      does not render it at all.
#
# alt+N resolves through that visible order (herdr's workspace_at_visible_position
# -> visible_workspace_order), NOT the raw `workspace list` array order, so this
# mirrors herdr's own workspace_list_entries_inner (src/ui/sidebar.rs). Keep the
# rules in this one place, in herdr's order, so re-checking them against upstream
# stays cheap:
#   * Workspaces sharing a .worktree.repo_key nest into one "space", but ONLY when
#     the repo has 2+ open workspaces AND one of them is the main checkout
#     (is_linked_worktree false). Two linked worktrees with no main workspace stay
#     separate top-level rows in array order.
#   * A space renders at the slot of its first-appearing member, and the row that
#     heads it is the MAIN checkout, with the other members nested after it in
#     array order, so a worktree listed before its main repo does not lead.
#   * A COLLAPSED space renders its head row alone. Its other members are hidden,
#     which is what position 0 means. The one exception herdr makes is the FOCUSED
#     member: a collapsed space keeps the active workspace rendered under its
#     parent, so that row still counts and every row after it shifts down. Numbers
#     therefore move when the user only collapses, expands, or switches workspaces.
#
# No herdr calls and no file reads: both inputs are passed in, so this is directly
# testable (see tests/test_ws_order.sh).
ar_workspace_positions() {
  printf '%s' "$1" | jq -r --argjson collapsed "$2" '
    [ (.result.workspaces // .workspaces // []) | to_entries[]
      | .value + { _i: .key,
                   _k: (.value.worktree.repo_key // ""),
                   _linked: (.value.worktree.is_linked_worktree // false) } ] as $rows
    # repo_key -> its members in SIDEBAR order (head first), for the keys that nest
    | ( reduce $rows[] as $r ({}; if $r._k == "" then . else .[$r._k] += [$r._i] end)
        | with_entries(
            ( [ .value[] | select($rows[.]._linked == false) ] | first ) as $head
            | select($head != null and (.value | length) >= 2)
            | .value = [ $head ] + [ .value[] | select(. != $head) ] ) ) as $spaces
    | ( [ $rows[] | select(.focused) | ._i ] | first ) as $active
    | ( [ $rows[]
          | ._k as $k | ._i as $i | $spaces[$k] as $mem
          | if $mem == null then $i                 # renders as its own row
            elif $i != ($mem | min) then empty      # space already rendered at its first member
            else $mem[0],                           # the main checkout heads it
                 ( if $collapsed | index($k)
                   then ( $active | select(. != null and . != $mem[0] and $rows[.]._k == $k) )
                   else $mem[1:][] end )
            end ] ) as $order
    | $rows[] | ._i as $i | ($order | index($i)) as $pos
    | [ .workspace_id, (.label // ""), (if $pos == null then 0 else $pos + 1 end) ]
    | @tsv' 2>/dev/null
}

# Workspaces: number them by herdr's visible sidebar order. Arg 1 is a cached
# `workspace list` JSON.
ar_renumber_workspaces() {
  local json=$1 rows wid label pos base want
  [ -n "$json" ] || return 0
  rows=$(ar_workspace_positions "$json" "$(ar_collapsed_spaces)")
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r wid label pos; do
    [ -n "$wid" ] || continue
    base=$(ar_strip_prefix "$label")
    [ -n "$base" ] || continue          # empty label: nothing to number, leave it
    want=$(ar_desired "$pos" "$base")   # position 0 (hidden) -> bare, like 10+
    [ "$want" = "$label" ] && continue
    "$HERDR" workspace rename "$wid" "$want" >/dev/null 2>&1 || true
  done <<< "$rows"
}

# Tabs: cmd+N indexes the focused workspace's tabs by ARRAY ORDER (NOT the
# non-contiguous .number field), so renumber each workspace's tabs 1..N
# independently by array position. This is also where auto-naming happens (tabs
# are the only item both features touch), so per tab we compute the base ONCE
# (naming if owned/eligible, else the stripped current base) and apply the
# position prefix in a single rename. Arg 1 is the cached `workspace list` JSON.
ar_reconcile_tabs() {
  local wsjson=$1 w tjson rows tid label pcount foc base0 base named name i want
  [ -n "$wsjson" ] || return 0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    if [ "${AR_HAVE_SNAPSHOT:-0}" = "1" ]; then
      # Slice this workspace's tabs out of the cached snapshot, preserving array
      # order (what cmd+N numbers by). Same shape as `tab list --workspace`.
      tjson=$(printf '%s' "$AR_SNAP_TABS_JSON" | jq -c --arg w "$w" \
        '{result:{tabs:[(.result.tabs // [])[]|select(.workspace_id==$w)]}}' 2>/dev/null)
    else
      tjson=$("$HERDR" tab list --workspace "$w" 2>/dev/null) || continue
    fi
    [ -n "$tjson" ] || continue
    rows=$(printf '%s' "$tjson" | jq -r '
      (.result.tabs // .tabs // [])[]
      | [ .tab_id, (.label // ""), (.pane_count // 0), (.focused // false) ] | @tsv' 2>/dev/null)
    [ -n "$rows" ] || continue
    i=0
    while IFS=$'\t' read -r tid label pcount foc; do
      [ -n "$tid" ] || continue
      i=$(( i + 1 ))
      AR_SEEN_TABS="$AR_SEEN_TABS $tid"
      base0=$(ar_strip_prefix "$label")
      base=$base0
      named=0
      if [ "$CLEAR" != "1" ] && [ "$NAME_TABS" = "1" ]; then
        # Status, not emptiness: under HIDE_SHELL an empty name IS the name. With
        # the knob off it is not, because a config can erase a name it did compute
        # (MAX_NAME_LEN=0, a SUBSTITUTE_SETS rule that matches everything) and
        # blanking a tab over that was never the deal. The fast path declines it too.
        if ar_name_eligible "$tid" "$base0" && name=$(ar_tab_name "$tid" "$pcount" "$foc") \
           && { [ -n "$name" ] || [ "${HIDE_SHELL:-0}" = "1" ]; }; then
          base=$name
          named=1
          ar_state_set "$tid" "$name" true     # record ownership even if no rename
        fi
      fi
      # herdr has not labeled this tab yet and we computed no name, so there is no
      # sensible "[i] " to form -- leave it until one of those changes. An empty
      # base is still written whenever the emptiness is deliberate: HIDE_SHELL just
      # named this tab nothing (named=1), or the label is already a bare "[i]" from
      # an earlier hidden pass, which still has to follow a renumber and to be
      # stripped by --clear. Both of those have a label, so testing it is enough.
      if [ -z "$label" ] && [ "$named" = "0" ]; then
        continue
      fi
      # Placeholder skip: with naming ON but no name computed yet, a bare-integer
      # base is herdr's transient placeholder ("3"). Numbering it now would flash
      # a throwaway "[3] 3" that the next event/zsh hook clobbers to "[3] zsh".
      # Defer this pass; the position (i) is still counted so later tabs are
      # correct. With naming OFF we DO number it (nothing else ever will), and
      # --clear must strip, so both skip this guard. An EMPTY base is not a
      # placeholder here (hence the -n, which ar_is_placeholder alone would not
      # give us): it got past the check above as a hidden tab, whose whole point is
      # to carry no name, so there is nothing to wait for.
      if [ "$CLEAR" != "1" ] && [ "$NAME_TABS" = "1" ] && [ "$named" = "0" ] \
         && [ -n "$base" ] && ar_is_placeholder "$base"; then
        continue
      fi
      want=$(ar_desired "$i" "$base")
      [ "$want" = "$label" ] && continue
      "$HERDR" tab rename "$tid" "$want" >/dev/null 2>&1 || true
    done <<< "$rows"
  done <<< "$(printf '%s' "$wsjson" | jq -r '(.result.workspaces // .workspaces // [])[].workspace_id' 2>/dev/null)"
}

# ar_agent_revert <pane_id> <base> <detected>
# Remove our numbering from an agent (used by --clear and positions 10+). Reverts
# an auto-named agent to detection (which also sidesteps herdr's duplicate
# manual-name rejection when several agents share a base like "claude"); a
# genuinely user-named agent keeps its name.
ar_agent_revert() {
  local tid=$1 base=$2 detected=$3
  if [ -n "$detected" ] && [ "$base" = "$detected" ]; then
    "$HERDR" agent rename "$tid" --clear >/dev/null 2>&1 || true
  else
    "$HERDR" agent rename "$tid" "$base" >/dev/null 2>&1 || true
  fi
}

# ar_unpark_base <base> <detected> -> base with a stuck park-temp suffix removed.
# The two-phase swap below parks each agent at a UNIQUE temp "[N] <base> <tid>"
# then finalizes to "[N] <base>". If a finalize loses to herdr, the agent stays
# at the temp name; on the next pass ar_strip_prefix removes only "[N] " and the
# glued id becomes part of the base, freezing the agent. Recover the real base by
# dropping a trailing park token (" term_<hex>" or " <ws>:<pane>") ONLY when what
# remains is exactly the detected kind, so a real multi-word user name is untouched.
ar_unpark_base() {
  local base=$1 detected=$2 stripped
  [ -n "$detected" ] || { printf '%s' "$base"; return; }
  case "$base" in
    "$detected "*) ;;
    *) printf '%s' "$base"; return ;;
  esac
  case "${base##* }" in
    term_*|w[0-9]*:*) ;;
    *) printf '%s' "$base"; return ;;
  esac
  stripped=${base% *}
  if [ "$stripped" = "$detected" ]; then
    printf '%s' "$detected"
  else
    printf '%s' "$base"
  fi
}

# ar_version_lt <a> <b> -> 0 when dotted version a orders before b. Compares the
# first three numeric fields, treating a missing field as 0 ("0.8" = "0.8.0"), and
# reports "not less than" for anything non-numeric so an unparseable version never
# unlocks a version-gated path. Pure, so tests/test_prefix.sh exercises it directly.
ar_version_lt() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  local a="$1." b="$2." i=0 af bf
  while [ "$i" -lt 3 ]; do
    af=${a%%.*}; a=${a#*.}
    bf=${b%%.*}; b=${b#*.}
    [ -n "$af" ] || af=0
    [ -n "$bf" ] || bf=0
    case "$af$bf" in *[!0-9]*) return 1 ;; esac
    [ "$af" -lt "$bf" ] && return 0
    [ "$af" -gt "$bf" ] && return 1
    i=$(( i + 1 ))
  done
  return 1
}

# ar_herdr_version -> the running herdr's dotted version ("0.8.0"), or rc 1 when
# it cannot be read. `herdr --version` prints "herdr <version>"; take the first
# field shaped like a number and drop any trailing build metadata.
ar_herdr_version() {
  local out f
  out=$("$HERDR" --version 2>/dev/null) || return 1
  for f in $out; do
    case "$f" in
      [0-9]*.[0-9]*) printf '%s' "${f%%[!0-9.]*}"; return 0 ;;
    esac
  done
  return 1
}

# ar_agent_prefix_ok -> 0 when this herdr accepts "[N] <base>" as an agent name.
#
# herdr 0.7.5 added valid_agent_name (^[a-z][a-z0-9_-]{0,31}$, src/app/agents.rs)
# and now rejects anything else with `invalid_agent_name`, so a bracketed number
# is structurally impossible there -- every rename fails and the agent keeps
# whatever name it had. Agents are therefore numbered only below 0.7.5, and the
# prefixes are stripped at or above it, which also cleans up "[N] " names left
# stuck by an older herdr + older plugin (see ar_renumber_agents). An unreadable
# version is treated as restricted: refusing to number is recoverable, issuing
# renames herdr rejects is not.
#
# Workspace and tab renames are unaffected -- those labels are free-form.
ar_agent_prefix_ok() {
  local v
  v=$(ar_herdr_version) || return 1
  ar_version_lt "$v" "0.7.5"
}

# ar_agent_sort -> "priority" or "spaces" (grouped). herdr renders the agent panel
# in its agent_panel_sort order: "spaces"/"workspaces" (grouped by space) or
# "priority" (attention queue). cmd+alt+N follows that VISIBLE order, but the CLI
# (`agent list`, `api snapshot`) always returns the fixed grouped order and herdr
# exposes neither the panel's displayed order nor a resort event, so in "priority"
# mode we cannot know the order a static "[N]" would have to match. We therefore
# number agents only in grouped mode (where agent-list order IS the panel order)
# and strip the prefixes in "priority" mode (see ar_renumber_agents). herdr
# rewrites agent_panel_sort into config.toml the instant the sort is toggled, so
# the file is the live source of truth; default (key unset) is "spaces".
# A named session keeps its own config.toml beside its session.json, so the path
# comes from ar_herdr_session_dir; HERDR_CONFIG_FILE overrides it for testing.
ar_agent_sort() {
  local cfg="${HERDR_CONFIG_FILE:-$(ar_herdr_session_dir)/config.toml}" line
  line=$(grep -E '^[[:space:]]*agent_panel_sort[[:space:]]*=' "$cfg" 2>/dev/null | tail -n1)
  case "${line#*=}" in
    *priority*) printf 'priority' ;;
    *)          printf 'spaces' ;;
  esac
}

# Agents: cmd+alt+N indexes agent-list order. The display label is .name (what
# agent rename sets) falling back to .agent when unnamed. Count EVERY agent-list
# row in order, including a degraded row whose .agent is null (it stays in the
# list and is still reached by cmd+alt+N), so our counter stays in sync with
# herdr's sidebar. agent rename REJECTS a manual name already held by another
# terminal, so positions 1-9 (unique "[N]" targets) use a two-phase park (unique
# temps first, then finals) and positions 10+ (bare, non-unique) revert individually.
#
# The rename target is .pane_id, the only form every supported herdr resolves:
# 0.7.5's resolve_agent_target (src/app/terminal_targets.rs) accepts a current
# pane id or a unique agent name and no longer matches .terminal_id, which the
# older resolve_terminal_target tried first. .terminal_id stays as a fallback for
# a row that somehow carries no pane id.
#
# Numbering is skipped (and existing prefixes stripped) in two cases: a herdr that
# rejects bracketed agent names (ar_agent_prefix_ok) and a "priority"-sorted panel,
# whose order is dynamic and API-invisible (ar_agent_sort). Both strip exactly the
# way --clear does.
ar_renumber_agents() {
  local json rows tid label detected base want i=0 n j strip=0
  if [ "${AR_HAVE_SNAPSHOT:-0}" = "1" ]; then
    json="$AR_SNAP_AGENTS_JSON"
  else
    json=$("$HERDR" agent list 2>/dev/null) || return 0
  fi
  [ -n "$json" ] || return 0
  rows=$(printf '%s' "$json" | jq -r '
    (.result.agents // .agents // [])[]
    | [ (.pane_id // .terminal_id // ""), (.name // .agent // ""), (.agent_session.agent // .agent // "") ] | @tsv' 2>/dev/null)
  [ -n "$rows" ] || return 0

  # Revert to detection (strip our "[N]") on uninstall, on a herdr that rejects
  # bracketed agent names, OR whenever the agent panel is priority-sorted: a
  # fixed-order number can only be wrong against a queue we cannot observe.
  # Grouped mode on an older herdr falls through to numbering below.
  if [ "$CLEAR" = "1" ]; then
    strip=1
  elif ! ar_agent_prefix_ok; then
    strip=1
  elif [ "$(ar_agent_sort)" = "priority" ]; then
    strip=1
  fi
  if [ "$strip" = "1" ]; then
    while IFS=$'\t' read -r tid label detected; do
      [ -n "$tid" ] || continue
      base=$(ar_strip_prefix "$label")
      base=$(ar_unpark_base "$base" "$detected")
      [ "$base" = "$label" ] && continue
      ar_agent_revert "$tid" "$base" "$detected"
    done <<< "$rows"
    return 0
  fi

  local -a P_TID P_WANT
  while IFS=$'\t' read -r tid label detected; do
    [ -n "$tid" ] || continue
    i=$(( i + 1 ))
    base=$(ar_strip_prefix "$label")
    base=$(ar_unpark_base "$base" "$detected")
    # A slot with no name AND no detected kind still counts toward the position
    # but we can't form "[N] base" for it -- leave it until herdr names it.
    [ -n "$base" ] || continue
    want=$(ar_desired "$i" "$base")
    [ "$want" = "$label" ] && continue
    if [ "$i" -ge 1 ] && [ "$i" -le 9 ]; then
      P_TID+=("$tid"); P_WANT+=("$want")
    else
      ar_agent_revert "$tid" "$base" "$detected"
    fi
  done <<< "$rows"

  n=${#P_TID[@]}
  [ "$n" -gt 0 ] || return 0
  if [ "$n" -gt 1 ]; then
    for (( j = 0; j < n; j++ )); do
      "$HERDR" agent rename "${P_TID[$j]}" "${P_WANT[$j]} ${P_TID[$j]}" >/dev/null 2>&1 || true
    done
  fi
  for (( j = 0; j < n; j++ )); do
    "$HERDR" agent rename "${P_TID[$j]}" "${P_WANT[$j]}" >/dev/null 2>&1 || true
  done
}

# ar_wait_tab_gone <tab_id> - block (bounded ~3s) until a just-closed tab has left
# herdr's model, so the reconcile that follows never numbers by a stale list.
# herdr keeps a closing tab in `tab list` until its pane finishes tearing down;
# the tab.closed event fires while it is still listed, so an immediate reconcile
# would find every number already correct and change nothing. Waiting for the id
# to disappear turns that race into a settled read.
ar_wait_tab_gone() {
  local t=$1 i=0 raw
  [ -n "$t" ] || return 0
  while [ "$i" -lt 60 ]; do
    raw=$("$HERDR" tab get "$t" 2>/dev/null) || return 0
    [ -n "$raw" ] || return 0
    printf '%s' "$raw" | jq -e '(.result.tab // .tab) | has("tab_id")' >/dev/null 2>&1 || return 0
    i=$(( i + 1 ))
    sleep 0.05 2>/dev/null || return 0
  done
}

# ======================================================================
# passes
# ======================================================================

# Full reconcile of every list, gated by the toggles. --clear ignores the toggles
# and strips everything (the uninstall path).
ar_reconcile() {
  local wsjson snap
  # A reset deletes the target tab's state once (under the lock) so it re-adopts.
  if [ -n "${AR_FORCE_TAB:-}" ] && [ -z "${AR_FORCE_DONE:-}" ]; then
    ar_state_del "$AR_FORCE_TAB"
    AR_FORCE_DONE=1
  fi
  # One `herdr api snapshot` (herdr >= 0.7.2) carries the workspace, tab, pane,
  # and agent lists in a single socket round-trip, in the SAME order and with the
  # same fields as the individual `... list` commands -- and numbering reads array
  # order, so that equal ordering is load-bearing (verified against a live herdr).
  # It replaces the old per-reconcile fan-out of `workspace list` + `pane list` +
  # `agent list` + one `tab list` per workspace. We reshape each slice into the
  # `{result:{...}}` envelope the existing jq already expects and cache the tab /
  # agent slices for ar_reconcile_tabs / ar_renumber_agents. Any failure (older
  # herdr with no `api snapshot`, a socket hiccup) falls back to the separate list
  # calls, so this never raises the plugin's min herdr version. Per-tab foreground
  # detection (`pane process-info`) is unaffected -- the snapshot carries panes but
  # not each pane's foreground process, so naming still samples per named tab.
  AR_HAVE_SNAPSHOT=0
  AR_SNAP_TABS_JSON=""
  AR_SNAP_AGENTS_JSON=""
  snap=$("$HERDR" api snapshot 2>/dev/null) || snap=""
  if [ -n "$snap" ] && printf '%s' "$snap" \
       | jq -e '(.result.snapshot // .snapshot).workspaces' >/dev/null 2>&1; then
    AR_HAVE_SNAPSHOT=1
    wsjson=$(printf '%s' "$snap" | jq -c \
      '{result:{workspaces:((.result.snapshot // .snapshot).workspaces // [])}}' 2>/dev/null)
    AR_SNAP_TABS_JSON=$(printf '%s' "$snap" | jq -c \
      '{result:{tabs:((.result.snapshot // .snapshot).tabs // [])}}' 2>/dev/null)
    AR_SNAP_AGENTS_JSON=$(printf '%s' "$snap" | jq -c \
      '{result:{agents:((.result.snapshot // .snapshot).agents // [])}}' 2>/dev/null)
    if [ "$CLEAR" != "1" ] && [ "$NAME_TABS" = "1" ]; then
      AR_PANES_JSON=$(printf '%s' "$snap" | jq -c \
        '{result:{panes:((.result.snapshot // .snapshot).panes // [])}}' 2>/dev/null)
      [ -n "$AR_PANES_JSON" ] || AR_PANES_JSON='{"result":{"panes":[]}}'
    fi
  else
    wsjson=$("$HERDR" workspace list 2>/dev/null) || wsjson=""
    if [ "$CLEAR" != "1" ] && [ "$NAME_TABS" = "1" ]; then
      AR_PANES_JSON=$("$HERDR" pane list 2>/dev/null) || AR_PANES_JSON='{"result":{"panes":[]}}'
    fi
  fi
  if [ "$CLEAR" = "1" ] || [ "$AUTO_INDEX" = "1" ]; then
    ar_renumber_workspaces "$wsjson"
  fi
  if [ "$CLEAR" = "1" ] || [ "$AUTO_INDEX" = "1" ] || [ "$NAME_TABS" = "1" ]; then
    AR_SEEN_TABS=""
    ar_reconcile_tabs "$wsjson"
    [ "$NAME_TABS" = "1" ] && [ -n "$AR_SEEN_TABS" ] && ar_state_prune $AR_SEEN_TABS
  fi
  if [ "$CLEAR" = "1" ] || [ "$AUTO_INDEX" = "1" ]; then
    ar_renumber_agents
  fi
}

# Fast path for the shell hooks: rename only the current tab (no cross-tab work).
# preexec passes the command line; precmd (back at the prompt) names by the shell.
# Preserves the existing "[N]" prefix when AUTO_INDEX is on, drops it when off.
#
# preexec has two modes. Default: trust the command line's first word as the
# program (accurate for external commands and expanded aliases). Sampled
# (AR_FAST_SAMPLE=1, the hook classified the word as a shell construct --
# function/builtin/reserved/typo): the word is NOT the program, so read the
# pane's real foreground process instead. An instant construct has exited by
# sample time (leader = the shell -> name already "zsh" -> no rename, no
# flicker); a construct wrapping nvim samples as nvim. On sampling failure
# rename nothing -- never guess.
ar_fast_once() {
  local tab="${HERDR_TAB_ID:-}"
  [ -n "$tab" ] || return 0
  local prog="" cmd="" info name label raw prefix slabel enabled auto want
  if [ "$MODE" = "preexec" ]; then
    if [ "${AR_FAST_SAMPLE:-}" = "1" ]; then
      info=$(ar_pane_program "${HERDR_PANE_ID:-}") || return 0
      IFS=$'\t' read -r prog cmd <<< "$info"
      [ -n "$prog" ] || return 0
    else
      cmd="${AR_FAST_ARG:-}"
      prog="${cmd%% *}"; prog="${prog##*/}"
    fi
  fi
  name=$(ar_format "$prog" "$cmd")
  # A failed `tab get` must NOT look like an empty label (which would read as a
  # placeholder and clobber a hand-picked name). Only proceed on a real tab object.
  raw=$("$HERDR" tab get "$tab" 2>/dev/null) || return 0
  [ -n "$raw" ] || return 0
  printf '%s' "$raw" | jq -e '(.result.tab // .tab) | has("label")' >/dev/null 2>&1 || return 0
  label=$(printf '%s' "$raw" | jq -r '(.result.tab // .tab).label // ""' 2>/dev/null)

  if [ "$AUTO_INDEX" = "1" ]; then prefix=$(ar_index_prefix "$label"); else prefix=""; fi
  slabel=$(ar_strip_prefix "$label")
  ar_name_eligible "$tab" "$slabel" || return 0
  # Empty is a real answer under HIDE_SHELL (name the tab nothing, keeping the
  # number alone when there is one); anywhere else it means we have no name.
  if [ -z "$name" ]; then
    [ "${HIDE_SHELL:-0}" = "1" ] || return 0
    prefix="${prefix% }"                        # "[3] " -> "[3]", "" stays ""
  fi
  want="${prefix}${name}"
  if [ "$want" != "$label" ]; then
    "$HERDR" tab rename "$tab" "$want" >/dev/null 2>&1 || return 0
  fi
  ar_state_set "$tab" "$name" true
}

# Coalesce bursts: only the lock holder works; contenders raise the rerun flag
# and exit, and the holder loops until no new work arrives (bounded). A fast pass
# escalates to a full reconcile the moment any rerun is seen -- a full reconcile
# is a superset of the single-tab rename, so a structural event that raced a
# preexec is still handled (and its lost rename recovered) inside this loop.
ar_run() {
  local want="${1:-full}"
  ar_lock || { : > "$RERUN_FLAG" 2>/dev/null || true; exit 0; }
  trap 'ar_unlock' EXIT
  local guard=0
  while :; do
    rm -f "$RERUN_FLAG" 2>/dev/null || true
    if [ "$want" = "fast" ]; then ar_fast_once; else ar_reconcile; fi
    want=full                              # any re-pass is a full reconcile
    guard=$(( guard + 1 ))
    [ "$guard" -ge 8 ] && break
    [ -f "$RERUN_FLAG" ] && continue
    ar_unlock
    [ -f "$RERUN_FLAG" ] || break
    ar_lock || break
  done
}

# ======================================================================
# entry point
# ======================================================================
# ar_main holds everything that must NOT run when this file is sourced for tests:
# the jq/herdr prerequisite checks, the config + naming load, the toggle
# defaults, the mode parse, and the dispatch.
ar_main() {
  set -o pipefail

  command -v jq >/dev/null 2>&1 || exit 0
  command -v "$HERDR" >/dev/null 2>&1 || exit 0
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

  # Config overrides must load BEFORE naming.sh (its defaults only fill unset vars).
  [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
  . "$AR_ROOT/naming.sh"

  # Feature toggles (default on). A config value of 0 wins because := only fills
  # an unset/empty var.
  : "${NAME_TABS:=1}"
  : "${AUTO_INDEX:=1}"

  MODE="${1:-event}"
  CLEAR=0
  case "$MODE" in --clear|clear) CLEAR=1 ;; esac

  case "$MODE" in
    preexec)
      [ "$NAME_TABS" = "1" ] || exit 0
      AR_FAST_ARG="${2:-}"                    # the command line being run
      # $3 = "shell": the hook resolved the command word to a shell construct
      # (function/builtin/reserved/typo), which never becomes the foreground
      # process. Give the construct a moment to finish or spawn its real
      # program, then name by what actually holds the pane (see ar_fast_once).
      # The settle sleep runs BEFORE ar_run so the lock is never held asleep.
      if [ "${3:-}" = "shell" ]; then
        AR_FAST_SAMPLE=1
        sleep 0.2 2>/dev/null || true
      fi
      ar_run fast
      ;;
    precmd)
      [ "$NAME_TABS" = "1" ] || exit 0
      # Optional 2nd arg = the calling shell's own name, so a bare prompt in a
      # bash/fish pane reads "bash"/"fish" instead of $SHELL (the login shell).
      # Absent (a bare `precmd` from an older caller) -> keep the SHELL_NAME
      # default from naming.sh/config. ar_format returns SHELL_NAME for an empty
      # program, which is exactly the bare-prompt case the precmd fast path hits.
      [ -n "${2:-}" ] && SHELL_NAME="$2"
      ar_run fast
      ;;
    reset)
      # Prefer the documented action inputs (HERDR_TAB_ID, then the context JSON);
      # fall back to the focused tab so reset still targets something.
      tab="${HERDR_TAB_ID:-}"
      if [ -z "$tab" ] && [ -n "${HERDR_PLUGIN_CONTEXT_JSON:-}" ]; then
        tab=$(printf '%s' "$HERDR_PLUGIN_CONTEXT_JSON" \
          | jq -r '.tab.tab_id // .tab.id // .tab_id // empty' 2>/dev/null)
      fi
      if [ -z "$tab" ]; then
        tab=$("$HERDR" tab list 2>/dev/null \
          | jq -r 'first((.result.tabs // .tabs)[] | select(.focused) | .tab_id) // empty' 2>/dev/null)
      fi
      [ -n "$tab" ] && [ "$NAME_TABS" = "1" ] && AR_FORCE_TAB="$tab"
      ar_run full
      ;;
    clear|--clear)
      ar_run full                            # CLEAR=1 already set above
      ;;
    tab.closed)
      ar_wait_tab_gone "${HERDR_TAB_ID:-}"   # settle before the reconcile
      ar_run full                            # renumbers survivors; ar_state_prune drops the closed tab
      ;;
    *)
      ar_run full                            # any other herdr event
      ;;
  esac
}

# Execute only when run as a script, never when sourced (the test suite sources
# this file to unit-test the pure helpers). BASH_SOURCE[0] == $0 iff executed.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  ar_main "$@"
fi
