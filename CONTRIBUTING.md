# Contributing

Bug reports, fixes, and naming-rule tweaks are all welcome.

## Running the tests

The suite needs only `bash` and `jq`:

```sh
./tests/run.sh            # everything
./tests/run.sh <part>     # only files matching *<part>*, e.g. ./tests/run.sh git
./tests/run.sh --serial   # one file at a time, when a parallel run hides an interaction
make test                 # same as ./tests/run.sh
```

Add or update a test with any behavior change. Every `tests/test_*.sh` runs, so a new area gets a new file named after it, and `tests/lib.sh` holds the assertions.

Tests come in two shapes. A unit test sources the module it covers and checks strings in against strings out. An integration test runs the real engine against `tests/mocks/herdr`, a fake herdr that answers reads from fixture files and logs every rename instead of making one, so a scenario can assert the exact commands the engine issued. Reach for the second shape whenever the behavior depends on what herdr reports.

## Pre-commit hook

`make hooks` installs a git pre-commit hook that runs the same checks CI runs: bash/zsh/fish syntax, shellcheck, markdownlint, then the suite. It needs [prek](https://prek.j178.dev) (`pre-commit` works too, and the config is the same `.pre-commit-config.yaml`).

```sh
make hooks                # install the hook
prek run --all-files      # run every check now, staged or not
git commit --no-verify    # skip it for one commit
```

Each hook only fires when a file it cares about is staged, so a docs-only commit pays for markdownlint and nothing else. One caveat: `shellcheck` and `npx` are skipped rather than failed when they are not installed locally, so a green hook on a machine without them says less than it looks like.

CI installs the exact shellcheck release named by `SHELLCHECK_VERSION` in the Makefile, because findings move between versions (an SC2218 that 0.9.0 reports, 0.11.0 does not). `make lint-sh` warns when your local shellcheck is a different version. To bump it, edit that variable and the `SHELLCHECK_SHA256` beside it, the sha256 of the new release's `linux.x86_64.tar.xz`, which CI checks before it installs anything.

## Ground rules

- **Target bash 3.2.** macOS ships `/bin/bash` 3.2, so no associative arrays, no namerefs, no `${var^^}`. When in doubt, test with `/bin/bash`.
- **One job per file.** `automatic-rename.sh` is the only file that talks to herdr. `naming.sh` takes strings and returns strings, with no herdr and no filesystem, which is what keeps the rules unit-testable. Anything that reads the filesystem gets a module of its own beside them, and the engine sources it. Functions carry the `ar_` prefix wherever they live.
- **Depend only on `jq` and the herdr CLI.** No other runtime dependencies.
- **Name the rule, not the inventory.** A doc that lists the files, the settings, or the checks is wrong on the day one is added, and nobody notices for a release. Say what the convention is and let the reader run `ls` for the rest.
- **No em dashes in comments or docs.**
- **A shellcheck suppression names its code and its reason.** `make lint` and CI both run `shellcheck -x` over the bash sources, and it passes clean. Where the linter is wrong about something deliberate, put `# shellcheck disable=SCxxxx` on the line or compound command it applies to, never at file scope, with a comment saying why the code is right. A sourced file whose path is computed gets `# shellcheck source=<the real file>` instead, so `-x` reads it rather than skipping it.
- **Never hard-wrap prose in markdown.** One paragraph per line. Release notes are copied out of `CHANGELOG.md` and GitHub soft-wraps prose itself, so a wrapped source ships its line breaks. CI enforces this with a custom markdownlint rule (`.github/markdownlint-rules/no-hard-wrap.js`); run it locally with `make lint-md`.
- **Keep changelog entries short.** Each entry in `CHANGELOG.md` is one line of one to three sentences that says what changed for the user. The release workflow copies these entries into the GitHub Release, so the reasoning goes in the commit message or `docs/ARCHITECTURE.md` instead. Credit an outside contribution as `([#N](link), thanks @user)`. A custom markdownlint rule (`.github/markdownlint-rules/concise-changelog.js`) enforces this in CI and in the pre-commit hook.
- **Don't credit a coding agent.** Leave agent `Co-authored-by` trailers, "Generated with" lines, and similar credits out of commits and PR descriptions. A human co-author still gets a trailer. Which tool helped does not matter to the history. You own the change, whoever typed it.

## Submitting

1. Fork and branch.
2. Make the change with a test.
3. Confirm `prek run --all-files` passes (CI runs the same checks, the suite on both Linux and macOS).
4. Open a pull request describing the behavior before and after.
