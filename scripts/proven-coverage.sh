#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven-coverage.sh OUT_DIR
#
# The whole-repository counted-coverage run for this suite.
#   1. actionlint over every workflow (.github/actionlint.yaml scopes each ignore).
#   2. Every test (tests/*.sh, actions/*/test.sh) under bash tracing; the
#      firing and silence fixtures they hold are the counted shell evidence.
#      A test that exits 2 did not run (a missing toolchain); it is listed as
#      NOT RUN and fails the run, because a test that did not run is no evidence.
#      Tests read /dev/null on stdin, so none can consume the test list.
#   3. proven-coverage-gate.sh over the shell report, with .proven/coverage-exclusions.tsv
#      (written exclusions). There is no debt list: every uncovered statement fails.
# Writes OUT_DIR/{shell.lcov,tests.tsv,trace}. The Rust crate under actions/creusot-check
# is measured by its own gate, not here. Exit 1 when a test
# fails, actionlint reports, or the gate has findings; 2 on usage errors.
# Idris2 (src/**/*.idr) is not measured here; see .proven/README.adoc.
set -euo pipefail
(($# == 1)) || { echo "usage: proven-coverage.sh OUT_DIR" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mkdir -p "$1" && cd "$1" && pwd)
cd "$root"
fail=0
command -v actionlint >/dev/null || { echo "proven-coverage: actionlint missing; NOT RUN" >&2; exit 2; }
actionlint || { echo "FAIL actionlint"; fail=1; }

rm -f -- "$out/trace"
: >"$out/tests.tsv"
while IFS= read -r test; do
  rc=0
  log=$out/log.${test//\//_}
  bash scripts/proven-shell-coverage.sh run "$out/trace" bash "$test" </dev/null >"$log" 2>&1 || rc=$?
  printf '%s\t%s\n' "$rc" "$test" >>"$out/tests.tsv"
  case $rc in
    0) ;;
    2) echo "NOT RUN $test (exit 2; see $log)"; fail=1 ;;
    *) echo "FAIL $test (exit $rc; see $log)"; fail=1 ;;
  esac
done < <(git ls-files 'tests/*.sh' 'actions/*/test.sh' | grep -v '^tests/fixtures/')

mapfile -t scripts < <(git ls-files '*.sh' | grep -v '^tests/' | grep -vE '(^|/)([a-z0-9-]+-)?test\.sh$')
bash scripts/proven-shell-coverage.sh lcov . "$out/trace" "${scripts[@]}" >"$out/shell.lcov"

cp .proven/coverage-exclusions.tsv "$out/exclusions.tsv"
bash scripts/proven-coverage-gate.sh "$root" "$out/exclusions.tsv" "$out/shell.lcov" || fail=1
exit "$fail"
