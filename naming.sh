# naming.sh - pure, herdr-free name computation for herdr-automatic-rename.
#
# Sourced by automatic-rename.sh. Every function is string-in / string-out (no herdr
# or filesystem calls) so the logic is unit-testable on its own (see
# tests/test_naming.sh). Targets bash 3.2 (macOS /bin/bash): no associative
# arrays, no namerefs. Functions share the ar_ prefix with the engine, which
# calls ar_format across the module seam.
#
# Naming rule: a tab is named after its foreground program (nvim, claude, git,
# ...). At a bare prompt, or while a quick throwaway command runs, it shows the
# shell name (e.g. zsh) instead. With SHOW_CWD=1 the cwd basename replaces that
# shell component or follows a program label. Loosely modeled on tmux-window-name.
#
# Every list below is guarded with `declare -p` rather than `${VAR+x}`, so
# clearing one in config.sh (e.g. IGNORED_PROGRAMS=()) actually takes effect:
# `${VAR+x}` reports a zero-element array as unset and would overwrite it.

# ---- configurable knobs (override in config.sh / $HERDR_AUTOMATIC_RENAME_CONFIG) ----
: "${MAX_NAME_LEN:=20}"        # truncate the final label to this many chars
: "${SHOW_PROGRAM_ARGS:=0}"   # 1 = regular programs show their full command line; 0 = name only
: "${SHOW_CWD:=1}"            # 1 = include the active pane's cwd basename in the label
: "${ICONS_ENABLED:=0}"       # prepend a Nerd Font glyph (needs a Nerd Font)
: "${ICON_STYLE:=name_and_icon}"  # name_and_icon (icon+name) | name (name only) | icon (icon only)

# Name shown at a bare prompt (no foreground program), and while an
# IGNORED_PROGRAMS command runs, so the tab holds steady instead of flickering.
: "${SHELL_NAME:=${SHELL##*/}}"
: "${SHELL_NAME:=zsh}"

# 1 = suppress the shell component at a bare prompt, for an explicit SHELLS
# entry, or for an IGNORED_PROGRAMS command. A cwd component remains visible.
# Without one, the empty label hands the tab back to herdr, which renders its own
# number; with AUTO_INDEX=1 the label keeps only the jump number ("[3]").
: "${HIDE_SHELL:=0}"

# Foreground processes that mean "a shell prompt" -> shown by their own name.
declare -p SHELLS >/dev/null 2>&1 || SHELLS=(zsh bash sh fish dash ksh)

# Programs shown by bare name, without command-line args (i.e. with
# SHOW_PROGRAM_ARGS=1, which is what makes this list visible). Coding agents are
# included so an agent tab reads as "claude" rather than its full invocation.
#
# The agent entries are the executable names herdr itself detects as interactive
# agents (src/detect/mod.rs, herdr 0.8.0). Two differ from herdr's --kind id and
# both spellings are listed: cursor-agent (kind "cursor") and kiro-cli (kind
# "kiro"). aider is not a herdr agent kind but is a real agent, so it stays.
declare -p NAME_ONLY_PROGRAMS >/dev/null 2>&1 || NAME_ONLY_PROGRAMS=(nvim vim vi view gvim git lazygit gitui lazydocker \
  claude codex aider pi gemini cursor cursor-agent devin agy antigravity cline omp mastracode opencode \
  copilot kimi kiro kiro-cli droid amp grok hermes kilo qodercli)

# Quick tools that should not take over the tab name: while one runs the tab
# keeps showing the shell (SHELL_NAME) so it does not flicker.
declare -p IGNORED_PROGRAMS >/dev/null 2>&1 || IGNORED_PROGRAMS=(ls eza ll la cd z zoxide cat bat less more echo pwd clear which man head tail wc cp mv rm mkdir touch fzf sudo doas)

