# icons.sh - Nerd Font glyph map for herdr-automatic-rename, sourced by naming.sh.
#
# Pure data + lookup, no herdr or filesystem access, so it stays unit-testable
# on its own (tests/test_naming.sh sources naming.sh, which pulls this in).
# Targets bash 3.2 (macOS /bin/bash): no associative arrays, so the builtin map
# is a case statement, arms sorted by their first program.
#
# The map is the `icons:` block of
#   https://raw.githubusercontent.com/joshmedeski/tmux-nerd-font-window-name/main/bin/defaults.yml
# (fetched 2026-08-03), plus the aliases this plugin always shipped that the
# upstream file does not list: gvim/view (vim), bun/npx/pnpm (node),
# ipython/ipython3 (python). One arm gives the robot glyph to every agent herdr
# detects, the executable names naming.sh keeps in NAME_ONLY_PROGRAMS, which is
# where that roster records which herdr release it was copied from.
#
# The glyphs below are literal Private Use Area characters and render as blank
# boxes without a Nerd Font installed. They also went missing once: every arm
# of the old map shipped as `printf ''` from naming.sh's first commit through
# v0.2.1, which made ICONS_ENABLED=1 a silent no-op (issue #3). Each arm
# carries its codepoint in a comment so a stripped glyph can be restored, and
# tests/test_naming.sh asserts the exact bytes, so the same loss fails the
# suite instead of passing quietly.

# ---- configurable knobs (override in config.sh / $HERDR_AUTOMATIC_RENAME_CONFIG) ----
: "${ICONS_ENABLED:=0}"          # prepend a Nerd Font glyph (needs a Nerd Font)
: "${ICON_STYLE:=name_and_icon}" # name_and_icon (icon+name) | name (name only) | icon (icon only)

# Glyph shown when a program is missing from the map, like upstream's
# fallback-icon. Empty by default: with icons on, a tab with no glyph already
# marks an unmapped program, and a "?" there reads as an error. The `+x` guard
# keeps a value config.sh set, empty or not.
if [ -z "${ICON_FALLBACK+x}" ]; then ICON_FALLBACK=''; fi

# Per-program icon overrides: "<program>=<glyph>" pairs, checked before the
# builtin map. Set this in config.sh, e.g. ICON_MAP=("nvim=...").
declare -p ICON_MAP >/dev/null 2>&1 || ICON_MAP=()

