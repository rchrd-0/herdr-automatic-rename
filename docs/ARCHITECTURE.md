# Architecture

This documents the non-obvious decisions in herdr-automatic-rename. For usage, see the
[README](../README.md).

## One reconcile, one entry point

`automatic-rename.sh` is invoked for every herdr event, both plugin actions, and the
shell hooks' fast path. It routes through `ar_run` and dispatches on `argv[1]`.
A full reconcile pulls its whole picture — workspaces, tabs, panes, and agents —
from one `herdr api snapshot` (a single socket call, herdr >= 0.7.2), then
computes the label every item should have and issues one rename per item whose
label is wrong. Older herdr with no `api snapshot` falls back to reading
`workspace list`, `pane list`, and `agent list` once each plus `tab list` per
workspace. Either way, per-tab foreground detection stays one `pane process-info`
per named tab — the snapshot carries pane identity and cwd data but not each
pane's foreground process.

Computing a tab's name and its `[N]` prefix in the same pass is what lets a
brand-new tab settle at `[3] project` in a single rename. Every rename is
skip-if-correct. A tab rename also emits `tab.renamed`; the event handler compares
the current base with the recorded auto-name and skips a full pass when they
match. A different base is a manual edit and still runs the ownership state
machine.

## Naming lives in a pure module

`naming.sh` turns `(program, cmdline, cwd)` into a display name and touches neither
herdr nor the filesystem. That keeps the naming rules (shells, name-only
programs, ignored programs, aliases, substitutions, cwd basename, truncation,
icons) unit testable in isolation. The engine calls `ar_format` across that
seam. Every function in both files uses the `ar_` prefix.

## Cwd comes from the state each path already owns

A full reconcile selects the active pane from cached snapshot or `pane list`
data and carries `.foreground_cwd // .cwd // ""` through the same resolver as
the pane id. `pane process-info` remains responsible only for the foreground
program and command. This keeps the existing request count: no cwd-specific
socket call is added.

The fast path has a better source. zsh, bash, and fish pass their quoted `$PWD`
to both preexec and prompt/postexec calls. The prompt callback runs after `cd`,
so it updates the directory label immediately without a separate chdir hook.
These values can briefly differ by design: Herdr's `foreground_cwd` follows the
foreground process when resolvable, while the hook value is the shell's cwd at
the moment the hook fires. In particular, `foreground_cwd` can retain the old
directory until focus changes after `cd`. The hook records its new base before
renaming, so the resulting `tab.renamed` event is recognized as self-generated
and cannot immediately reconcile the label back to stale pane data.

## Why config and state sit at fixed paths

State (`~/.local/state/herdr-automatic-rename/`) and config
(`~/.config/herdr-automatic-rename/config.sh`) use fixed paths, not
`$HERDR_PLUGIN_STATE_DIR` / `$HERDR_PLUGIN_CONFIG_DIR`. The live shell hooks run
`preexec`/`precmd`, launched by your shell, not by herdr, so they never receive
the `HERDR_PLUGIN_*` variables. The herdr-invoked pass and the shell-invoked
fast path must share one config and one state store, which forces a path both
can name without herdr's help. `$HERDR_AUTOMATIC_RENAME_CONFIG` overrides the config
location.

herdr exposes no per-tab metadata and no auto/manual flag, so the manual-rename
opt-out is tracked in a small JSON state file keyed by `tab_id`: the last base
the plugin set, and whether auto-naming is still enabled for that tab.

State reads require one JSON object. Missing, blank, malformed, or differently
shaped JSON is treated as an empty store so the next write or reset can recover
it. A failed file read or a jq process that cannot run is different: writers
return failure and leave the existing file alone.

Both naming paths publish ownership before calling `tab rename`, allowing a
synchronous `tab.renamed` event to recognize the plugin's own update. If the
state write fails, no rename is attempted; if Herdr rejects the rename, the
previous ownership record is restored so the next event can retry.

A reconcile prunes closed tabs only after reading every workspace's tab list
successfully. Failed, empty, malformed, or incomplete responses defer pruning
until a later complete pass. A valid empty tab array still counts as a complete
read. Empty keep lists and prune passes that remove nothing leave the state
file untouched.

## Locking

A `mkdir` lock (atomic, ownership-token stamped, 30-second steal window) plus a
rerun flag coalesces a burst of events into one worker. Contenders raise the
rerun flag and exit; the holder loops until no new work arrives. A fast-path run
that loses the lock still lands, because the holder's re-pass is a full reconcile
that recomputes names itself.

