#!/usr/bin/env bash
# Behavior tests for install.sh: which startup file it writes, what it writes
# there, that a re-run is a no-op, and when it reaches for `herdr plugin
# install`. Everything runs against a fake HOME and a fake herdr, so no real
# startup file or herdr install is ever touched.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib.sh
. "$here/lib.sh"
REPO=$(cd "$here/.." && pwd)

SB=$(mktemp -d "${TMPDIR:-/tmp}/hal-install.XXXXXX")
trap 'rm -rf "$SB"' EXIT

# A herdr whose plugin list is whatever HAR_FAKE_INSTALLED says, and which logs
# every `plugin install` so a test can assert the call happened (or did not).
FAKE_HERDR="$SB/herdr"
cat >"$FAKE_HERDR" <<'FAKE'
#!/usr/bin/env bash
if [ "$1 $2" = "plugin list" ]; then
  if [ "${HAR_FAKE_INSTALLED:-0}" = 1 ]; then
    echo '{"result":{"plugins":[{"plugin_id":"herdr-automatic-rename"}]}}'
  else
    echo '{"result":{"plugins":[]}}'
  fi
  exit 0
fi
printf '%s\n' "$*" >>"$HAR_FAKE_LOG"
FAKE
chmod +x "$FAKE_HERDR"

# The curl'd shape: install.sh alone in a directory, with no engine beside it.
CURLED="$SB/curled"; mkdir -p "$CURLED"
cp "$REPO/install.sh" "$CURLED/install.sh"

# run <case-name> <shell> [env assignments...] -- fresh fake HOME per case, so
# each one starts from a clean startup file. Prints the script's output.
run() {
  case_home="$SB/home-$1"; mkdir -p "$case_home"
  shift
  HOME="$case_home" HERDR_BIN_PATH="$FAKE_HERDR" HAR_FAKE_LOG="$SB/herdr.log" \
    XDG_CONFIG_HOME='' SHELL=/bin/zsh bash "$@" 2>&1
}

: >"$SB/herdr.log"

# ---- the curl'd path: managed plugin directory, plugin installed for you ----
out=$(run curled-zsh "$CURLED/install.sh" zsh)
rc_file="$SB/home-curled-zsh/.zshrc"
check_contains "curled zsh: reports the file it wrote" "$out" ".zshrc"
check_contains "curled zsh: writes the marker" "$(cat "$rc_file")" \
  "# herdr-automatic-rename: live tab naming hook"
# A literal $HOME, not this sandbox's resolved path: the startup file has to
# keep working on the next machine that reads it, so the needle must not expand.
# shellcheck disable=SC2016
check_contains "curled zsh: globs the managed dir under \$HOME" "$(cat "$rc_file")" \
  '$HOME/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.zsh(N)'
check_absent "curled zsh: no resolved sandbox path" "$(cat "$rc_file")" "$SB"
check_contains "curled: installs the plugin" "$(cat "$SB/herdr.log")" \
  "plugin install qu8n/herdr-automatic-rename --yes"

# zsh parses what we wrote (the whole point of the (N) qualifier).
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$rc_file" >/dev/null 2>&1
  check_rc "curled zsh: snippet parses as zsh" 0 "$?"
else
  echo "# zsh not installed; skipping the parse check"
fi

# ---- re-run: idempotent, and no second plugin install ----
: >"$SB/herdr.log"
out=$(HOME="$SB/home-curled-zsh" HERDR_BIN_PATH="$FAKE_HERDR" HAR_FAKE_LOG="$SB/herdr.log" \
  HAR_FAKE_INSTALLED=1 XDG_CONFIG_HOME='' SHELL=/bin/zsh bash "$CURLED/install.sh" zsh 2>&1)
check_contains "re-run: says the hook is already there" "$out" "already in"
check_contains "re-run: says the plugin is already there" "$out" "plugin: already installed"
check "re-run: marker still appears once" "1" "$(grep -c 'live tab naming hook' "$rc_file")"
check "re-run: no herdr writes" "" "$(cat "$SB/herdr.log")"

# ---- bash: appends after whatever the file already set up ----
mkdir -p "$SB/home-curled-bash"
# shellcheck disable=SC2016
printf 'eval "$(starship init bash)"\n' >"$SB/home-curled-bash/.bashrc"
out=$(run curled-bash "$CURLED/install.sh" bash)
check "bash: hook lands after the prompt tool" "starship" \
  "$(sed -n '1s/.*starship.*/starship/p' "$SB/home-curled-bash/.bashrc")"
check_contains "bash: keeps the existing line" "$(cat "$SB/home-curled-bash/.bashrc")" "starship init"
check_contains "bash: globs the managed dir" "$(cat "$SB/home-curled-bash/.bashrc")" \
  'hook.bash'
bash -n "$SB/home-curled-bash/.bashrc" >/dev/null 2>&1
check_rc "bash: snippet parses as bash" 0 "$?"

# ---- fish: its own config path, created when missing ----
out=$(run curled-fish "$CURLED/install.sh" fish)
check_contains "fish: writes config.fish" "$out" "fish/config.fish"
check_contains "fish: sources the fish hook" "$(cat "$SB/home-curled-fish/.config/fish/config.fish")" \
  "hook.fish"
if command -v fish >/dev/null 2>&1; then
  fish -n "$SB/home-curled-fish/.config/fish/config.fish" >/dev/null 2>&1
  check_rc "fish: snippet parses as fish" 0 "$?"
else
  echo "# fish not installed; skipping the parse check"
fi

# ---- run from a clone: the hook points at the clone, plugin left alone ----
: >"$SB/herdr.log"
out=$(run clone "$REPO/install.sh" zsh)
check_contains "clone: hook points at the checkout" "$(cat "$SB/home-clone/.zshrc")" \
  "$REPO/shell/hook.zsh"
check_contains "clone: says the plugin is yours to link" "$out" "link it with herdr yourself"
check "clone: no herdr writes" "" "$(cat "$SB/herdr.log")"

# ---- an unrecognized shell asks rather than guessing ----
out=$(run other "$CURLED/install.sh" tcsh 2>&1) && rc=0 || rc=$?
check_rc "unknown shell: fails" 1 "$rc"
check_contains "unknown shell: names the ones it knows" "$out" "Pass zsh, bash, or fish"

# ---- HAR_RC overrides the startup file (macOS .bash_profile, say) ----
mkdir -p "$SB/home-har-rc"
HOME="$SB/home-har-rc" HERDR_BIN_PATH="$FAKE_HERDR" HAR_FAKE_LOG="$SB/herdr.log" \
  HAR_FAKE_INSTALLED=1 XDG_CONFIG_HOME='' HAR_RC="$SB/home-har-rc/.bash_profile" \
  bash "$CURLED/install.sh" bash >/dev/null 2>&1
check_contains "HAR_RC: writes the named file" "$(cat "$SB/home-har-rc/.bash_profile")" "hook.bash"
check "HAR_RC: leaves .bashrc alone" "0" \
  "$([ -e "$SB/home-har-rc/.bashrc" ] && echo 1 || echo 0)"

t_summary
