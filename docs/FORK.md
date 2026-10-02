# Fork compatibility

This fork adopts upstream 0.13.0 naming: directory and branch context, SSH host labels, agent task titles, and workspace tracking. Existing manual names remain excluded from automatic tab naming. Existing owned compact labels update on the next naming pass. The old `SHOW_CWD` setting no longer controls labels; use upstream's `TAB_CONTEXT`, `SHOW_BRANCH`, and `AGENT_TITLES` settings instead. `AGENT_TITLES=0` keeps program names in place of agent task titles.

## Sidebar tab numbers

Herdr 0.8.0 and newer receive a plain `tab_number` pane token for tab positions 1 through 9. Sidebar row templates can display `$tab_number`. All panes in a tab receive the same position. The token follows effective tab indexing, including `AUTO_INDEX_TABS`; disabling tab indexing, running `clear`, or moving a tab beyond position 9 removes only this token. Other pane metadata is preserved.

The implementation lives in `fork-metadata.sh` and reuses the reconcile's pane inventory. It adds no polling or shell-hook metadata work. A failed metadata report retries on a later reconcile. Sidebar collapse and sort changes still need a plugin event before numbering refreshes.

## Compatibility and recovery

Already-loaded shell hooks that pass explicit working directories remain supported, as do upstream hooks. A delayed preexec that sees the shell again cannot overwrite a newer prompt label.

Tab ownership is published before a rename emits its event. Failed writes prevent the rename, and rejected renames restore the previous state. Incomplete workspace or tab lists defer tab-state pruning. State reads distinguish malformed data from tool failures, and session migration runs under the session lock with checked confirmation. Client preference lookup follows the API/client socket precedence used by Herdr 0.9.3.

## Updating

The initial adoption must include upstream history in a real Git merge. Copying files or cherry-picking fixes alone does not establish that ancestry. Future GitHub Sync fork updates can merge automatically when these additions do not conflict with upstream changes; conflicts still require review. Run the upstream suite and `test_fork_*.sh` after each update.

## Checkout context in sidebars

Set `SIDEBAR_CONTEXT=1` in the plugin's `config.sh` to publish `ar_workspace_label` and `ar_checkout_context` on workspaces and their panes. This is opt-in and leaves upstream tab formatting and workspace names intact. It requires Herdr 0.8.0 or newer.

Main checkouts keep their project label. Linked worktrees use their checked-out branch as the primary sidebar label, with the same visible workspace shortcut number. A manually named workspace keeps its name. Detached worktrees show an explicit detached-HEAD identity; an unreadable checkout uses a worktree-path fallback instead of pretending to be the main checkout. The context token is the branch for a main checkout and the repository for a linked worktree. For a manually named linked worktree, it includes both repository and branch so the custom name does not hide checkout identity.

Configure Herdr's `config.toml` with:

```toml
[ui.sidebar.spaces]
rows = [["state_icon", "$ar_workspace_label"], ["branch", "git_status"]]

[ui.sidebar.agents]
rows = [["state_icon", "$ar_workspace_label"], ["$ar_checkout_context", "state_text", "agent"]]
```

The space layout keeps Herdr's indentation and native branch/status details. Agent rows share the space identity instead of repeating an ambiguous project name and a tab number. Task titles can be added as another row with `terminal_title_stripped`; they are optional and do not replace checkout identity.

Metadata refreshes on normal plugin events and on shell prompts, so checking out a branch refreshes the caller's workspace without polling. Unchanged tokens are not written again. `clear` or disabling `SIDEBAR_CONTEXT` removes only these two tokens on the next full reconcile. Restore `workspace` in the sidebar templates when disabling the feature, since a custom token with no value is hidden by Herdr. The existing `tab_number` token remains available independently.
