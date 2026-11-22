#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven-coverage-gate.sh ROOT EXCLUSIONS LCOV...
#
# The counted-coverage gate. Every DA line and every FNDA function in the given
# LCOV reports must be hit by counted evidence, or be written down in EXCLUSIONS
# (tab-separated: path, unit, kind, reason), where unit is one of
#   line:N:SHA12   line N of path; SHA12 is the first 12 hex of the line's sha256
#   fn:NAME        a function whose LCOV name ends with NAME
# and kind is unreachable or environment, with a reason. Paths are relative to ROOT. An LCOV
# path matches only the file the row pins: the same repo-relative path (a leading ./ is
# ignored), or ROOT/path as an absolute path. So probe.sh never excuses actions/a/probe.sh.
# Findings (one per line, then a SUMMARY line):
#   UNCOVERED            a counted line or function nobody hit and nobody excused
#   STALE                an exclusion whose line text or function name has moved
#   MALFORMED            an exclusion row that does not parse
#   COVERED-BUT-EXCLUDED an exclusion the evidence now reaches; delete the row
#   UNUSED-EXCLUSION     an exclusion that matches nothing in the reports
#   EMPTY                the reports hold no DA or FNDA record, so nothing was measured
# Exit 0 when there are no findings, 1 when there are, 2 on usage errors.
set -euo pipefail
(($# >= 3)) || { echo "usage: proven-coverage-gate.sh ROOT EXCLUSIONS LCOV..." >&2; exit 2; }
root=$1 exclusions=$2; shift 2
[[ -d $root && -f $exclusions ]] || { echo "proven-coverage-gate: ROOT or EXCLUSIONS missing" >&2; exit 2; }
for report in "$@"; do
  [[ -f $report ]] || { echo "proven-coverage-gate: no report $report" >&2; exit 2; }
done

# Resolve each line exclusion's current text hash, so awk can compare.
resolved=$(mktemp)
trap 'rm -f -- "$resolved"' EXIT
while IFS=$'\t' read -r path unit kind reason; do
  [[ -z $path || $path == \#* ]] && continue
  current=-
  if [[ $unit =~ ^line:([0-9]+):[0-9a-f]{12}$ && -f $root/$path ]]; then
    current=$(sed -n "${BASH_REMATCH[1]}p" "$root/$path" | sha256sum | cut -c1-12)
  elif [[ $unit =~ ^fn:([A-Za-z_][A-Za-z0-9_]*)$ && -f $root/$path ]]; then
    grep -qF -- "${BASH_REMATCH[1]}" "$root/$path" && current=present
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$unit" "$kind" "${reason:-}" "$current"
done <"$exclusions" >"$resolved"

rc=0
abs=$(cd -- "$root" && pwd -L) real=$(cd -- "$root" && pwd -P)
awk -F'\t' -v exclusions="$resolved" -v abs="$abs" -v real="$real" '
  BEGIN {
    while ((getline row < exclusions) > 0) {
      split(row, x, "\t"); exclusion(x[1], x[2], x[3], x[4], x[5])
    }
  }
  function exclusion(path, unit, kind, reason, current) {
    if (kind !~ /^(unreachable|environment)$/ || reason == "" || unit !~ /^(line:[0-9]+:[0-9a-f]{12}|fn:[A-Za-z_][A-Za-z0-9_]*)$/) {
      print "MALFORMED\t" path "\t" unit; bad++; return
    }
    split(unit, u, ":")
    if (u[1] == "line" && current != u[3]) { print "STALE\t" path "\t" unit; bad++; return }
    if (u[1] == "fn" && current != "present") { print "STALE\t" path "\t" unit; bad++; return }
    n++; ex_path[n] = path; ex_unit[n] = unit; ex_used[n] = 0
  }
  /^SF:/ { file = substr($0, 4); sub(/^(\.\/)+/, "", file); next }
  /^DA:/ || /^FNDA:/ {
    split(substr($0, index($0, ":") + 1), f, ",")
    if (/^DA:/) { what = "line"; key = f[1]; hits = f[2] } else { what = "fn"; key = f[2]; hits = f[1] }
    if (what == "line") lines++; else fns++
    excused = 0
    for (i = 1; i <= n; i++) {
      if (file != ex_path[i] && file != abs "/" ex_path[i] && file != real "/" ex_path[i]) continue
      split(ex_unit[i], u, ":")
      if (u[1] != what) continue
      if (what == "line" && u[2] != key) continue
      if (what == "fn" && substr(key, length(key) - length(u[2]) + 1) != u[2]) continue
      excused = 1; ex_used[i] = 1
      if (hits > 0) { print "COVERED-BUT-EXCLUDED\t" ex_path[i] "\t" ex_unit[i]; bad++ }
    }
    if (hits > 0) covered++
    else if (excused) excluded++
    else { print "UNCOVERED\t" file "\t" what ":" key; bad++ }
  }
  END {
    if (lines + fns == 0) { print "EMPTY\tno DA or FNDA record in the reports"; bad++ }
    for (i = 1; i <= n; i++) if (!ex_used[i]) { print "UNUSED-EXCLUSION\t" ex_path[i] "\t" ex_unit[i]; bad++ }
    printf "SUMMARY lines=%d functions=%d covered=%d excluded=%d findings=%d\n", lines, fns, covered, excluded, bad
    exit bad > 0
  }
' "$@" | tee "$resolved.out" || rc=$?
rm -f -- "$resolved.out"
exit "$rc"
