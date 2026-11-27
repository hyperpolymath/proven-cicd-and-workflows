#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The zero-test parser behind scripts/proven-run.sh must accept a counted run and refuse a vacuous one.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0 n=0
check() {  # check WANT-EXIT LANG PRINTF-TEXT
  local want=$1 lang=$2 text=$3 d rc
  d=$(mktemp -d)
  rc=0; LANGS=$lang bash scripts/proven-run.sh unit "$lang" "$d" "printf '%b' '$text'" >/dev/null 2>&1 || rc=$?
  rm -rf "$d"; n=$((n + 1))
  if [[ $rc -eq $want ]]; then echo "  ok   $lang: $text" ; else echo "  FAIL $lang: $text (exit $rc, want $want)"; fail=1; fi
}
check 0 all 'ok - p2p: every seam check passed\n'
check 0 all 'unit: 5 tests run\n'
check 0 all 'running 3 tests\n'
check 0 all 'ok  \tpkg\t0.02s\n'
check 1 all 'echo test 1\n'
check 1 all 'ok\n'
check 1 all 'testing: warning: no tests to run\nPASS\n'
check 1 all 'ok  \tpkg\t0.02s [no tests to run]\n'
check 1 all 'nothing useful\n'
check 0 all ' 4 pass\n 0 fail\nRan 4 tests across 1 file.\n'
check 0 all 'Ran 4 tests across 1 file.\n'
check 1 all ' 0 pass\n 0 fail\n'
check 0 shell 'ok - one\nok - two\n'
check 0 shell '1..2\nok 1\nok 2\n'
check 1 shell 'ok\n'
check 1 shell 'PASS\n'
check 1 shell 'echo ok\n'
check 0 zig 'Build Summary: 3/3 steps succeeded; 2/2 tests passed\n'
check 1 zig 'Build Summary: 3/3 steps succeeded\n'
check 1 weirdlang 'ok - x\n'
echo "proven-run-parser: $n checks"
(( fail == 0 )) && echo "ok - proven-run-parser: every parser check passed"; exit "$fail"
