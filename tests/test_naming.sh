#!/usr/bin/env bash
# Unit tests for naming.sh -- the pure, herdr-free name computation.
# String in / string out, so every rule is testable without a live herdr.

here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

# Pin the shell name so bare-prompt cases are deterministic regardless of $SHELL.
SHELL_NAME=zsh
. "$here/../naming.sh"

# ---- bare prompt / shells ----
check "bare prompt -> shell name"      "zsh"  "$(ar_format '' '')"
check "explicit shell shows own name"  "bash" "$(ar_format 'bash' 'bash')"
check "fish shell name"                "fish" "$(ar_format 'fish' '')"

# Cwd display replaces the shell component at a prompt.
check "shell with cwd -> directory" "foo" \
  "$(SHOW_CWD=1 ar_format 'zsh' '-zsh' '/Users/test/code/foo')"
check "cwd renderer strips trailing slash" "foo" \
  "$(ar_cwd_basename '/Users/test/code/foo/')"
check "cwd renderer preserves root" "/" "$(ar_cwd_basename '/')"
check "cwd renderer abbreviates home" "~" "$(HOME=/Users/test ar_cwd_basename '/Users/test')"
check "cwd renderer handles empty cwd" "" "$(ar_cwd_basename '')"

# ---- name-only programs (editors, agents, git) ----
check "nvim is name-only"    "nvim"   "$(ar_format 'nvim' 'nvim README.md')"
check "claude is name-only"  "claude" "$(ar_format 'claude' 'claude --dangerously-skip-permissions')"
check "git is name-only"     "git"    "$(ar_format 'git' 'git status')"
check "nvim with cwd -> program:directory" "nvim:foo" \
  "$(SHOW_CWD=1 ar_format 'nvim' 'nvim README.md' '/Users/test/code/foo')"
check "codex with cwd -> program:directory" "codex:foo" \
  "$(SHOW_CWD=1 ar_format 'codex' 'codex' '/Users/test/code/foo')"
check "SHOW_CWD disabled preserves program name" "nvim" \
  "$(SHOW_CWD=0 ar_format 'nvim' 'nvim README.md' '/Users/test/code/foo')"

# NAME_ONLY_PROGRAMS only bites with SHOW_PROGRAM_ARGS=1 (0 is the default and
# already renders bare names), so assert these there. Covers the agents herdr
# 0.8.0 detects, including the two whose executable differs from its --kind id.
check "grok is name-only"        "grok"         "$(SHOW_PROGRAM_ARGS=1 ar_format 'grok' 'grok --model x')"
check "agy is name-only"         "agy"          "$(SHOW_PROGRAM_ARGS=1 ar_format 'agy' 'agy --conversation 12')"
check "opencode is name-only"    "opencode"     "$(SHOW_PROGRAM_ARGS=1 ar_format 'opencode' 'opencode run x')"
check "cursor-agent name-only"   "cursor-agent" "$(SHOW_PROGRAM_ARGS=1 ar_format 'cursor-agent' 'cursor-agent -p x')"
check "kiro-cli is name-only"    "kiro-cli"     "$(SHOW_PROGRAM_ARGS=1 ar_format 'kiro-cli' 'kiro-cli chat')"
check "gemini is name-only"      "gemini"       "$(SHOW_PROGRAM_ARGS=1 ar_format 'gemini' 'gemini -p hi')"

# ---- ignored programs keep showing the shell ----
check "ls is ignored -> shell" "zsh" "$(ar_format 'ls' 'ls -la')"
check "cd is ignored -> shell" "zsh" "$(ar_format 'cd' 'cd ..')"
check "ignored command with cwd -> directory" "foo" \
  "$(SHOW_CWD=1 ar_format 'ls' 'ls -la' '/Users/test/code/foo')"

# ---- regular programs show their command line (SHOW_PROGRAM_ARGS default on) ----
SHOW_PROGRAM_ARGS=1
check "regular program shows cmdline"   "htop -d 5"    "$(ar_format 'htop' 'htop -d 5')"
check "regular program, args off -> name only" "psql" "$(SHOW_PROGRAM_ARGS=0 ar_format 'psql' 'psql -h db')"

# ---- program aliases win over category ----
PROGRAM_ALIASES=("clx=hn" "lazygit=lg")
check "alias clx->hn"       "hn" "$(ar_format 'clx' 'clx --nerdfonts')"
check "alias lazygit->lg"   "lg" "$(ar_format 'lazygit' 'lazygit')"
PROGRAM_ALIASES=()

# ---- substitutions ----
check "poetry shell -> poetry" "poetry"   "$(ar_format 'poetry' 'poetry shell')"
check "ipython3 collapse"      "ipython3" "$(ar_format 'ipython3' '/usr/bin/ipython3')"