# ar_icon <program> -> a Nerd Font glyph, or $ICON_FALLBACK ("" by default).
# Lookup order: user ICON_MAP override -> builtin map -> fallback. An empty
# argument returns empty on purpose; ar_format only prepends when the glyph is
# non-empty, so with the fallback off an unknown program keeps a clean,
# text-only label.
ar_icon() {
  local n=$1 pair
  [ -n "$n" ] || return 0
  for pair in "${ICON_MAP[@]}"; do
    case "$pair" in
    "$n="*)
      printf '%s' "${pair#*=}"
      return 0
      ;;
    esac
  done
  case "$n" in
  Python | ipython | ipython3 | pip | pip3 | python | python3) printf '\356\234\274' ;; # U+E73C
  R) printf '\357\263\222' ;;                                                           # U+FCD2
  aider | claude | codex | pi | gemini | cursor | cursor-agent | devin | cline | \
    agy | antigravity | omp | mastracode | opencode | copilot | kimi | droid | amp | \
    kiro | kiro-cli | grok | hermes | kilo | qodercli | qwen | maki | \
    letta | letta-code | muse | muse-cli | muse-code) \
    printf '\363\260\232\251' ;;                                                        # U+F06A9
  alacritty | gnome-terminal | iterm2) printf '\357\204\240' ;;                         # U+F120
  ansible) printf '\357\227\247' ;;                                                     # U+F5E7
  ant) printf '\356\235\240' ;;                                                         # U+E760
  apache2 | httpd | nginx) printf '\357\202\254' ;;                                     # U+F0AC
  apt | dpkg | nala) printf '\356\235\275' ;;                                           # U+E77D
  atom) printf '\356\235\244' ;;                                                        # U+E764
  aws) printf '\357\211\260' ;;                                                         # U+F270
  babel) printf '\356\234\215' ;;                                                       # U+E70D
  bash | fish | just | nu | tcsh | zsh) printf '\356\236\225' ;;                        # U+E795
  bat) printf '\363\260\255\237' ;;                                                     # U+F0B5F
  bazel) printf '\356\230\272' ;;                                                       # U+E63A
  beam | beam.smp) printf '\356\236\261' ;;                                             # U+E7B1
  bitbucket) printf '\356\234\203' ;;                                                   # U+E703
  brew) printf '\356\254\251' ;;                                                        # U+EB29
  btm | btop | glances | htop | mactop | top) printf '\356\256\242' ;;                  # U+EBA2
  bun | node | npx | pnpm | yarn) printf '\356\234\230' ;;                              # U+E718
  caffeinate) printf '\357\203\264' ;;                                                  # U+F0F4
  cargo | rustc | rustup) printf '\356\236\250' ;;                                      # U+E7A8
  cfdisk | fdisk | parted) printf '\357\202\240' ;;                                     # U+F0A0
  clang | gcc) printf '\356\230\236' ;;                                                 # U+E61E
  clion | idea | pycharm) printf '\356\236\265' ;;                                      # U+E7B5
  cmake | julia | make) printf '\356\230\244' ;;                                        # U+E624
  code | code-insiders) printf '\356\236\226' ;;                                        # U+E796
  composer) printf '\356\236\203' ;;                                                    # U+E783
  console) printf '\363\260\236\267' ;;                                                 # U+F07B7
  crontab) printf '\357\201\263' ;;                                                     # U+F073
  csharp) printf '\356\236\257' ;;                                                      # U+E7AF
  curl | wget) printf '\357\200\231' ;;                                                 # U+F019
  dart | flutter) printf '\356\236\230' ;;                                              # U+E798
  deno) printf '\356\255\222' ;;                                                        # U+EB52
  dnf | yum) printf '\357\214\212' ;;                                                   # U+F30A
  docker | lazydocker) printf '\357\214\210' ;;                                         # U+F308
  doctl) printf '\357\222\201' ;;                                                       # U+F481
  dotnet) printf '\356\235\277' ;;                                                      # U+E77F
  eclipse) printf '\356\236\260' ;;                                                     # U+E7B0
  elixir) printf '\356\230\255' ;;                                                      # U+E62D
  emacs) printf '\356\230\262' ;;                                                       # U+E632
  firebase) printf '\356\236\207' ;;                                                    # U+E787
  gcloud) printf '\356\211\260' ;;                                                      # U+E270
  gdb | lldb | valgrind) printf '\357\206\210' ;;                                       # U+F188
  gh | gitlab | wordpress) printf '\356\234\211' ;;                                     # U+E709
  ghc | stack) printf '\356\235\267' ;;                                                 # U+E777
  ghostty) printf '\356\273\276' ;;                                                     # U+EEFE
  git | gitui | lazygit | tig) printf '\356\234\202' ;;                                 # U+E702
  go) printf '\356\230\247' ;;                                                          # U+E627
  gpg) printf '\357\202\204' ;;                                                         # U+F084
  gping | ping) printf '\356\234\224' ;;                                                # U+E714
  gradle) printf '\356\236\251' ;;                                                      # U+E7A9
  grunt) printf '\356\230\221' ;;                                                       # U+E611
  gulp) printf '\356\230\220' ;;                                                        # U+E610
  gvim | lvim | vi | view | vim) printf '\356\230\253' ;;                               # U+E62B
  helm | k9s | kubectl | kubie | minikube) printf '\363\261\203\276' ;;                 # U+F10FE
  heroku) printf '\356\235\211' ;;                                                      # U+E749
  hg) printf '\356\234\247' ;;                                                          # U+E727
  hx) printf '\363\260\224\244' ;;                                                      # U+F0524
  java) printf '\356\211\226' ;;                                                        # U+E256
  jekyll) printf '\356\230\260' ;;                                                      # U+E630
  jenkins) printf '\356\235\247' ;;                                                     # U+E767
  jest) printf '\356\235\222' ;;                                                        # U+E752
  jj | lazyjj | svn) printf '\356\234\245' ;;                                           # U+E725
  laravel) printf '\356\234\277' ;;                                                     # U+E73F
  lf | lfcd | ranger) printf '\357\201\274' ;;                                          # U+F07C
  maven) printf '\356\236\264' ;;                                                       # U+E7B4
  mocha) printf '\356\236\236' ;;                                                       # U+E79E
  mongo) printf '\356\236\244' ;;                                                       # U+E7A4
  mysql) printf '\356\234\204' ;;                                                       # U+E704
  nano) printf '\357\201\200' ;;                                                        # U+F040
  netbeans) printf '\356\235\250' ;;                                                    # U+E768
  ng) printf '\356\235\223' ;;                                                          # U+E753
  npm) printf '\356\234\236' ;;                                                         # U+E71E
  nvim) printf '\356\232\256' ;;                                                        # U+E6AE
  openssl) printf '\357\200\243' ;;                                                     # U+F023
  pacman | paru | yay) printf '\357\214\203' ;;                                         # U+F303
  perl) printf '\356\235\251' ;;                                                        # U+E769
  php) printf '\356\234\275' ;;                                                         # U+E73D
  powershell) printf '\356\257\207' ;;                                                  # U+EBC7
  psql) printf '\356\235\256' ;;                                                        # U+E76E
  puppet) printf '\357\222\231' ;;                                                      # U+F499
  react) printf '\356\236\272' ;;                                                       # U+E7BA
  redis) printf '\356\235\255' ;;                                                       # U+E76D
  rsync) printf '\357\200\241' ;;                                                       # U+F021
  ruby) printf '\356\210\276' ;;                                                        # U+E23E
  scala) printf '\356\234\267' ;;                                                       # U+E737
  scp | ssh) printf '\363\260\243\200' ;;                                               # U+F08C0
  screen | tmux) printf '\356\257\210' ;;                                               # U+EBC8
  sqlite) printf '\357\207\200' ;;                                                      # U+F1C0
  sublime_text) printf '\356\236\252' ;;                                                # U+E7AA
  sudo) printf '\357\204\262' ;;                                                        # U+F132
  swift) printf '\356\235\225' ;;                                                       # U+E755
  systemctl) printf '\357\202\205' ;;                                                   # U+F085
  terraform) printf '\357\262\275' ;;                                                   # U+FCBD
  tickrs) printf '\356\257\242' ;;                                                      # U+EBE2
  topgrade) printf '\363\260\232\260' ;;                                                # U+F06B0
  travis) printf '\356\235\276' ;;                                                      # U+E77E
  tsc) printf '\356\230\250' ;;                                                         # U+E628
  unicorn) printf '\363\261\227\203' ;;                                                 # U+F15C3
  unzip | zip) printf '\357\207\206' ;;                                                 # U+F1C6
  vagrant) printf '\357\212\270' ;;                                                     # U+F2B8
  virtualbox) printf '\356\234\252' ;;                                                  # U+E72A
  visualstudio) printf '\356\234\214' ;;                                                # U+E70C
  vue) printf '\357\265\202' ;;                                                         # U+FD42
  webpack) printf '\356\235\260' ;;                                                     # U+E770
  weechat) printf '\363\260\255\271' ;;                                                 # U+F0B79
  yazi) printf '\356\254\271' ;;                                                        # U+EB39
  zig) printf '\342\206\257' ;;                                                         # U+21AF
  *) printf '%s' "$ICON_FALLBACK" ;;
  esac
}