# Ordered, complete `sed -E` programs applied to the final display string.
declare -p SUBSTITUTE_SETS >/dev/null 2>&1 || SUBSTITUTE_SETS=(
  's|.*ipython([32])|ipython\1|'
  's|.*poetry shell.*|poetry|'
)

# Exact program-name renames: "<program>=<label>" pairs. A matching foreground
# program is shown as <label> regardless of its category (e.g. "clx=hn" makes a
# clx tab read "hn"). Takes priority over every rule except the bare-prompt shell
# name. Set this in config.sh, e.g. PROGRAM_ALIASES=("clx=hn" "lazygit=lg").
declare -p PROGRAM_ALIASES >/dev/null 2>&1 || PROGRAM_ALIASES=()

# ---- helpers ----

# ar_in_list <needle> <list items...>
ar_in_list() {
  local n=$1 e
  shift
  for e in "$@"; do [ "$e" = "$n" ] && return 0; done
  return 1
}

# ar_cwd_basename <cwd> -> the final path component, or empty when unavailable.
ar_cwd_basename() {
  local cwd=$1 home=${HOME:-}
  [ -n "$cwd" ] || return 0
  while [ "$cwd" != "/" ] && [ "${cwd%/}" != "$cwd" ]; do cwd=${cwd%/}; done
  while [ "$home" != "/" ] && [ "${home%/}" != "$home" ]; do home=${home%/}; done
  [ -n "$home" ] && [ "$cwd" = "$home" ] && { printf '~'; return 0; }
  [ "$cwd" = "/" ] && { printf '/'; return 0; }
  printf '%s' "${cwd##*/}"
}

# ar_alias <program> -> its PROGRAM_ALIASES label, or empty when unaliased.
ar_alias() {
  local n=$1 pair
  [ -n "$n" ] || return 0
  for pair in "${PROGRAM_ALIASES[@]}"; do
    case "$pair" in
      "$n="*) printf '%s' "${pair#*=}"; return 0 ;;
    esac
  done
}

# ar_subst <string> -> string with SUBSTITUTE_SETS applied in order
ar_subst() {
  local s=$1 expr
  for expr in "${SUBSTITUTE_SETS[@]}"; do
    s=$(printf '%s' "$s" | sed -E "$expr")
  done
  printf '%s' "$s"
}

# ar_icon <program> -> a Nerd Font glyph, or empty. Edit freely.
#
# The glyphs below are literal Private Use Area characters and render as blank
# boxes without a Nerd Font installed. They also went missing once: every arm
# shipped as `printf ''` from this file's first commit through v0.2.1, which made
# ICONS_ENABLED=1 a silent no-op (issue #3). Each arm carries its codepoint in a
# comment so a stripped glyph can be restored, and tests/test_naming.sh asserts
# the exact bytes, so the same loss fails the suite instead of passing quietly.
#
# An unmatched program returns empty on purpose: ar_format only prepends when the
# glyph is non-empty, so an unknown program keeps a clean, text-only label.
ar_icon() {
  case "$1" in
    nvim)                             printf '' ;;  # U+E6AE nf-custom-neovim
    vim|vi|view|gvim)                 printf '' ;;  # U+E62B nf-custom-vim
    git|lazygit|gitui)                printf '' ;;  # U+E702 nf-dev-git
    node|npm|npx|yarn|pnpm|deno|bun)  printf '' ;;  # U+E718 nf-dev-nodejs_small
    python|python3|ipython|ipython3)  printf '' ;;  # U+E73C nf-dev-python
    docker|lazydocker)                printf '' ;;  # U+F308 nf-linux-docker
    cargo|rustc|rustup)               printf '' ;;  # U+E7A8 nf-dev-rust
    go)                               printf '' ;;  # U+E627 nf-seti-go
    claude|codex|aider|pi|gemini)     printf '󰚩' ;;  # U+F06A9 nf-md-robot
    cursor|cursor-agent|devin|cline)  printf '󰚩' ;;  # U+F06A9 nf-md-robot
    agy|antigravity|omp|mastracode)   printf '󰚩' ;;  # U+F06A9 nf-md-robot
    opencode|copilot|kimi|droid|amp)  printf '󰚩' ;;  # U+F06A9 nf-md-robot
    kiro|kiro-cli|grok|hermes|kilo)   printf '󰚩' ;;  # U+F06A9 nf-md-robot
    qodercli)                         printf '󰚩' ;;  # U+F06A9 nf-md-robot
    *) ;;
  esac
}

