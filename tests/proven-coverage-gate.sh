#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Firing and silence fixtures for scripts/proven-shell-coverage.sh and
# scripts/proven-coverage-gate.sh.
#   tracer   a taken branch is hit, an untaken one is not; structure lines are
#            not statements; a multi-line command is one statement; exit codes
#            pass through; <<< , 1<<n, a quoted "<<EOF" and an escaped \<<EOF
#            open no here-document; a punctuated delimiter (EOF-JSON) closes;
#            a file without a final newline keeps the next file's record
#   gate     silence on full coverage; UNCOVERED, STALE, MALFORMED,
#            COVERED-BUT-EXCLUDED, UNUSED-EXCLUSION and EMPTY each fire; line and
#            fn rows excuse; an exclusion matches whole path components only;
#            usage is exit 2
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tracer=$root/scripts/proven-shell-coverage.sh
gate=$root/scripts/proven-coverage-gate.sh
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL $*"; fail=1; }
# check OK_TEXT FAIL_TEXT CMD...: runs CMD inside if, so a false CMD reports
# FAIL instead of ending the script under set -e.
check() { local yes=$1 no=$2; shift 2; if "$@"; then ok "$yes"; else bad "$no"; fi; }

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
check "tracer passes the exit code through" "tracer exit $rc, want 3" test "$rc" = 3
(cd "$tmp/repo" && bash "$tracer" lcov . "$tmp/trace" probe.sh) >"$tmp/probe.lcov"
want=$'SF:probe.sh\nDA:2,1\nDA:3,1\nDA:4,1\nDA:6,0\nDA:8,1\nDA:10,1\nLF:6\nLH:5\nend_of_record'
check "tracer statements and hits" "tracer lcov: $(tr '\n' ' ' <"$tmp/probe.lcov")" test "$(cat "$tmp/probe.lcov")" = "$want"
bash "$tracer" lcov 2>/dev/null && rc=0 || rc=$?
check "tracer usage is exit 2" "tracer usage exit $rc" test "$rc" = 2
bash "$tracer" bogus a b 2>/dev/null && rc=0 || rc=$?
check "tracer unknown mode is exit 2" "tracer unknown mode exit $rc" test "$rc" = 2

# Not here-documents: a here-string, two shifts and a quoted <<EOF. Each later
# line must stay a statement (a false here-document would swallow them).
cat >"$tmp/repo/shifts.sh" <<'SH'
#!/usr/bin/env bash
cat <<< word
n=$((1<<n))
(( m = 1 << shift ))
k=$(( (1<<n) + 1 ))
echo "x <<EOF"
echo after
SH
: >"$tmp/empty-trace"
bash "$tracer" lcov "$tmp/repo" "$tmp/empty-trace" shifts.sh >"$tmp/shifts.lcov"
want=$'SF:shifts.sh\nDA:2,0\nDA:3,0\nDA:4,0\nDA:5,0\nDA:6,0\nDA:7,0\nLF:6\nLH:0\nend_of_record'
check "tracer: <<<, shifts and a quoted <<EOF open no here-document" "tracer lcov: $(tr '\n' ' ' <"$tmp/shifts.lcov")" \
  test "$(cat "$tmp/shifts.lcov")" = "$want"

cat >"$tmp/repo/redirected-loops.sh" <<'SH'
#!/usr/bin/env bash
while read -r word; do
  echo "$word"
done <<< space
while read -r word; do
  echo "$word"
done	<<< tab
SH
bash "$tracer" run "$tmp/trace" bash "$tmp/repo/redirected-loops.sh" >/dev/null
bash "$tracer" lcov "$tmp/repo" "$tmp/trace" redirected-loops.sh >"$tmp/redirected-loops.lcov"
want=$'SF:redirected-loops.sh\nDA:2,1\nDA:3,1\nDA:5,1\nDA:6,1\nLF:4\nLH:4\nend_of_record'
check "tracer: loop terminators with space or tab before redirection are structural" \
  "tracer lcov: $(tr '\n' ' ' <"$tmp/redirected-loops.lcov")" test "$(cat "$tmp/redirected-loops.lcov")" = "$want"

