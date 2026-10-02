#!/usr/bin/env bash
# One command that installs the plugin and wires the shell hook, for whichever
# of zsh, bash, and fish you actually use:
#
#   curl -fsSL https://raw.githubusercontent.com/qu8n/herdr-automatic-rename/main/install.sh | bash
#
# Run it again any time: both halves are idempotent. Pass a shell name to wire a
# shell other than your login one (`bash install.sh fish`), and set
# HAR_RC to point at a startup file other than that shell's default.
#
# Run from a clone instead of curl'd, the hook it writes points at the clone (a
# checkout is not under herdr's managed plugin directory), and the plugin half
# is left to you, since herdr is the one that would own a second copy.
set -eu

REPO="qu8n/herdr-automatic-rename"
# The line that makes this idempotent: present in a startup file means the hook
# is already wired, so a re-run touches nothing.
MARKER="# herdr-automatic-rename: live tab naming hook"
HERDR="${HERDR_BIN_PATH:-herdr}"

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

command -v "$HERDR" >/dev/null 2>&1 || die "herdr is not on PATH; see https://herdr.dev"
command -v jq >/dev/null 2>&1 || die "jq is not on PATH; the plugin needs it too"

# Where the hook lives. A clone has the engine next to this script; a curl'd run
# has nothing next to it, so the hook globs herdr's managed plugin directory,
# whose name carries a version hash that changes under every upgrade.
# $0 is a file only when this script was run from disk. Piped from curl it is
# "bash", whose dirname is the current directory -- which would read as a clone
# to anyone who happened to be standing in one.
self_dir=""
[ -f "$0" ] && self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
if [ -n "$self_dir" ] && [ -f "$self_dir/automatic-rename.sh" ]; then
  from_clone=1
  hook_dir="$self_dir/shell"
else
  from_clone=0
  # Written with a literal $HOME so the startup file stays portable across
  # machines. Only a non-default XDG_CONFIG_HOME hard-codes a resolved path.
  base="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/github"
  # The single quotes keep $HOME literal in what we write; that is the point.
  # shellcheck disable=SC2016
  case "$base" in
    "$HOME"/*) hook_dir='$HOME'"${base#"$HOME"}/herdr-automatic-rename-*/shell" ;;
    *) hook_dir="$base/herdr-automatic-rename-*/shell" ;;
  esac
fi

# --- 1. the plugin ---
if "$HERDR" plugin list --json 2>/dev/null |
  jq -e '.result.plugins[]|select(.plugin_id=="herdr-automatic-rename")' >/dev/null 2>&1; then
  say "plugin: already installed"
elif [ "$from_clone" = 1 ]; then
  say "plugin: not installed, and this is a clone -- link it with herdr yourself"
else
  say "plugin: installing $REPO"
  "$HERDR" plugin install "$REPO" --yes
fi

# --- 2. the shell hook ---
shell=${1:-$(basename "${SHELL:-}")}
case "$shell" in
  zsh)
    rc="${HAR_RC:-$HOME/.zshrc}"
    if [ "$from_clone" = 1 ]; then
      snippet="[[ -r $hook_dir/hook.zsh ]] && source $hook_dir/hook.zsh"
    else
      # (N) is zsh's nullglob qualifier: no match expands to nothing rather
      # than erroring on every new shell.
      snippet="for _f in $hook_dir/hook.zsh(N); do
  source \$_f; break
done"
    fi
    ;;
  bash)
    # Appending puts the hook after whatever prompt or history tool (starship,
    # atuin, ble.sh) the file already sets up, which is where hook.bash wants
    # to be: it registers into their arrays instead of clobbering the DEBUG
    # trap. macOS login shells read .bash_profile, so pass HAR_RC for those.
    rc="${HAR_RC:-$HOME/.bashrc}"
    if [ "$from_clone" = 1 ]; then
      snippet="[ -r $hook_dir/hook.bash ] && source $hook_dir/hook.bash"
    else
      snippet="for _f in $hook_dir/hook.bash; do
  [ -r \"\$_f\" ] && { source \"\$_f\"; break; }
done"
    fi
    ;;
  fish)
    rc="${HAR_RC:-${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish}"
    if [ "$from_clone" = 1 ]; then
      snippet="test -r $hook_dir/hook.fish; and source $hook_dir/hook.fish"
    else
      snippet="for _f in $hook_dir/hook.fish
    test -r \"\$_f\"; and source \"\$_f\"; and break
end"
    fi
    ;;
  *)
    die "unrecognized shell '${shell:-none}'. Pass zsh, bash, or fish, or add the hook by hand (see the README)."
    ;;
esac

if [ -f "$rc" ] && grep -qF "$MARKER" "$rc"; then
  say "hook: already in $rc"
else
  mkdir -p "$(dirname "$rc")"
  printf '\n%s\n%s\n' "$MARKER" "$snippet" >>"$rc"
  say "hook: added to $rc -- open a new $shell tab, or source that file, to pick it up"
fi

# --- 3. what is left, which no script should do behind your back ---
cat <<'EOF'

Two manual steps remain:
  * Turn off herdr's new-tab name prompt, which otherwise counts as a hand
    rename and opts new tabs out of naming. In ~/.config/herdr/config.toml:
        [ui]
        prompt_new_tab_name = false
  * Install the herdr integration for the coding agents you use, so herdr
    detects an agent natively instead of by reading the screen:
        https://herdr.dev/docs/integrations/
EOF
