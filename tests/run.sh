#!/usr/bin/env bash
# Run every tests/test_*.sh and aggregate. Exit non-zero if any file fails.
#
#   ./tests/run.sh            # run all
#   ./tests/run.sh naming     # run only files matching *naming*
#   ./tests/run.sh --serial   # one file at a time, output as it happens
#
# Every file sandboxes itself under mktemp, so the files run at once and the
# wall time is the slowest file rather than the sum of them. test_lock.sh is
# the exception: it races six contenders on sleep-timed handoffs and must not
# share the machine, so it runs alone once the batch is done. A file that needs
# the same goes beside it below. --serial is for chasing an interaction the
# parallel run hides.
#
# No dependencies beyond bash and jq (same as the plugin itself).

here=$(cd "$(dirname "$0")" && pwd)
serial=0
filter=""
for arg in "$@"; do
  case "$arg" in
    --serial) serial=1 ;;
    *)        filter=$arg ;;
  esac
done
fail=0
ran=0

# Each parallel file writes its own log, so concurrent output never interleaves
# and the report below can come out in name order whatever order they finished.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hal-run.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# run_one <file> <name>: run a test file into its log, exit status beside it.
run_one() {
  bash "$1" >"$tmp/$2.out" 2>&1
  echo $? >"$tmp/$2.rc"
}

lock_test=""
for t in "$here"/test_*.sh; do
  [ -f "$t" ] || continue
  n=$(basename "$t")
  case "$n" in *"$filter"*) ;; *) continue ;; esac
  ran=$(( ran + 1 ))
  if [ "$serial" = "1" ]; then
    printf '\n# ==== %s ====\n' "$n"
    bash "$t" || fail=1
  elif [ "$n" = "test_lock.sh" ]; then
    lock_test=$t
  else
    run_one "$t" "$n" &
  fi
done
wait
if [ -n "$lock_test" ]; then
  run_one "$lock_test" "$(basename "$lock_test")"
fi

# Empty on a serial run, which has already printed everything.
for out in "$tmp"/*.out; do
  [ -f "$out" ] || continue
  n=$(basename "$out" .out)
  printf '\n# ==== %s ====\n' "$n"
  cat "$out"
  [ "$(cat "$tmp/$n.rc")" = "0" ] || fail=1
done

printf '\n'
if [ "$ran" -eq 0 ]; then
  echo "# no test files matched '$filter'"
  exit 1
fi
if [ "$fail" -eq 0 ]; then
  echo "# ALL TESTS PASSED"
else
  echo "# SOME TESTS FAILED"
fi
exit "$fail"