## The shell hooks find their own engine

herdr installs a github plugin to a content-hashed directory, so the hooks
cannot hard-code the engine path. Each hook resolves `automatic-rename.sh` relative to
its own sourced-file location: zsh via `${(%):-%N}`, bash via `BASH_SOURCE[0]`,
fish via `status current-filename` captured into a global. The bash hook never
overwrites a `DEBUG` trap another tool already set, and cooperates with
`bash-preexec` / `ble.sh` / `atuin` when present.

## Shell constructs are sampled, not trusted

The preexec fast path names the tab by the first word of the command line,
which is only honest when that word resolves to an external program. zsh
expands aliases in preexec's `$2` but never expands functions, and bash and
fish hand over the raw line, so a function `l`, a builtin, a reserved word, or
a typo arrives verbatim. No program list can match those words (`IGNORED_PROGRAMS`
holds `eza`, not the function `l` that calls it), so trusting them renamed the
tab and let precmd snap it back: a flicker on every instant construct.

Each hook classifies the command word (`whence -w` in zsh, `type -t` in bash,
`type --type` in fish). External commands keep the instant rename. Everything
else gets a `shell` marker, and the engine sleeps 0.2 s (before taking the
lock), then names the tab by the pane's actual foreground process via
`pane process-info`. An instant construct has exited by then, so the leader is
the shell again and nothing is renamed; precmd owns the prompt label. This is
load-bearing for `cd`, because the delayed preexec worker captured the old
`$PWD` and can finish after precmd has already written the new one. A construct
that wraps a long-running program gets that program's real name, which the typed
word never was. When sampling fails the engine renames nothing rather than guess.

## Numbering caveats

- **Tabs** are numbered by array order, not the non-contiguous `.number` field.
  On herdr 0.8.0 or newer, that same 1-9 position is also published to every
  pane in the tab as the plain custom token `tab_number`. This gives pane-backed
  agent rows a stable number without changing agent names or coupling the row to
  the tab's responsive display label. `ar_sync_tab_number_token` reads both pane
  identity and `.tokens.tab_number` from the cached snapshot or `pane list`,
  skips an already-correct value, and clears a stale token for positions 10+.
  Turning `AUTO_INDEX` off or running `clear` removes only this token. The
  `herdr-automatic-rename` source id owns each report; an unreadable or pre-0.8
  Herdr version disables the path rather than issuing an unsupported command.
  Shell-hook fast paths never report it because a program or cwd change cannot
  alter tab position; structural event reconciles own the metadata lifecycle.
- **Workspaces** are numbered by herdr's visible sidebar order, not the raw
  `workspace list` order. `alt+N` resolves through herdr's own
  `workspace_at_visible_position`, so a row the sidebar does not render is a row no
  keybind reaches, and a collapsed space both hides rows and moves the ones below
  it. `ar_workspace_positions` mirrors herdr's `workspace_list_entries_inner` and
  owns the rules (which workspaces nest, which member heads a space, what a
  collapsed one still renders); its header comment is the copy to keep in sync with
  upstream. Hidden rows come back as position 0 and drop their prefix like 10+.
- **Agents** are numbered only on herdr `< 0.7.5`, and there only when
  `agent_panel_sort` is grouped (`spaces`).
  - herdr `0.7.5` added `valid_agent_name` (`^[a-z][a-z0-9_-]{0,31}$`,
    `src/app/agents.rs`) and now answers `invalid_agent_name` to anything else, so
    `[N] claude` is not a name that release can hold. `ar_agent_prefix_ok` gates on
    the version and an unreadable version counts as restricted, because declining
    to number is recoverable and firing renames herdr rejects is not. The same
    release also stopped resolving `terminal_id` as an agent target
    (`resolve_agent_target`, `src/app/terminal_targets.rs`), so renames target
    `.pane_id`, the one form every supported version accepts.
  - Where it does apply, `priority` sort still opts out: the panel reorders behind
    an order the CLI never exposes, so the plugin strips agent numbers rather than
    guess wrong, and renumbers when you switch back.
  - Stripping runs on the restricted versions too, which is what unsticks an
    `[N] claude` written by an older herdr and older plugin. Nothing else can: that
    name fails every rename a newer herdr accepts, including `--clear` aimed at a
    `terminal_id`.
  - Numbering keeps its two-phase park (park at a unique temp, then finalize) to
    dodge herdr's duplicate-name rejection when several agents share a base like
    `claude`. It is reachable only on herdr `< 0.7.5`.
  - `agent.view.set` (herdr `0.7.5`) is a further reason the feature stops there.
    An active view redefines the order `focus_agent` follows, by sort or by
    filtering rows out, and `apply_agent_view` bypasses `agent_panel_sort`
    entirely. No event announces a view and no request reads one back, so a plugin
    cannot even detect the drift. Both of those releases are ones where agent
    numbering is off anyway.
- Nothing numbers past 9, since no keybind reaches a 10th item.

## Collapse is readable, but only from session.json

herdr publishes sidebar collapse nowhere in its API: no field on `workspace list`
or `api snapshot`, no request method, and none of the events a plugin can subscribe
to (checked against protocol 17). Toggling a space flips `collapsed_space_keys` in
memory and marks the session dirty, which leaves one readable copy: the top-level
`collapsed_space_keys` array in that session's `session.json`. `ar_collapsed_spaces`
reads it, at the path `ar_herdr_session_dir` derives by stripping the filename off
`$HERDR_SOCKET_PATH`. herdr keeps a session's socket, `session.json`, and
`config.toml` in one directory and exports that variable into plugin commands and
pane environments both, so the herdr-invoked pass and the shell hooks resolve the
same files, in a named session as well as the default one. `ar_agent_sort` reads its
`config.toml` through the same helper for that reason.

Two consequences follow. The file is written atomically (temp plus rename, so no
torn reads) on a 5-second debounce, so a pass that runs right after the click still
reads the old value and corrects itself on a later event. And because the toggle
emits no event, nothing wakes the plugin when collapse changes: the numbers settle
on whatever event arrives next, which in an active session is usually seconds away
(`pane.agent_status_changed` fires constantly). So the first `alt+N` after a
collapse can still jump by the old numbering. Upstream support, either an event or
a `collapsed` field on `WorkspaceInfo`, is what would close that window.

## The placeholder rule

herdr labels a fresh tab with a small integer. When naming is on but the tab's
foreground program cannot be read yet (a background multi-pane tab exposes no
active pane), the pass counts the tab's position but defers its rename, so no
throwaway `[3] 3` flashes before the real name arrives. When naming is off, the
integer is numbered as-is, since nothing else will ever name it.

## An empty name is a name (HIDE_SHELL)

`HIDE_SHELL=1` suppresses the shell component. With `SHOW_CWD=1`, a resolved cwd
still supplies an independent directory label. When cwd display is disabled or
cwd is unavailable, the result is the empty string, because that is the only way
to get herdr's own tab number back on screen: herdr renders the number whenever
a tab has no label, and there is no API to ask for it directly.

The empty string is now a name the engine has to carry around, so the invariant
is: **a name is returned on stdout, and "cannot compute one" is reported only
through exit status, never as empty output.** Every site that could confuse the
two follows from it:

- `ar_tab_name` reports failure through its exit status instead of an empty
  string, and `ar_reconcile_tabs` branches on that status rather than on the
  string it got back.
- The `[N] ` prefix helpers accept a bare `[3]`, the numbered form of an empty
  base. Without that, a hidden tab would read its own label back as a hand-typed
  name and opt itself out of naming permanently.
- `ar_desired` numbers an empty base as `[3]` rather than `[3] `, since herdr
  drops the trailing space anyway and the bare form round-trips back through
  `ar_strip_prefix`.
- The opt-out state machine keeps a tab whose recorded name is empty even when
  the label reads as herdr's integer again, which is what a restored session and
  herdr's own relabeling look like from here.
- `ar_reconcile_tabs` writes an empty base when the emptiness is deliberate, and
  skips the tab only when herdr has not labeled it at all.
- The fast path is the one exception: it calls `ar_format` directly rather than
  through `ar_tab_name`, so it has no status to read and tests `HIDE_SHELL`
  itself to decide whether an empty `ar_format` result is an answer.

The placeholder rule above is unaffected: it defers a tab whose name is not
computable *yet*, while an empty name is computed and final.

## Testing

`tests/` runs on bash and jq alone (no bats). It covers the pure naming and cwd rules,
the `[N]` prefix helpers, the JSON state store and opt-out state machine, the
shell hooks, and a full reconcile driven against a fake `herdr` (`tests/mocks/herdr`)
that serves fixture JSON and records every rename the engine issues. Sourcing
`automatic-rename.sh` defines its functions but runs nothing (guarded by
`BASH_SOURCE[0] == $0`), so the helpers can be exercised directly.
