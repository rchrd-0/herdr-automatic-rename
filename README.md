# herdr-automatic-rename

[![tests](https://github.com/qu8n/herdr-automatic-rename/actions/workflows/ci.yml/badge.svg)](https://github.com/qu8n/herdr-automatic-rename/actions/workflows/ci.yml)

Fork of [qu8n/herdr-automatic-rename](https://github.com/qu8n/herdr-automatic-rename), based on version `0.4.0`. Adds cwd-aware tab names.

## Features

**1. Automatic tab rename with the foreground process and cwd.** Inspired by [tmux](https://github.com/tmux/tmux)'s `automatic-rename`, each tab shows the active directory at a shell prompt (e.g. `project`) or combines its foreground process with that directory (e.g. `nvim:project`, `codex:project`). Custom renames are respected, and `SHOW_CWD=0` restores the original process/shell-only style.

**2. Automatic prefix spaces/tabs with the 1-9 keybind jump number**. Add an `[N]` prefix to each workspace and tab matching the `1-9` binding for that slot. Glance at the tabs or sidebar, see what runs where, and quickly jump by number. Agents get one too on herdr `< 0.7.5`, which is the last release whose agent names allow it.

Each feature can be toggled and work independently.

<img width="3216" height="2088" alt="readme-demo-screenshot" src="https://github.com/user-attachments/assets/43f620c0-d667-4fa9-b76c-dbafde41b7ec" />

## Before and after

herdr labels a new tab with a number, and leaves workspace and agent rows at their plain names. One four-tab workspace in a checkout named `project`, before and after (stock fork config: `NAME_TABS=1`, `AUTO_INDEX=1`, `SHOW_CWD=1`):

```
herdr alone      │ 1           │ 2                │ 3           │ notes     │
with the plugin  │ [1] project │ [2] nvim:project │ [3] project │ [4] notes │
```

| Tab is running | herdr alone | with the plugin |
| --- | --- | --- |
| a bare shell prompt in `project` | `1` | `[1] project` |
| `nvim README.md` in `project` | `2` | `[2] nvim:project` |
| `ls -la`, an `IGNORED_PROGRAMS` entry | `3` | `[3] project` |
| a tab you renamed `notes` yourself | `notes` | `[4] notes` |

Workspaces get numbered, never renamed, so only the prefix is new:

| Sidebar row | herdr alone | with the plugin |
| --- | --- | --- |
| workspace | `dotfiles` | `[1] dotfiles` |
| agent | `claude` | `claude` (see below) |

Agents are the exception. herdr `0.7.5` restricted agent names to `^[a-z][a-z0-9_-]{0,31}$`, which no `[N] ` prefix can satisfy, so on herdr `>= 0.7.5` agent rows are left at their detected names and any `[N]` a previous version of this plugin managed to set is stripped back off. On herdr `< 0.7.5` agents still get `[1] claude`.

Turn one feature off and you keep the other half: `AUTO_INDEX=0` names without the prefix (`project`, `nvim:project`), and `NAME_TABS=0` leaves every base name as herdr or you left it and adds only the `[N]`. `SHOW_PROGRAM_ARGS=1` swaps a program's name for its whole command line before the cwd suffix, so a `npm run dev` tab reads `[2] npm run dev:project` rather than `[2] npm:project`. `SHOW_CWD=0` gives the original `zsh` / `nvim` output.

With `SHOW_CWD=0`, `HIDE_SHELL=1` can still hide a row of shell names and leave those tabs to herdr's own number:

```
HIDE_SHELL=0, AUTO_INDEX=0  │ lazygit     │ nvim     │ fish │ pi     │
HIDE_SHELL=1, AUTO_INDEX=0  │ lazygit     │ nvim     │ 3    │ pi     │
HIDE_SHELL=1, AUTO_INDEX=1  │ [1] lazygit │ [2] nvim │ [3]  │ [4] pi │
```

That covers a bare prompt, an explicit shell, and anything in `IGNORED_PROGRAMS`. With `SHOW_CWD=1`, `HIDE_SHELL` removes only the shell component and keeps the directory label; it falls back to the number-only behavior when cwd is unavailable.

## Requirements

herdr `>= 0.7.1`, `jq`, and bash. Linux or macOS.

herdr `>= 0.7.4` is recommended. There a plugin rename repaints the tab bar immediately, so live renames appear the instant they happen; on older herdr the new name still lands but the tab bar only catches up on the next redraw (a focus change or resize). herdr `>= 0.7.2` also lets a full reconcile read its whole state in one `api snapshot` call — without it the plugin falls back to per-list queries automatically.

Two newer versions add smaller wins, both detected at runtime: on herdr `>= 0.7.5` a restored session is reconciled the moment herdr comes up rather than at the first event, and on `>= 0.8.0` reordering a worktree group renumbers immediately. Everything else works down to `0.7.1`.

## Install

```sh
herdr plugin install qu8n/herdr-automatic-rename --yes
```

Events work immediately.

### Shell hook (highly recommended)

Renames the instant a command starts. Without it, naming waits for the next focus or tab event. Source your shell's hook so that it self-locates the engine wherever herdr installed it.

**zsh** (`~/.zshrc`):

```zsh
for _f in ${HOME}/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.zsh(N); do
  source $_f; break
done
```

**bash** (`~/.bashrc`, after any prompt/history tool like starship or atuin):

```bash
for _f in "$HOME"/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.bash; do
  [ -r "$_f" ] && { source "$_f"; break; }
done
```

**fish** (`~/.config/fish/config.fish`):

```fish
for _f in $HOME/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.fish
    test -r "$_f"; and source "$_f"; and break
end
```

No-op outside a herdr pane. On bash it cooperates with bash-preexec / atuin / ble.sh, else owns `DEBUG` without clobbering an existing trap.

A command word that is not an external program (a shell function, builtin, or typo) never renames the tab directly. The hook flags it, and the engine reads the pane's real foreground process a moment later: an instant function leaves the tab name alone, and a function that opens `nvim` uses `nvim:<directory>`. Each hook passes its shell's current `$PWD`; the next prompt callback therefore updates the label immediately after `cd`.

### Turn off herdr's new-tab name prompt

herdr asks each new tab for a name (`prompt_new_tab_name`, on by default). Under `NAME_TABS=1` that prompt has nothing left to do, and a name typed into it counts as a hand rename, which opts the tab out of naming until you `reset` it. Turn it off:

```toml
# ~/.config/herdr/config.toml
[ui]
prompt_new_tab_name = false
```

New tabs then arrive with herdr's generated number for the plugin to name. Accepting the prompt's prefilled number works as well, since a bare integer reads as a placeholder, but it costs a keystroke per tab. Keep `prompt_new_workspace_name` if you use it: the plugin only prefixes workspace names, it never generates them.

## Configuration

Works with no config. To change a knob, copy the sample:

```sh
mkdir -p ~/.config/herdr-automatic-rename
cp "$(dirname "$(herdr plugin list --json | jq -r '.result.plugins[]|select(.plugin_id=="herdr-automatic-rename").source.managed_path')")"/herdr-automatic-rename-*/config.example.sh \
  ~/.config/herdr-automatic-rename/config.sh
```

Override the path with `HERDR_AUTOMATIC_RENAME_CONFIG`.

| Knob | Default | What it does |
| --- | --- | --- |
| `NAME_TABS` | `1` | Rename each tab from its foreground program and optional cwd. `0` leaves tab names alone. |
| `AUTO_INDEX` | `1` | Add the `[N]` jump-key number (1-9) in front of each workspace and tab (and agent on herdr `< 0.7.5`). |
| `SHOW_PROGRAM_ARGS` | `0` | `0` shows just the program name (`git`), `1` shows its full command line (`git log --oneline`). |
| `SHOW_CWD` | `1` | Show the cwd basename alone at a shell prompt and append it to programs (`nvim:project`). `0` restores process/shell-only names. |
| `MAX_NAME_LEN` | `20` | Cut the finished label off after this many characters. |
| `SHELL_NAME` | `$SHELL` basename | Shell component/fallback used when no program is running and cwd is unavailable. |
| `HIDE_SHELL` | `0` | `1` suppresses the shell component. A cwd remains visible; without cwd, herdr's own tab number shows instead. |
| `SHELLS` | `zsh bash sh fish dash ksh` | Programs counted as a shell prompt, so cwd replaces their program label when available. |
| `NAME_ONLY_PROGRAMS` | editors, git tools, agents | Program components always shown by bare name, never with args (`nvim`, `claude`). |
| `IGNORED_PROGRAMS` | `ls`, `cd`, `cat`, ... | Quick commands that keep the shell/cwd prompt label instead of taking over the tab. |
| `PROGRAM_ALIASES` | none | Force a specific program to a custom label, e.g. `("lazygit=lg")`. |
| `SUBSTITUTE_SETS` | two rules | `sed -E` rewrites that tidy up the label, e.g. to shorten a path-heavy command line. |
| `ICONS_ENABLED` | `0` | `1` prepends a Nerd Font glyph for the program (needs a Nerd Font installed). |
| `ICON_STYLE` | `name_and_icon` | When icons are on, show `name_and_icon`, `icon` only, or `name` only. |

`config.example.sh` documents each with examples.

## Actions

- `reset`: re-adopt a hand-renamed tab.
- `clear`: strip every `[N]`, restore base names, revert agents to detection.

Run from the CLI, or bind a key:

```sh
herdr plugin action invoke herdr-automatic-rename.reset
```

```toml
# ~/.config/herdr/config.toml (example binding)
[[keys.command]]
key = "alt+shift+r"
type = "plugin_action"
command = "herdr-automatic-rename.reset"
```

## Uninstall

Strip labels first (else `clear`'s renames re-fire the hooks), then remove:

```sh
bash "$(herdr plugin list --json \
  | jq -r '.result.plugins[]|select(.plugin_id=="herdr-automatic-rename").source.managed_path')/automatic-rename.sh" --clear
herdr plugin uninstall herdr-automatic-rename
```

## Notes

- **Manual renames win.** Rename a tab yourself and naming leaves it alone. Numbering still applies. `clear` the label or `reset` to hand it back.
- **Cwd has two sources.** Normal Herdr-driven reconciles use the selected pane's cached `foreground_cwd`, falling back to `cwd`; shell-hook updates use that shell's `$PWD` directly. The former follows the foreground process when Herdr can resolve it, while the latter is authoritative at prompt time and updates immediately after `cd`.
- **Agent numbering needs herdr `< 0.7.5`.** That release added a name rule (`^[a-z][a-z0-9_-]{0,31}$`) that rejects a bracketed number outright, so newer herdr leaves agent rows alone and strips any prefix an older setup left behind. Where it does apply, it also needs grouped (`spaces`) sort, the mode whose CLI order matches the panel `focus_agent` follows. In `priority` sort that order is API-invisible, so numbers are stripped there too.
- **Tab names go quiet on Linux runtimes with no foreground process group.** Naming reads the pane's foreground process, and some container and sandbox setups leave herdr unable to see one, which makes tab naming do nothing at all (numbering is unaffected). herdr `>= 0.8.0` has an opt-in fallback: set `HERDR_PROCESS_DETECTION=child-groups` in its environment. It is best-effort by herdr's own account, since in that mode a background job can look like the foreground one, so a tab may occasionally follow the wrong process.
- **Collapsing a space renumbers.** `alt+N` counts the sidebar's visible rows, so a collapsed space hides its worktree workspaces from numbering and every row below it moves up. The hidden ones go bare until you expand. Focusing one of those worktrees while the space stays collapsed renders that row again, which shifts the rows below it back down. herdr publishes collapse only in `session.json`, on a 5-second debounce and with no event to hook, so the first jump right after a collapse can still use the old numbers.
- **Stops at 9.** No binding reaches a 10th item, so `10+` stay bare.

## Development

Engine: `automatic-rename.sh` (bash 3.2, needs only `jq` and the herdr CLI). Pure naming: `naming.sh`. Tests need only bash and jq:

```sh
./tests/run.sh            # all
./tests/run.sh reconcile  # one file
```

They cover the naming rules, the `[N]` prefix helpers, the state machine, the shell hooks, and a full reconcile against a fake `herdr`.

## License

MIT. See [LICENSE](LICENSE).
