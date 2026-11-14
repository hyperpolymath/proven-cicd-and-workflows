#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Fixture runner for the proven lock kernel. Each case under
# tests/fixtures/proven-lock/<case>/ has repo/, optional oracle.json and
# `expected` (first line, then sorted REASON lines). UNJUDGED/WHY lines are
# not compared. Exit: 0 all ok, 1 a case failed, 2 NOT RUN (missing tool).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
fixtures="$here/fixtures/proven-lock"
export PATH="$HOME/.idris2/bin:$PATH"

notrun() { printf 'proven-lock tests: %s; NOT RUN\n' "$1" >&2; exit 2; }
if [[ -z ${PROVEN_LOCK_VERDICT:-} ]]; then
  command -v idris2 >/dev/null || notrun "idris2 is not installed"
fi
command -v jq >/dev/null || notrun "jq is not installed"
command -v yq >/dev/null || notrun "yq is not installed"
yq --version 2>/dev/null | grep -q mikefarah || notrun "mikefarah yq v4 is required"

# PROVEN_LOCK_VERDICT runs the corpus against a prebuilt binary, such as the
# gcc build of the shipped C (tests/proven-lock-dist.sh).
if [[ -n ${PROVEN_LOCK_VERDICT:-} ]]; then
  verdict=$PROVEN_LOCK_VERDICT
else
  (cd "$repo" && idris2 --build proven-lock.ipkg >/dev/null) || { echo "FAIL: the kernel does not build" >&2; exit 1; }
  verdict="$repo/build/exec/proven-lock-verdict"
fi
[[ -x $verdict ]] || notrun "kernel binary missing"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# observe ROOT [ORACLE] -> prints first line + sorted REASON lines
observe() {
  local root=$1 oracle=${2:-} facts="$tmp/facts.json" out rc
  local args=("$root")
  [[ -n $oracle ]] && args+=(--oracle "$oracle")
  set +e
  "$repo/scripts/extract-lock-facts.sh" "${args[@]}" > "$facts" 2>"$tmp/err"
  rc=$?
  if [[ $rc -eq 2 ]]; then
    set -e; echo NOT_RUN; return 0
  elif [[ $rc -ne 0 ]]; then
    set -e; echo "EXTRACTOR_EXIT_$rc"; return 0
  fi
  out=$("$verdict" "$facts" 2>/dev/null)
  set -e
  printf '%s\n' "$out" | head -n 1
  printf '%s\n' "$out" | tail -n +2 | grep -a '^REASON'$'\t' | LC_ALL=C sort || true
}