# ---- truncation (MAX_NAME_LEN), counted by codepoint ----
check "truncates to MAX_NAME_LEN" "12345678901234567890" \
  "$(MAX_NAME_LEN=20 ar_format 'x' '123456789012345678901234567890')"
check "truncates combined cwd-aware label" "nvim:foo" \
  "$(SHOW_CWD=1 MAX_NAME_LEN=8 ar_format 'nvim' 'nvim README.md' '/Users/test/code/foobar')"
# A multibyte string must be cut on a codepoint boundary, never mid-byte.
check "multibyte truncation is clean" "ünïcödé" \
  "$(MAX_NAME_LEN=7 ar_format 'x' 'ünïcödéxxxxxxx')"

# ---- icons ----
# Expected glyphs are built from explicit UTF-8 byte escapes rather than pasted
# literals: bash 3.2 has no $'\uXXXX', and the Private Use Area codepoints these
# tests assert on are precisely what an editor or a copy-paste silently ate once
# before (ar_icon shipped with every arm returning "", so ICONS_ENABLED was a
# no-op through v0.2.1). Byte escapes cannot be eaten that way, so these tests
# still fail loudly if the glyphs ever vanish from naming.sh again.
g_nvim=$(printf '\xee\x9a\xae')    # U+E6AE nf-custom-neovim
g_vim=$(printf '\xee\x98\xab')     # U+E62B nf-custom-vim
g_git=$(printf '\xee\x9c\x82')     # U+E702 nf-dev-git
g_node=$(printf '\xee\x9c\x98')    # U+E718 nf-dev-nodejs_small
g_python=$(printf '\xee\x9c\xbc')  # U+E73C nf-dev-python
g_docker=$(printf '\xef\x8c\x88')  # U+F308 nf-linux-docker
g_cargo=$(printf '\xee\x9e\xa8')   # U+E7A8 nf-dev-rust
g_go=$(printf '\xee\x98\xa7')      # U+E627 nf-seti-go
g_agent=$(printf '\xf3\xb0\x9a\xa9')  # U+F06A9 nf-md-robot

# ar_icon must return a real glyph per program group, not the empty string.
check "ar_icon nvim"   "$g_nvim"   "$(ar_icon nvim)"
check "ar_icon vim"    "$g_vim"    "$(ar_icon vim)"
check "ar_icon gvim"   "$g_vim"    "$(ar_icon gvim)"
check "ar_icon git"    "$g_git"    "$(ar_icon git)"
check "ar_icon lazygit" "$g_git"   "$(ar_icon lazygit)"
check "ar_icon node"   "$g_node"   "$(ar_icon node)"
check "ar_icon pnpm"   "$g_node"   "$(ar_icon pnpm)"
check "ar_icon python3" "$g_python" "$(ar_icon python3)"
check "ar_icon docker" "$g_docker" "$(ar_icon docker)"
check "ar_icon cargo"  "$g_cargo"  "$(ar_icon cargo)"
check "ar_icon go"     "$g_go"     "$(ar_icon go)"
check "ar_icon claude" "$g_agent"  "$(ar_icon claude)"
check "ar_icon codex"  "$g_agent"  "$(ar_icon codex)"

# Every agent herdr detects gets the robot glyph, not just the original three.
# The arms are split across several case patterns, so walk the whole set: a
# dropped or mistyped entry then fails here instead of silently losing its icon.
for _agent in aider pi gemini cursor cursor-agent devin cline agy antigravity \
              omp mastracode opencode copilot kimi droid amp kiro kiro-cli \
              grok hermes kilo qodercli; do
  check "ar_icon $_agent" "$g_agent" "$(ar_icon "$_agent")"
done

# An unknown program has no glyph. This is the documented contract ("or empty")
# and it is what keeps the `[ -n "$ic" ]` guard in ar_format meaningful, so it
# must stay empty rather than gaining a fallback icon.
check "ar_icon unknown -> empty" "" "$(ar_icon htop)"
check "ar_icon empty arg -> empty" "" "$(ar_icon '')"

# ICON_STYLE wiring, end to end through ar_format.
check "icon style default is icon+name" "$g_nvim nvim" \
  "$(ICONS_ENABLED=1 ar_format 'nvim' 'nvim')"
check "icon style 'name_and_icon' is icon+name" "$g_git git" \
  "$(ICONS_ENABLED=1 ICON_STYLE=name_and_icon ar_format 'git' 'git status')"
check "icon style 'icon' is glyph only" "$g_nvim" \
  "$(ICONS_ENABLED=1 ICON_STYLE=icon ar_format 'nvim' 'nvim')"