# CodeRabbit round 4: a command after fi; stays counted, a spaced case
# pattern is not a statement, and two here-documents on one command are
# both read as data before scanning resumes.
cat >"$tmp/repo/round4.sh" <<'SH'
#!/usr/bin/env bash
if true; then
  exit 0
fi; echo never
case $1 in
  x | y)
    echo xy ;;
esac
cat <<A <<B
a
A
"
B
echo reached
SH
bash "$tracer" lcov "$tmp/repo" "$tmp/empty-trace" round4.sh >"$tmp/round4.lcov"
want=$'SF:round4.sh\nDA:2,0\nDA:3,0\nDA:4,0\nDA:5,0\nDA:7,0\nDA:9,0\nDA:14,0\nLF:7\nLH:0\nend_of_record'
check "tracer: fi; cmd, a spaced case pattern and two here-documents" "tracer lcov: $(tr '\n' ' ' <"$tmp/round4.lcov")" \
  test "$(cat "$tmp/round4.lcov")" = "$want"
# CodeRabbit round 5: tabs separate tokens as spaces do. A terminator, a
# function header and a case pattern with tabs are still structure.
printf '%s\n' '#!/usr/bin/env bash' 'for i in 1; do' '  echo loop' $'done\t>/dev/null' \
  'for j in 1; do' '  echo spaced' 'done >/dev/null' $'f()\t{' '  echo body' '}' \
  'case $1 in' $'  x\t|\ty)' '    echo xy ;;' 'esac' >"$tmp/repo/round5.sh"
bash "$tracer" lcov "$tmp/repo" "$tmp/empty-trace" round5.sh >"$tmp/round5.lcov"
want=$'SF:round5.sh\nDA:2,0\nDA:3,0\nDA:5,0\nDA:6,0\nDA:9,0\nDA:11,0\nDA:13,0\nLF:7\nLH:0\nend_of_record'
check "tracer: tabs before a terminator redirection, a function brace and a | are structure" "tracer lcov: $(tr '\n' ' ' <"$tmp/round5.lcov")" \
  test "$(cat "$tmp/round5.lcov")" = "$want"
# A subshell line is a statement; only a line where a case pattern may
# start (after case ... in or ;;) is a pattern list.
printf '%s\n' '#!/usr/bin/env bash' 'if false; then' '  (echo)' 'fi' \
  'case $1 in' '  a | b)' '    (echo ab)' '    case $2 in' '      c) echo c ;;' \
  '    esac ;;' '  (d)' '    echo d' '    ;;' 'esac' >"$tmp/repo/subshell.sh"
bash "$tracer" lcov "$tmp/repo" "$tmp/empty-trace" subshell.sh >"$tmp/subshell.lcov"
want=$'SF:subshell.sh\nDA:2,0\nDA:3,0\nDA:5,0\nDA:7,0\nDA:8,0\nDA:9,0\nDA:12,0\nLF:7\nLH:0\nend_of_record'
check "tracer: a subshell is a statement outside a case pattern position" "tracer lcov: $(tr '\n' ' ' <"$tmp/subshell.lcov")" \
  test "$(cat "$tmp/subshell.lcov")" = "$want"
# case may follow then or do on its line, and esac may follow ;; or end a
# chain such as esac; done. A full traced run then covers every statement.
cat >"$tmp/repo/inline-case.sh" <<'SH'
#!/usr/bin/env bash
if true; then case x in
  x)
    echo reached
    ;;
esac
fi
for v in a; do case $v in
  (a | b)
    echo "$v" ;;
esac; done
case y in
  y) echo y ;; esac