fail=0 count=0
for dir in "$fixtures"/*/; do
  name=$(basename "$dir")
  [[ -d $dir/repo && -f $dir/expected ]] || continue
  count=$((count + 1))
  oracle=
  [[ -f $dir/oracle.json ]] && oracle="$dir/oracle.json"
  # Fixture trees store their workflows under dot-github/, never .github/: they
  # are deliberately defective inputs, and at a .github/workflows path every
  # workflow scanner (SonarCloud, CodeQL, Hypatia) would read them as live.
  rm -rf -- "$tmp/case"
  cp -R "$dir/repo" "$tmp/case"
  [[ -d $tmp/case/dot-github ]] && mv "$tmp/case/dot-github" "$tmp/case/.github"
  observe "$tmp/case" "$oracle" > "$tmp/got"
  { head -n 1 "$dir/expected"; tail -n +2 "$dir/expected" | LC_ALL=C sort; } > "$tmp/want"
  if diff -u "$tmp/want" "$tmp/got" > "$tmp/diff"; then
    echo "ok $name"
  else
    echo "FAIL $name"
    sed 's/^/    /' "$tmp/diff"
    fail=1
  fi
done

[[ $count -gt 0 ]] || { echo "FAIL: no fixture cases found" >&2; exit 1; }

# --relock is edge-exact and never makes a lock worse (advisor review): with
# every managed entry replaced by its relocked entry,
#   (a) a CONSISTENT lock stays CONSISTENT, and no edge reason remains
#       (MissingTransitiveEdge, BlindEmptyEntry, StaleRef);
#   (b) every reason that is new is a DanglingRecord on a key `needs_records`
#       names, or an UnusedRecord; and the judge's UnusedRecord keys on the
#       relocked lock are exactly the run's `unused_records`;
#   * `needs_records` names exactly the relocked keys that no record keys, and
#     `unused_records` exactly the records nothing names any more, each checked
#     against an independent jq computation.
# Tested, not proven. Relock reads only the graph and the record keys
# (relockIgnoresEntries), so a second relock is not compared here: that
# comparison could not fail.
#
# relock_ok exits 0 conforms, 1 broken (reason on stdout), 3 skipped (reason on
# stdout): a fixture the extractor or relock refuses has nothing to check, and
# is counted as a skip, never as a pass. RELOCK_MUTATE, a jq filter over the
# --relock output (one array), plants a defect for the negative controls below.
relock_ok() { # CASE_ROOT
  local r1 out0 out1 v0 v1 newr needs want unused wunused judged
  "$repo/scripts/extract-lock-facts.sh" "$1" > "$tmp/facts.json" 2>/dev/null || { echo "the extractor refuses the fixture"; return 3; }
  r1=$("$verdict" --relock "$tmp/facts.json" 2>/dev/null) || { echo "relock refuses the fixture"; return 3; }
  r1=$(jq -s -c "${RELOCK_MUTATE:-.}" <<<"$r1") || { echo "mutation filter failed"; return 1; }
  jq --argjson r "$r1" '.entries |= map(.path as $p | ($r[] | select(.workflow == $p and .managed) | .keys) as $k | .keys = $k)' \
    "$tmp/facts.json" > "$tmp/relocked.json"
  # Capture first: under pipefail the verdict's exit 1 would mask grep's match.
  out0=$("$verdict" "$tmp/facts.json" 2>/dev/null) || true
  out1=$("$verdict" "$tmp/relocked.json" 2>/dev/null) || true
  v0=$(head -n 1 <<<"$out0"); v1=$(head -n 1 <<<"$out1")
  if grep -qE '^REASON	(MissingTransitiveEdge|BlindEmptyEntry|StaleRef)	' <<<"$out1"; then
    echo "an edge reason survives relock"; return 1
  fi
  [[ $v0 != CONSISTENT || $v1 == CONSISTENT ]] || { echo "relock turned a CONSISTENT lock $v1: $(grep '^REASON' <<<"$out1" | tr '\t\n' ' ;')"; return 1; }
  needs=$(jq -r '.[] | select(.managed) | .needs_records[]' <<<"$r1" | LC_ALL=C sort -u)
  want=$(jq -rn --slurpfile f "$tmp/facts.json" --argjson r "$r1" \
    '[$f[0].records[].key] as $k | [$r[] | select(.managed) | .keys[] | select(. as $x | $k | index($x) | not)] | unique[]')
  [[ $needs == "$want" ]] || { echo "needs_records [$needs] is not the unkeyed relocked keys [$want]"; return 1; }
  [[ $(jq '[.[] | select(has("unused_records"))] | length' <<<"$r1") == 1 ]] || { echo "not exactly one unused_records line"; return 1; }
  unused=$(jq -r '.[] | select(has("unused_records")) | .unused_records[]' <<<"$r1" | LC_ALL=C sort -u)
  wunused=$(jq -r '([.entries[].keys[]] + [.records[] | .uses | if type == "array" then .[] else empty end]) as $n
    | [.records[].key | select(. as $x | $n | index($x) | not)] | unique[]' "$tmp/relocked.json")
  [[ $unused == "$wunused" ]] || { echo "unused_records [$unused] is not the records nothing names [$wunused]"; return 1; }
  judged=$(grep -E '^REASON	UnusedRecord	' <<<"$out1" | cut -f3 | LC_ALL=C sort -u)
  [[ $judged == "$unused" ]] || { echo "the judge's UnusedRecord keys [$judged] are not unused_records [$unused]"; return 1; }
  newr=$(comm -13 <(grep '^REASON' <<<"$out0" | LC_ALL=C sort) <(grep '^REASON' <<<"$out1" | LC_ALL=C sort))
  while IFS=$'\t' read -r _ reason key _; do
    [[ -n $reason ]] || continue
    case $reason in
      DanglingRecord) grep -qxF -- "$key" <<<"$needs" || { echo "new DanglingRecord on $key, which needs_records does not name"; return 1; } ;;
      UnusedRecord) ;;   # checked above against unused_records, exactly
      *) echo "relock introduced $reason $key"; return 1 ;;
    esac
  done <<<"$newr"
}
# The fixtures relock cannot check, pinned: a new silent skip fails the suite.
expected_skips="missing-composite unparsable-workflow"
skips="" relock_ok_count=0
for dir in "$fixtures"/*/; do
  name=$(basename "$dir")
  [[ -d $dir/repo && -f $dir/expected ]] || continue
  rm -rf -- "$tmp/case"; cp -R "$dir/repo" "$tmp/case"
  [[ -d $tmp/case/dot-github ]] && mv "$tmp/case/dot-github" "$tmp/case/.github"
  rc=0; why=$(relock_ok "$tmp/case") || rc=$?
  case $rc in
    0) echo "ok relock $name"; relock_ok_count=$((relock_ok_count + 1)) ;;
    3) echo "skip relock $name: $why"; skips="$skips $name" ;;
    *) echo "FAIL relock $name: $why"; fail=1 ;;
  esac