check "icon-only label keeps cwd suffix" "$g_nvim:foo" \
  "$(ICONS_ENABLED=1 ICON_STYLE=icon SHOW_CWD=1 ar_format 'nvim' 'nvim' '/Users/test/code/foo')"
check "icon style 'name' suppresses glyph" "nvim" \
  "$(ICONS_ENABLED=1 ICON_STYLE=name ar_format 'nvim' 'nvim')"

# Icons off (the default) never prepends a glyph, even for a known program.
check "icons off -> no glyph" "nvim" "$(ar_format 'nvim' 'nvim')"
# A program with no glyph keeps its plain name even with icons on.
check "icons on, unknown program -> plain name" "htop" \
  "$(ICONS_ENABLED=1 SHOW_PROGRAM_ARGS=0 ar_format 'htop' 'htop -d 5')"

# A glyph is one codepoint, so "<glyph> <name>" must be truncated by codepoint,
# never mid-byte. node is not name-only, so its cmdline is long enough to cut:
# MAX_NAME_LEN=6 keeps the glyph, the space, and 4 chars of the name.
check "icon+name truncates on codepoint boundary" "$g_node node" \
  "$(ICONS_ENABLED=1 MAX_NAME_LEN=6 SHOW_PROGRAM_ARGS=1 ar_format 'node' 'nodeandmore')"

# ---- HIDE_SHELL: suppress the shell component (issue #5) ----
# Without cwd the empty label still hands the tab back to herdr. With cwd
# display enabled, the independent directory component remains visible.
check "hide_shell bare prompt"    "" "$(HIDE_SHELL=1 ar_format '' '')"
check "hide_shell explicit fish"  "" "$(HIDE_SHELL=1 ar_format 'fish' '-fish')"
check "hide_shell explicit bash"  "" "$(HIDE_SHELL=1 ar_format 'bash' 'bash')"
check "hide_shell ignored ls"     "" "$(HIDE_SHELL=1 ar_format 'ls' 'ls -la')"
check "hide_shell keeps cwd" "foo" \
  "$(HIDE_SHELL=1 SHOW_CWD=1 ar_format 'zsh' '-zsh' '/Users/test/code/foo')"
check "hide_shell ignored command keeps cwd" "foo" \
  "$(HIDE_SHELL=1 SHOW_CWD=1 ar_format 'ls' 'ls -la' '/Users/test/code/foo')"
# Only shells are hidden: a real program is named exactly as before.
check "hide_shell keeps nvim"     "nvim" "$(HIDE_SHELL=1 ar_format 'nvim' 'nvim README.md')"
check "hide_shell keeps program"  "htop" "$(HIDE_SHELL=1 SHOW_PROGRAM_ARGS=0 ar_format 'htop' 'htop -d 5')"
# An alias is a label the user asked for by hand, so it outlives the knob.
check "hide_shell keeps alias on a shell" "sh" \
  "$(PROGRAM_ALIASES=("fish=sh"); HIDE_SHELL=1 ar_format 'fish' '-fish')"
# Off (the default) is the old behavior, unchanged.
check "hide_shell off -> shell name" "zsh" "$(HIDE_SHELL=0 ar_format '' '')"
got=$(bash -c 'SHELL_NAME=zsh; . "$1"; ar_format "" ""' _ "$here/../naming.sh")
check "HIDE_SHELL defaults to off" "zsh" "$got"
got=$(bash -c 'HOME=/Users/test; SHELL_NAME=zsh; . "$1"; ar_format zsh zsh /Users/test' _ "$here/../naming.sh")
check "SHOW_CWD defaults to on" "~" "$got"

# ---- default: SHOW_PROGRAM_ARGS defaults to 0 (regular program -> name only) ----
got=$(bash -c 'SHELL_NAME=zsh; . "$1"; ar_format htop "htop -d 5"' _ "$here/../naming.sh")
check "SHOW_PROGRAM_ARGS defaults to name-only" "htop" "$got"

# ---- config arrays: an intentionally-empty override must survive the guard ----
# naming.sh uses `declare -p`, not `${arr+x}` (which reports a zero-element array
# as unset and would silently restore the default list). Source it fresh in a
# subshell with IGNORED_PROGRAMS=() and confirm `ls` is no longer suppressed.
got=$(bash -c 'SHELL_NAME=zsh; SHOW_PROGRAM_ARGS=1; IGNORED_PROGRAMS=(); . "$1"; ar_format ls "ls -la"' _ "$here/../naming.sh")
check "empty IGNORED_PROGRAMS override survives" "ls -la" "$got"

t_summary
