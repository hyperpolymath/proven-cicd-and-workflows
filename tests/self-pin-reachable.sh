#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Controls for scripts/self-pin-reachable.sh, in a throwaway repository:
# a pin on the base passes; a pin to a commit only on a side branch, a pin to a
# commit not in the clone, and a shallow clone each refuse. Then the real check.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
check=$root/scripts/self-pin-reachable.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 fails=0
expect() { # want_rc label cmd...
  local want=$1 label=$2 rc=0; shift 2
  "$@" >"$tmp/out" 2>&1 || rc=$?
  if [[ $rc == "$want" ]]; then echo "  ok   $label (exit $rc)"; pass=$((pass + 1))
  else echo "  FAIL $label: want $want, got $rc"; sed 's/^/       /' "$tmp/out"; fails=$((fails + 1)); fi
}
r=$tmp/repo
git init -q -b main "$r"
g() { git -C "$r" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "$@"; }
mkdir -p "$r/.github/workflows"
echo base >"$r/f"; g add f; g commit -qm base
onmain=$(g rev-parse HEAD)
g checkout -q -b side; echo side >"$r/f"; g commit -qam side
offmain=$(g rev-parse HEAD)
g checkout -q main
w=$r/.github/workflows/w.yml
pin() { printf 'jobs: { a: { runs-on: x, steps: [ { uses: "hyperpolymath/proven-cicd-and-workflows/actions/x@%s" } ] } }\n' "$1" >"$w"; g add .github; }
run() { (cd "$r" && bash "$check" main); }
pin "$onmain";  expect 0 'a pin reachable from main passes' run
pin "$offmain"; expect 1 'a pin only on a side branch fails' run
pin 0123456789abcdef0123456789abcdef01234567; expect 1 'a pin not in the clone fails' run
pin "$onmain"
if (cd "$r" && bash "$check" main) | grep -q ': 1 pins checked'; then echo "  ok   the pin is counted"; pass=$((pass + 1))
else echo "  FAIL the pin is not counted"; fails=$((fails + 1)); fi
expect 2 'an unknown base is NOT RUN' bash -c "cd '$r' && bash '$check' no-such-ref"
git clone -q --depth 1 "file://$r" "$tmp/shallow"
expect 2 'a shallow clone is NOT RUN' bash -c "cd '$tmp/shallow' && bash '$check' origin/main"
expect 2 'outside a checkout is NOT RUN' bash -c "cd '$tmp' && bash '$check'"
echo "== this repository =="
expect 0 'every self-pin here is reachable from origin/main' bash -c "cd '$root' && bash '$check' origin/main"
if grep -qE ': [1-9][0-9]* pins checked' "$tmp/out"; then echo "  ok   $(tail -n1 "$tmp/out")"; pass=$((pass + 1))
else echo "  FAIL no self-pin was found here; the pattern is vacuous"; fails=$((fails + 1)); fi
echo "PASS=$pass FAIL=$fails"
[[ $fails == 0 ]]