(echo sub)
SH
bash "$tracer" run "$tmp/inline-trace" bash "$tmp/repo/inline-case.sh" >/dev/null
bash "$tracer" lcov "$tmp/repo" "$tmp/inline-trace" inline-case.sh >"$tmp/inline-case.lcov"
want=$'SF:inline-case.sh\nDA:2,1\nDA:4,1\nDA:8,1\nDA:10,1\nDA:12,1\nDA:13,1\nDA:14,1\nLF:7\nLH:7\nend_of_record'
check "tracer: case after then or do, and esac after ;; or before ; done, are structure" \
  "tracer lcov: $(tr '\n' ' ' <"$tmp/inline-case.lcov")" test "$(cat "$tmp/inline-case.lcov")" = "$want"
cat >"$tmp/repo/heredoc.sh" <<'SH'
#!/usr/bin/env bash
cat <<EOF
text
EOF
echo after
SH
bash "$tracer" lcov "$tmp/repo" "$tmp/empty-trace" heredoc.sh >"$tmp/heredoc.lcov"
want=$'SF:heredoc.sh\nDA:2,0\nDA:5,0\nLF:2\nLH:0\nend_of_record'
check "tracer: a real here-document is one statement" "tracer lcov: $(tr '\n' ' ' <"$tmp/heredoc.lcov")" \
  test "$(cat "$tmp/heredoc.lcov")" = "$want"
# A punctuated delimiter closes at its full word; an escaped \<<EOF is an
# input redirection, not a here-document.
cat >"$tmp/repo/delims.sh" <<'SH'
#!/usr/bin/env bash
cat <<'EOF-JSON'
{"a": 1}
EOF-JSON
cat <<-"END.TXT"
	text
	END.TXT
cat \<<EOF
echo after
SH
bash "$tracer" lcov "$tmp/repo" "$tmp/empty-trace" delims.sh >"$tmp/delims.lcov"
want=$'SF:delims.sh\nDA:2,0\nDA:5,0\nDA:8,0\nDA:9,0\nLF:4\nLH:0\nend_of_record'
check "tracer: a punctuated delimiter closes and an escaped \\<< opens nothing" "tracer lcov: $(tr '\n' ' ' <"$tmp/delims.lcov")" \
  test "$(cat "$tmp/delims.lcov")" = "$want"
printf '%s\n%s' '#!/usr/bin/env bash' 'echo a' >"$tmp/repo/nonl.sh"
bash "$tracer" lcov "$tmp/repo" "$tmp/empty-trace" nonl.sh heredoc.sh >"$tmp/nonl.lcov"
check "tracer: a file without a final newline keeps the next record" "tracer lcov: $(tr '\n' ' ' <"$tmp/nonl.lcov")" \
  grep -qx 'SF:heredoc.sh' "$tmp/nonl.lcov"
# A case opener may carry its first arm; the next pattern is still structure.
cat >"$tmp/repo/arm-case.sh" <<'SH'
#!/usr/bin/env bash
for a in x y; do
  case "$a" in x) echo x ;;
    y)
      echo y ;;
  esac
done
case z in z) echo z ;; esac
SH
bash "$tracer" run "$tmp/arm-trace" bash "$tmp/repo/arm-case.sh" >/dev/null
bash "$tracer" lcov "$tmp/repo" "$tmp/arm-trace" arm-case.sh >"$tmp/arm-case.lcov"
want=$'SF:arm-case.sh\nDA:2,1\nDA:3,1\nDA:5,1\nDA:8,1\nLF:4\nLH:4\nend_of_record'
check "tracer: a case opener with an inline first arm leaves later patterns as structure" \
  "tracer lcov: $(tr '\n' ' ' <"$tmp/arm-case.lcov")" test "$(cat "$tmp/arm-case.lcov")" = "$want"
