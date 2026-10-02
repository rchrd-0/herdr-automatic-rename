#!/usr/bin/env bash
# Unit tests for the JSON state store and the manual-rename opt-out state
# machine (ar_name_eligible). State lives under $XDG_STATE_HOME, which we point
# at a throwaway dir BEFORE sourcing the engine so STATE_DIR/STATE_FILE resolve
# there and the real state is never touched.

here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-state.XXXXXX")
export XDG_STATE_HOME="$SB/xdg"
. "$here/../automatic-rename.sh"
mkdir -p "$STATE_DIR"

# ---- ar_state_set / get / del ----
ar_state_set t1 nvim true
check "get auto after set"     "nvim" "$(ar_state_get t1 auto)"
check "get enabled after set"  "true" "$(ar_state_get t1 enabled)"
ar_state_set t1 claude false
check "overwrite auto"         "claude" "$(ar_state_get t1 auto)"
check "overwrite enabled"      "false"  "$(ar_state_get t1 enabled)"
ar_state_del t1
check "get after del"          "" "$(ar_state_get t1 auto)"

# ---- ar_state_prune: keep only listed tab ids ----
ar_state_set a x true
ar_state_set b y true
ar_state_set c z true
ar_state_prune a c
check "pruned entry gone"      "" "$(ar_state_get b auto)"
check "kept entry a"           "x" "$(ar_state_get a auto)"
check "kept entry c"           "z" "$(ar_state_get c auto)"

# Invalid stores heal to one object on the next write.
for invalid in '' 'broken' 'null' '[]' '42' '{} {}'; do
  printf '%s' "$invalid" > "$STATE_FILE"
  ar_state_set repaired nvim true
  check "invalid store heals ($invalid)" "nvim" "$(ar_state_get repaired auto)"
  check "invalid store becomes one object ($invalid)" "true" \
    "$(jq -s 'length == 1 and (.[0] | type == "object")' "$STATE_FILE")"
done
printf '\n' > "$STATE_FILE"
ar_state_set repaired zsh true
check "newline-only store heals" "zsh" "$(ar_state_get repaired auto)"

# A complete keep list and an absent one must leave the existing inode alone.
# A hard link witnesses replacement by temp+mv without relying on timestamp resolution.
rm -f "$STATE_FILE"
ar_state_set a x true
ar_state_set c z true
ln "$STATE_FILE" "$SB/original-state"
ar_state_prune a c
check "unchanged prune preserves file" "yes" \
  "$([ "$STATE_FILE" -ef "$SB/original-state" ] && printf yes || printf no)"
ar_state_prune
check "empty prune preserves records" "x" "$(ar_state_get a auto)"
check "empty prune preserves file" "yes" \
  "$([ "$STATE_FILE" -ef "$SB/original-state" ] && printf yes || printf no)"

# Inject read/process failures without relying on filesystem privileges.
printf '{"a":{"auto":"x","enabled":true},"c":{"auto":"z","enabled":true}}\n' > "$STATE_FILE"
before=$(cat "$STATE_FILE")
cat() { [ "$1" = "$STATE_FILE" ] && return 1; command cat "$@"; }
ar_state_set b y true
check_rc "unreadable store refuses write" 1 $?
ar_state_del a
ar_state_prune c
unset -f cat
check "unreadable store survives all writers" "$before" "$(cat "$STATE_FILE")"
jq() { return 137; }
ar_state_set b y true
check_rc "crashed jq refuses write" 1 $?
ar_state_del a
ar_state_prune c
unset -f jq
check "crashed jq preserves valid store" "$before" "$(cat "$STATE_FILE")"

# Fail only the initial validation: a later successful jq must not write over
# valid state using an empty base produced by an invocation or compile failure.
for jq_status in 2 3; do
  rm -f "$SB/jq-failed"
  jq() {
    if [ ! -e "$SB/jq-failed" ]; then
      : > "$SB/jq-failed"
      return "$jq_status"
    fi
    command jq "$@"
  }
  ar_state_set b y true
  check_rc "jq status $jq_status refuses write" 1 $?
  unset -f jq
  check "jq status $jq_status preserves valid store" "$before" "$(cat "$STATE_FILE")"
done

# ======================================================================
# ar_name_eligible state machine. rc 0 = eligible for auto-naming, 1 = leave it.
# ======================================================================
reset_state() { rm -f "$STATE_FILE"; }

# First sight of a placeholder label -> adopt (eligible), no state written yet.
reset_state
ar_name_eligible tX "3"; check_rc "first-seen placeholder adopts" 0 $?

# First sight of a hand-picked label -> opt out and remember it.
reset_state
ar_name_eligible tX "myproject"; check_rc "first-seen named opts out" 1 $?
check "opt-out recorded"       "false" "$(ar_state_get tX enabled)"

# We own it (enabled=true) and the base still matches -> keep updating.
reset_state
ar_state_set tX nvim true
ar_name_eligible tX "nvim"; check_rc "owned + unchanged stays eligible" 0 $?

# We own it but the base changed under us (user renamed) -> opt out.
reset_state
ar_state_set tX nvim true
ar_name_eligible tX "renamed-by-hand"; check_rc "owned + user-renamed opts out" 1 $?
check "owned->opt-out recorded" "false" "$(ar_state_get tX enabled)"

# We own it and the user cleared the label -> re-adopt.
reset_state
ar_state_set tX nvim true
ar_name_eligible tX ""; check_rc "owned + cleared re-adopts" 0 $?

# A HIDE_SHELL tab is owned with an EMPTY auto name. herdr handing its generated
# number back to such a label-less tab is not a hand rename -> stay eligible, so
# the tab is still named the moment a real program starts.
reset_state
ar_state_set tX "" true
ar_name_eligible tX "3"; check_rc "owned + empty auto keeps a number" 0 $?
ar_name_eligible tX "";  check_rc "owned + empty auto keeps empty"    0 $?
ar_name_eligible tX "notes"; check_rc "owned + empty auto still opts out on a name" 1 $?

# Opted out, still non-empty -> leave it.
reset_state
ar_state_set tX "" false
ar_name_eligible tX "3000"; check_rc "opted-out numeric stays out" 1 $?

# Opted out, but the label was cleared -> re-adopt.
reset_state
ar_state_set tX "" false
ar_name_eligible tX ""; check_rc "opted-out + cleared re-adopts" 0 $?

# reset action force: AR_FORCE_TAB wins over any opt-out.
reset_state
ar_state_set tX "" false
AR_FORCE_TAB=tX ar_name_eligible tX "still-named"; check_rc "force re-adopts" 0 $?

rm -rf "$SB" 2>/dev/null || true
t_summary
