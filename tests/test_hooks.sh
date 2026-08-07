#!/usr/bin/env bash
# Behavior tests for the shell hooks. bash is always exercised; zsh and fish are
# exercised only when installed (skipped, not failed, otherwise). Each hook is
# sourced against the real repo layout, so we verify it resolves the engine next
# to itself rather than at any hard-coded path.

here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
REPO=$(cd "$here/.." && pwd)

# ---- bash ----
got=$(HERDR_PANE_ID=x HAL_HOOK="$REPO/shell/hook.bash" /usr/bin/env bash -c 'source "$HAL_HOOK"; echo "$_har_bin"')
check "bash: self-locates engine next to hook" "$REPO/automatic-rename.sh" "$got"

got=$(HERDR_PANE_ID=x HAL_HOOK="$REPO/shell/hook.bash" /usr/bin/env bash -c \
  'source "$HAL_HOOK"; source "$HAL_HOOK"; printf "%s\n" "$PROMPT_COMMAND" | grep -c _har_precmd_wrap')
check "bash: double-source adds PROMPT_COMMAND once" "1" "$got"

# Trap behavior only makes sense in an interactive shell (the only place a hook
# is sourced). Non-interactive `/usr/bin/env bash -c` has different DEBUG-trap scoping, so we
# simulate a real .bashrc: set a DEBUG trap, source the hook after it, then run a
# command. The pre-existing trap must still fire (proof it was not clobbered).
_rc=$(mktemp "${TMPDIR:-/tmp}/hal-rc.XXXXXX")
cat >"$_rc" <<EOF
trap 'echo KEEP_FIRED' DEBUG
source "$REPO/shell/hook.bash"
EOF
got=$(printf 'true\nexit\n' | HERDR_PANE_ID=x /usr/bin/env bash --rcfile "$_rc" -i 2>&1)
rm -f "$_rc"
check_contains "bash: never clobbers a pre-existing DEBUG trap" "$got" "KEEP_FIRED"

got=$(HERDR_PANE_ID=x HAL_HOOK="$REPO/shell/hook.bash" /usr/bin/env bash -c \
  'preexec_functions=(); source "$HAL_HOOK"; printf "%s " "${preexec_functions[@]}"')
check_contains "bash: cooperates with a preexec framework" "$got" "_har_preexec"

got=$(HAL_HOOK="$REPO/shell/hook.bash" /usr/bin/env bash -c 'unset HERDR_PANE_ID; source "$HAL_HOOK"; echo "${_har_installed:-unset}"')
check "bash: no-ops outside a herdr pane" "unset" "$got"

# ---- command-word classification (both shells) ----
# Copy a hook into a sandbox repo layout whose engine is a stub that logs its
# argv, then call _har_preexec the way the shell would. A function word must
# carry the "shell" marker; an external command must not. The engine runs in a
# backgrounded subshell, so poll briefly for both log lines.
clsbox() { # <hook file> -> sets $CLS_SB, $CLS_LOG
  CLS_SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-cls.XXXXXX")
  CLS_LOG="$CLS_SB/args.log"; : >"$CLS_LOG"
  CLS_CWD="$CLS_SB/cwd with space"; mkdir -p "$CLS_CWD"
  CLS_CWD=$(cd "$CLS_CWD" && pwd)
  mkdir -p "$CLS_SB/shell"
  cp "$REPO/shell/$1" "$CLS_SB/shell/"
  printf '#!/usr/bin/env bash\nprintf "argc=%%s|1=<%%s>|2=<%%s>|3=<%%s>|4=<%%s>\\n" "$#" "${1-}" "${2-}" "${3-}" "${4-}" >> "%s"\n' "$CLS_LOG" >"$CLS_SB/automatic-rename.sh"
  chmod +x "$CLS_SB/automatic-rename.sh"
}
clswait() { # [line count] -- poll until the log is complete (or ~1s passes)
  local want=${1:-3}
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ "$(grep -c . "$CLS_LOG" 2>/dev/null)" -ge "$want" ] && break
    sleep 0.05
  done
  cat "$CLS_LOG"
}

