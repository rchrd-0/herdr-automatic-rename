# herdr-automatic-rename developer tasks.

.PHONY: test lint

# Run the full test suite (needs bash + jq only).
test:
	@./tests/run.sh

# Skip only when ShellCheck is absent; findings must retain its failure status.
# The shell hooks are per-shell (zsh/fish), so check only the bash sources here.
lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s bash automatic-rename.sh naming.sh shell/hook.bash tests/*.sh; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi
