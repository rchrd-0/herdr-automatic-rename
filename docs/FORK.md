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
