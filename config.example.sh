# herdr-automatic-rename configuration.
#
# Copy to ~/.config/herdr-automatic-rename/config.sh and uncomment what you want to
# change (or point $HERDR_AUTOMATIC_RENAME_CONFIG somewhere else). This file is sourced
# by automatic-rename.sh BEFORE naming.sh, so anything set here wins over the defaults.
# Every setting has a working default, so an empty config is fine.

# ---- feature toggles (both default on) ----

# Auto-name each tab from its foreground program and, with SHOW_CWD enabled, its
# cwd basename. Set to 0 to leave tab names alone.
# NAME_TABS=1

# Prefix workspaces and tabs with their 1-9 jump-key number, e.g. "[2] api". Set
# to 0 to name without numbering. Agents are included only on herdr < 0.7.5:
# newer herdr rejects a bracketed agent name, so those rows keep their detected
# names (and lose any prefix an older setup left on them).
# AUTO_INDEX=1

# ---- naming knobs (only used when NAME_TABS=1) ----

# 1 = a regular program shows its full command line ("psql -h db"); 0 = just its
# name ("psql"). Default 0.
# SHOW_PROGRAM_ARGS=0

# 1 = include the active pane's cwd basename. Shell prompts show only the
# directory ("project"); programs append it with a colon ("nvim:project").
# Set to 0 for the original shell/program-only naming behavior. Default 1.
# SHOW_CWD=1

# Truncate the final label to this many characters (counted by codepoint).
# MAX_NAME_LEN=20

# Shell fallback used when cwd is unavailable. Defaults to $SHELL's basename.
# SHELL_NAME=zsh

# 1 = suppress the shell component at a bare prompt, for an explicit shell, and
# for an IGNORED_PROGRAMS command. With SHOW_CWD=1 the directory remains visible;
# without a cwd component the label is empty and herdr shows its own tab number
# (or the jump number alone, "[3]", with AUTO_INDEX=1). Programs are unchanged.
# HIDE_SHELL=0

# Programs that count as a shell prompt, allowing cwd to replace their label.
# Assigning the array replaces the default; SHELLS=() disables the category.
# SHELLS=(zsh bash sh fish dash ksh)

# Program components shown by name only, without command-line args. Coding
# agents live here so the label starts with "claude" instead of its invocation.
# NAME_ONLY_PROGRAMS=(nvim vim vi view gvim git lazygit gitui lazydocker claude codex aider)

# Quick commands that should not take over the tab name: while one runs, the tab
# keeps its shell/cwd prompt label so it does not flicker.
# IGNORED_PROGRAMS=(ls eza ll la cd z zoxide cat bat less more echo pwd clear which man head tail wc cp mv rm mkdir touch fzf sudo doas)

# Rename specific programs on the tab. "<program>=<label>" pairs; wins over every
# rule except the bare-prompt shell name.
# PROGRAM_ALIASES=(
#   "lazygit=lg"
#   "clx=hn"
# )

# Ordered `sed -E` rewrites applied to the final label.
# SUBSTITUTE_SETS=(
#   's|.*ipython([32])|ipython\1|'
#   's|.*poetry shell.*|poetry|'
# )

# Prepend a Nerd Font glyph (needs a Nerd Font). ICON_STYLE is one of
# name_and_icon (default), name, or icon.
# ICONS_ENABLED=0
# ICON_STYLE=name_and_icon
