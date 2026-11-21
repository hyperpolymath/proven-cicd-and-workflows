#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Firing and silence fixtures for scripts/proven-shell-coverage.sh and
# scripts/proven-coverage-gate.sh.
#   tracer   a taken branch is hit, an untaken one is not; structure lines are
#            not statements; a multi-line command is one statement; exit codes
#            pass through
#   gate     silence on full coverage; UNCOVERED, STALE, MALFORMED,
#            COVERED-BUT-EXCLUDED and UNUSED-EXCLUSION each fire; line and fn
#            rows excuse; usage is exit 2
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tracer=$root/scripts/proven-shell-coverage.sh
gate=$root/scripts/proven-coverage-gate.sh
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL $*"; fail=1; }
verdict() { if [[ $1 == 0 ]]; then ok "$2"; else bad "$3"; fi; } # STATUS OK_TEXT FAIL_TEXT

mkdir -p "$tmp/repo"
cat >"$tmp/repo/probe.sh" <<'SH'
#!/usr/bin/env bash
x=${1:-}
if [[ $x == yes ]]; then
  echo taken
else
  echo untaken
fi
y=$(printf '%s' "a" |
  tr a A)
exit 3
# visit_never
SH
printf '%s\n' '#!/usr/bin/env bash' >"$tmp/repo/other.sh"
(cd "$tmp/repo" && bash "$tracer" run "$tmp/trace" bash probe.sh yes >/dev/null) && rc=0 || rc=$?
[[ $rc == 3 ]]; verdict $? "tracer passes the exit code through" "tracer exit $rc, want 3"
(cd "$tmp/repo" && bash "$tracer" lcov . "$tmp/trace" probe.sh) >"$tmp/probe.lcov"
want=$'SF:probe.sh\nDA:2,1\nDA:3,1\nDA:4,1\nDA:6,0\nDA:8,1\nDA:10,1\nLF:6\nLH:5\nend_of_record'
[[ $(cat "$tmp/probe.lcov") == "$want" ]]; verdict $? "tracer statements and hits" "tracer lcov: $(tr '\n' ' ' <"$tmp/probe.lcov")"
bash "$tracer" lcov 2>/dev/null && rc=0 || rc=$?
[[ $rc == 2 ]]; verdict $? "tracer usage is exit 2" "tracer usage exit $rc"
bash "$tracer" bogus a b 2>/dev/null && rc=0 || rc=$?
[[ $rc == 2 ]]; verdict $? "tracer unknown mode is exit 2" "tracer unknown mode exit $rc"

sha() { sed -n "$2p" "$tmp/repo/$1" | sha256sum | cut -c1-12; }
lcov=$tmp/probe.lcov
printf 'SF:%s\nFNDA:0,_RNvXs_crate_visit_never\nFNDA:4,_RNvXs_crate_visit_often\nend_of_record\n' "$tmp/repo/probe.sh" >"$tmp/fn.lcov"
expect() { # NAME WANT_RC WANT_FINDING EXCLUSIONS_TEXT LCOV...
  local name=$1 want=$2 finding=$3 rows=$4; shift 4
  printf '%b' "$rows" >"$tmp/ex.tsv"
  local rc=0
  bash "$gate" "$tmp/repo" "$tmp/ex.tsv" "$@" >"$tmp/out" 2>&1 || rc=$?
  if [[ $rc == "$want" ]] && grep -q -- "$finding" "$tmp/out"; then ok "$name"; else bad "$name: exit $rc; $(tr '\n' ' ' <"$tmp/out")"; fi
}
line6="probe.sh\tline:6:$(sha probe.sh 6)"
expect "silence: excused line and fn" 0 "findings=0" \
  "$line6\tunreachable\tfixture\nprobe.sh\tfn:visit_never\tunreachable\tfixture\n" "$lcov" "$tmp/fn.lcov"
expect "fires: UNCOVERED line" 1 $'UNCOVERED\tprobe.sh\tline:6' "" "$lcov"
expect "fires: UNCOVERED fn" 1 "UNCOVERED.*fn:_RNvXs_crate_visit_never" "$line6\tunreachable\tfixture\n" "$lcov" "$tmp/fn.lcov"
expect "fires: STALE line" 1 "STALE" "probe.sh\tline:6:000000000000\tunreachable\tfixture\n" "$lcov"
expect "fires: STALE fn" 1 "STALE" "$line6\tunreachable\tx\nprobe.sh\tfn:not_in_source\tunreachable\tx\n" "$lcov"
expect "fires: MALFORMED kind" 1 "MALFORMED" "$line6\tmaybe\tfixture\n" "$lcov"
expect "fires: MALFORMED reason" 1 "MALFORMED" "$line6\tunreachable\t\n" "$lcov"
expect "fires: COVERED-BUT-EXCLUDED" 1 "COVERED-BUT-EXCLUDED" "$line6\tunreachable\tx\nprobe.sh\tline:4:$(sha probe.sh 4)\tunreachable\tx\n" "$lcov"
expect "fires: UNUSED-EXCLUSION" 1 "UNUSED-EXCLUSION" "$line6\tunreachable\tx\nother.sh\tline:1:$(sha probe.sh 1)\tunreachable\tx\n" "$lcov"
expect "fires: MALFORMED retired debt kind" 1 "MALFORMED" "$line6\tdebt\tx\n" "$lcov"
expect "usage: no report is exit 2" 2 "no report" "" "$tmp/missing.lcov"
exit "$fail"