# A here-document body line that reads FILE, a tab, and nothing else is source
# text, not a file boundary, so the unexecuted line after exit stays uncovered.
printf '%s\n' '#!/usr/bin/env bash' 'cat <<EOF' $'FILE\t' 'EOF' 'exit 0' 'echo never' >"$tmp/repo/marker.sh"
bash "$tracer" run "$tmp/marker-trace" bash "$tmp/repo/marker.sh" >/dev/null
bash "$tracer" lcov "$tmp/repo" "$tmp/marker-trace" marker.sh >"$tmp/marker.lcov"
want=$'SF:marker.sh\nDA:2,1\nDA:5,1\nDA:6,0\nLF:3\nLH:2\nend_of_record'
check "tracer: source text cannot pass for a file boundary" \
  "tracer lcov: $(tr '\n' ' ' <"$tmp/marker.lcov")" test "$(cat "$tmp/marker.lcov")" = "$want"
# A traced nested/same.sh credits only itself, never a requested same.sh;
# an unmodified copy run from another directory still credits same.sh.
mkdir -p "$tmp/repo/nested" "$tmp/copy"
printf '%s\n' '#!/usr/bin/env bash' 'echo same' | tee "$tmp/repo/same.sh" "$tmp/copy/same.sh" >"$tmp/repo/nested/same.sh"
bash "$tracer" run "$tmp/nested-trace" bash "$tmp/repo/nested/same.sh" >/dev/null
bash "$tracer" lcov "$tmp/repo" "$tmp/nested-trace" same.sh nested/same.sh >"$tmp/nested.lcov"
want=$'SF:same.sh\nDA:2,0\nLF:1\nLH:0\nend_of_record\nSF:nested/same.sh\nDA:2,1\nLF:1\nLH:1\nend_of_record'
check "tracer: a nested trace path is not credited to a shorter requested file" \
  "tracer lcov: $(tr '\n' ' ' <"$tmp/nested.lcov")" test "$(cat "$tmp/nested.lcov")" = "$want"
bash "$tracer" run "$tmp/copy-trace" bash "$tmp/copy/same.sh" >/dev/null
bash "$tracer" lcov "$tmp/repo" "$tmp/copy-trace" same.sh nested/same.sh >"$tmp/copy.lcov"
check "tracer: an unmodified copy elsewhere still credits the original" \
  "tracer lcov: $(tr '\n' ' ' <"$tmp/copy.lcov")" grep -qzP 'SF:same.sh\nDA:2,1\n' "$tmp/copy.lcov"

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
: >"$tmp/empty.lcov"
expect "fires: EMPTY report" 1 "EMPTY" "" "$tmp/empty.lcov"
printf 'SF:xprobe.sh\nDA:6,0\nend_of_record\n' >"$tmp/xprobe.lcov"
expect "fires: exclusion does not match a longer file name" 1 $'UNCOVERED\txprobe.sh\tline:6' "$line6\tunreachable\tx\n" "$tmp/xprobe.lcov"
printf 'SF:actions/a/probe.sh\nDA:6,0\nend_of_record\n' >"$tmp/deeper.lcov"
expect "fires: exclusion for probe.sh does not excuse actions/a/probe.sh" 1 $'UNCOVERED\tactions/a/probe.sh\tline:6' "$line6\tunreachable\tx\n" "$lcov" "$tmp/deeper.lcov"
printf 'SF:./probe.sh\nDA:6,0\nend_of_record\n' >"$tmp/dot.lcov"
expect "silence: ./probe.sh is the pinned file" 0 "findings=0" "$line6\tunreachable\tx\n" "$tmp/dot.lcov"
printf 'SF:/elsewhere/probe.sh\nDA:6,0\nend_of_record\n' >"$tmp/abs.lcov"
expect "fires: absolute path outside ROOT is not excused" 1 $'UNCOVERED\t/elsewhere/probe.sh\tline:6' "$line6\tunreachable\tx\n" "$lcov" "$tmp/abs.lcov"
exit "$fail"