clsbox hook.bash
HERDR_PANE_ID=x HAL_HOOK="$CLS_SB/shell/hook.bash" HAL_CWD="$CLS_CWD" /usr/bin/env bash -c \
  'source "$HAL_HOOK"; cd "$HAL_CWD"; l() { :; }; _har_preexec "l"; _har_preexec "ls -a"; _har_precmd; wait' 2>/dev/null
got=$(clswait)
check_contains "bash: function passes cwd + shell marker" "$got" "argc=4|1=<preexec>|2=<l>|3=<$CLS_CWD>|4=<shell>"
check_contains "bash: external passes cwd" "$got" "argc=3|1=<preexec>|2=<ls -a>|3=<$CLS_CWD>|4=<>"
check_contains "bash: precmd passes cwd" "$got" "argc=3|1=<precmd>|2=<bash>|3=<$CLS_CWD>|4=<>"
rm -rf "$CLS_SB"

if command -v zsh >/dev/null 2>&1; then
  clsbox hook.zsh
  HERDR_PANE_ID=x HAL_HOOK="$CLS_SB/shell/hook.zsh" HAL_CWD="$CLS_CWD" zsh -c \
    'source "$HAL_HOOK"; cd "$HAL_CWD"; function l() { :; }; _har_preexec l l l; _har_preexec "ls -a" "ls -a" "ls -a"; _har_precmd; wait' 2>/dev/null
  got=$(clswait)
  check_contains "zsh: function passes cwd + shell marker" "$got" "argc=4|1=<preexec>|2=<l>|3=<$CLS_CWD>|4=<shell>"
  check_contains "zsh: external passes cwd" "$got" "argc=3|1=<preexec>|2=<ls -a>|3=<$CLS_CWD>|4=<>"
  check_contains "zsh: precmd passes cwd" "$got" "argc=3|1=<precmd>|2=<zsh>|3=<$CLS_CWD>|4=<>"
  rm -rf "$CLS_SB"
else
  echo "# skip: zsh not installed"
fi

# fish classifies with `type --type`, where an external command reads "file".
# Use /usr/bin/env (not bare ls): fish wraps ls in a color function, and a
# function word is exactly what must take the sampled path. /usr/bin/env is
# portable across NixOS (no /bin) and standard Linux.
if command -v fish >/dev/null 2>&1; then
  clsbox hook.fish
  HERDR_PANE_ID=x HAL_HOOK="$CLS_SB/shell/hook.fish" HAL_CWD="$CLS_CWD" fish -c \
    'source "$HAL_HOOK"; cd "$HAL_CWD"; function l; end; _har_preexec "l"; _har_preexec "/usr/bin/env -a"; _har_precmd' 2>/dev/null
  got=$(clswait)
  check_contains "fish: function passes cwd + shell marker" "$got" "argc=4|1=<preexec>|2=<l>|3=<$CLS_CWD>|4=<shell>"
  check_contains "fish: external passes cwd" "$got" "argc=3|1=<preexec>|2=</usr/bin/env -a>|3=<$CLS_CWD>|4=<>"
  check_contains "fish: precmd passes cwd" "$got" "argc=3|1=<precmd>|2=<fish>|3=<$CLS_CWD>|4=<>"
  rm -rf "$CLS_SB"
else
  echo "# skip: fish not installed (classification)"
fi

# ---- zsh (if present) ----
if command -v zsh >/dev/null 2>&1; then
  got=$(HERDR_PANE_ID=x HAL_HOOK="$REPO/shell/hook.zsh" zsh -c 'source "$HAL_HOOK"; echo "$_har_bin"')
  check "zsh: self-locates engine next to hook" "$REPO/automatic-rename.sh" "$got"
  got=$(HERDR_PANE_ID=x HAL_HOOK="$REPO/shell/hook.zsh" zsh -c 'source "$HAL_HOOK"; echo ${preexec_functions[(r)_har_preexec]}')
  check "zsh: registers a preexec hook" "_har_preexec" "$got"
else
  echo "# skip: zsh not installed"
fi

# ---- fish (if present): at minimum, it must parse ----
if command -v fish >/dev/null 2>&1; then
  if fish -n "$REPO/shell/hook.fish" >/dev/null 2>&1; then rc=0; else rc=1; fi
  check_rc "fish: hook parses" 0 "$rc"
else
  echo "# skip: fish not installed"
fi

t_summary