done
[[ ${skips# } == "$expected_skips" ]] && echo "ok relock: $relock_ok_count fixtures checked; skipped exactly [$expected_skips]" ||
  { echo "FAIL relock: skipped [${skips# }], expected [$expected_skips]"; fail=1; }

# Negative controls for relock_ok itself, so the check above cannot go soft
# unseen: each planted defect in the relock output must be refused.
relock_mutant() { # FIXTURE NAME FILTER
  local rc=0
  rm -rf -- "$tmp/case"; cp -R "$fixtures/$1/repo" "$tmp/case"
  [[ -d $tmp/case/dot-github ]] && mv "$tmp/case/dot-github" "$tmp/case/.github"
  RELOCK_MUTATE=$3 relock_ok "$tmp/case" >/dev/null || rc=$?
  if [[ $rc == 1 ]]; then echo "ok relock control: $2 is refused"
  else echo "FAIL relock control: $2 was accepted (exit $rc)"; fail=1; fi
}
relock_mutant job-call-absent-ok 'an unrecorded job-call key appended to a relocked entry' \
  'map(if .managed and has("keys") then .keys += ["planted/unrecorded@v1"] else . end)'
relock_mutant composite-transitive-missing 'a needs_records element dropped' \
  'map(if has("needs_records") and (.needs_records | length) > 0 then .needs_records |= .[1:] else . end)'
relock_mutant dependabot-bump-stale-lock 'an unused_records element dropped' \
  'map(if has("unused_records") then .unused_records |= .[1:] else . end)'
relock_mutant ok-tag-keyed 'an unused_records line removed' 'map(select(has("unused_records") | not))'

# --json (the squabbler executor contract) must agree with the text verdict on
# every fixture: same exit code, every line valid JSON, one finding object per
# REASON line, and a final status object naming the same verdict.
json_agrees() { # CASE_ROOT ORACLE
  local oracle=$2 args=("$1") trc jrc text json
  [[ -n $oracle ]] && args+=(--oracle "$oracle")
  "$repo/scripts/extract-lock-facts.sh" "${args[@]}" > "$tmp/facts.json" 2>/dev/null || return 0
  text=$("$verdict" "$tmp/facts.json" 2>/dev/null) && trc=0 || trc=$?
  json=$("$verdict" --json "$tmp/facts.json" 2>/dev/null) && jrc=0 || jrc=$?
  [[ $trc == "$jrc" ]] || { echo "exit $trc vs $jrc"; return 1; }
  jq -e . >/dev/null <<<"$json" || { echo "invalid JSON"; return 1; }
  [[ $(jq -sr 'last.verdict' <<<"$json") == "$(head -n 1 <<<"$text")" ]] || { echo "verdict differs"; return 1; }
  [[ $(jq -s '[.[] | select(has("reason"))] | length' <<<"$json") == "$(grep -c '^REASON' <<<"$text" || true)" ]] || { echo "finding count differs"; return 1; }
  # Contents, not only counts (CodeRabbit on #100): the text REASON lines,
  # mapped independently to the executor contract, must equal the JSON
  # findings field by field. A swapped key/path or a misnamed reason fails.
  local want got
  want=$(grep -a '^REASON' <<<"$text" | awk -F'\t' 'BEGIN{OFS="\t"}
    function out(r,k,w,d){ print r, k, w, d }
    $2=="MissingTransitiveEdge"||$2=="StaleRef"||$2=="Tracking" { out($2,$4,$3,"-"); next }
    $2=="BlindEmptyEntry"||$2=="StaleEntry"||$2=="DuplicateEntry" { out($2,"-",$3,"-"); next }
    $2=="Moved" { out($2,$3,"-",$4); next }
    $2=="Illegal" { out($2,"-",$3,$4); next }
    { out($2,$3,"-","-") }' | LC_ALL=C sort)
  got=$(jq -r 'select(has("reason")) | [.reason, (.record_key // "-"), (.workflow_file // "-"), (.detail // "-")] | @tsv' <<<"$json" | LC_ALL=C sort)
  [[ $want == "$got" ]] || { echo "finding fields differ: $(diff <(echo "$want") <(echo "$got") | tr '\n' ' ')"; return 1; }
}
for dir in "$fixtures"/*/; do
  name=$(basename "$dir")
  [[ -d $dir/repo && -f $dir/expected ]] || continue
  rm -rf -- "$tmp/case"; cp -R "$dir/repo" "$tmp/case"
  [[ -d $tmp/case/dot-github ]] && mv "$tmp/case/dot-github" "$tmp/case/.github"
  oracle=; [[ -f $dir/oracle.json ]] && oracle="$dir/oracle.json"
  if why=$(json_agrees "$tmp/case" "$oracle"); then echo "ok json $name"; else echo "FAIL json $name: $why"; fail=1; fi
done

# The repository's own lock must be consistent.
self=$(observe "$repo")
if [[ $(printf '%s\n' "$self" | head -n 1) == CONSISTENT ]]; then
  echo "ok repository-root"
else
  echo "FAIL repository-root"
  printf '%s\n' "$self" | sed 's/^/    /'
  fail=1
fi

exit "$fail"