# ar_format <program|""> <cmdline> [cwd] -> final tab label
#   program == "" means a bare prompt (name by the shell).
ar_format() {
  local prog=$1 cmdline=$2 cwd=${3:-} cwd_name="" name="" ic aliased is_shell=0
  aliased=$(ar_alias "$prog")
  if [ -z "$prog" ]; then
    name=$SHELL_NAME; is_shell=1
  elif [ -n "$aliased" ]; then
    name=$aliased                             # user rename (PROGRAM_ALIASES) wins
  elif ar_in_list "$prog" "${SHELLS[@]}"; then
    name=$prog; is_shell=1                    # a shell shows its own name (zsh)
  elif ar_in_list "$prog" "${IGNORED_PROGRAMS[@]}"; then
    name=$SHELL_NAME; is_shell=1              # quick tools: keep showing the shell
  elif ar_in_list "$prog" "${NAME_ONLY_PROGRAMS[@]}"; then
    name="$(ar_subst "$prog")"               # nvim, claude, ...: just the name
  elif [ "${SHOW_PROGRAM_ARGS:-1}" = "1" ] && [ -n "$cmdline" ]; then
    name="$(ar_subst "$cmdline")"
  else
    name="$(ar_subst "$prog")"
  fi

  if [ "${SHOW_CWD:-1}" = "1" ]; then
    cwd_name=$(ar_cwd_basename "$cwd")
    [ -n "$cwd_name" ] && [ "$is_shell" = "1" ] && name=$cwd_name
  fi

  # HIDE_SHELL: drop the shell component, but keep an independent cwd label when
  # one is available. An explicit PROGRAM_ALIASES entry for a shell (e.g.
  # "fish=sh") is a name the user asked for by hand, so it survives too.
  if [ "${HIDE_SHELL:-0}" = "1" ] && [ "$is_shell" = "1" ] && [ -z "$cwd_name" ]; then
    printf ''
    return 0
  fi

  if [ "${ICONS_ENABLED:-0}" = "1" ] && [ -n "$prog" ]; then
    ic=$(ar_icon "$prog")
    if [ -n "$ic" ]; then
      case "${ICON_STYLE:-name_and_icon}" in
        icon)            name=$ic ;;          # icon only
        name)            : ;;                 # name only (icon suppressed)
        name_and_icon|*) name="$ic $name" ;;  # icon + name (default)
      esac
    fi
  fi

  if [ -n "$cwd_name" ] && [ "$is_shell" != "1" ]; then
    name="$name:$cwd_name"
  fi

  # Truncate by Unicode codepoint, not byte. bash's ${#name} / ${name:0:$max}
  # count bytes under a C/POSIX locale (herdr may launch plugins with no LC_*),
  # which would slice a multibyte char in half and emit mojibake. jq (already a
  # hard dependency of this plugin) always reads input as UTF-8, so it slices on
  # codepoint boundaries regardless of the ambient locale; fall back to the byte
  # cut only if jq is somehow unavailable.
  local max=${MAX_NAME_LEN:-20}
  if [ "${#name}" -gt "$max" ]; then
    local truncated
    truncated=$(printf '%s' "$name" | jq -Rrs --argjson n "$max" '.[:$n]' 2>/dev/null || printf '')
    if [ -n "$truncated" ]; then
      name=$truncated
    else
      name=${name:0:$max}
    fi
  fi
  printf '%s' "$name"
}
