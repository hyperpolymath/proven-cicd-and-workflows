#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Negative controls for tests/registry-sq-map.sh: each planted defect in a copy
# of the map must fail the conformance test (exit 1); a missing cross-check
# input must be NOT RUN (exit 2). The unmodified map must pass.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
map=$root/proven/registry/sq-map.tsv
expect() { # NAME WANT [ENV...] -- runs the test on $tmp/map.tsv
  local name=$1 want=$2 rc=0; shift 2
  env SQ_MAP="$tmp/map.tsv" "$@" bash "$root/tests/registry-sq-map.sh" >"$tmp/log" 2>&1 || rc=$?
  [[ $rc == "$want" ]] || { cat "$tmp/log"; echo "FAIL $name: wanted $want, got $rc"; exit 1; }
  echo "ok: $name"
}
cp "$map" "$tmp/map.tsv"; expect 'the committed map conforms' 0
cp "$map" "$tmp/map.tsv"; grep -m1 '^hypatia/' "$map" >> "$tmp/map.tsv"
expect 'a duplicated A5 id fails' 1
cp "$map" "$tmp/map.tsv"; printf 'hypatia/x/y\tSQ-BAD\tmapped\tabsent\tnote\n' >> "$tmp/map.tsv"
expect 'a malformed SQ id fails' 1
cp "$map" "$tmp/map.tsv"; printf 'hypatia/x/y\tunassigned\tmapped\tabsent\tnote\n' >> "$tmp/map.tsv"
expect 'unassigned is refused outside kernel-reason rows' 1
cp "$map" "$tmp/map.tsv"; printf -- '-\tSQ-LOCK-02\tsquabbler-only\t-\tnote\n' >> "$tmp/map.tsv"
expect 'an SQ id both mapped and squabbler-only fails' 1
cp "$map" "$tmp/map.tsv"; printf 'hypatia/x/y\tSQ-LOCK-02\tmapped\tabsent\n' >> "$tmp/map.tsv"
expect 'a row with four fields fails' 1
printf 'SQ-LOCK-01\tFIX\nSQ-ZZZ-99\tFIX\n' > "$tmp/rules.tsv"
cp "$map" "$tmp/map.tsv"; expect 'a table/map mismatch fails' 1 SQUABBLER_RULES="$tmp/rules.tsv"
cp "$map" "$tmp/map.tsv"; expect 'a named but missing table is NOT RUN' 2 SQUABBLER_RULES="$tmp/absent.tsv"
printf 'hypatia/ci_failure_triage/pages_not_enabled\n' > "$tmp/praxis.deed"
cp "$map" "$tmp/map.tsv"; expect 'a praxis column that disagrees with the registry fails' 1 HYPATIA_PRAXIS="$tmp/praxis.deed"
# Reverse direction: a triage id the registry holds but the map lacks fails,
# and so does dropping one of the unmapped rows.
grep -oE 'hypatia/[a-z0-9_]+/[A-Za-z0-9_]+' "$map" | sort -u > "$tmp/praxis-all.deed"
cp "$map" "$tmp/map.tsv"; expect 'the committed map conforms to a registry of its own ids' 0 HYPATIA_PRAXIS="$tmp/praxis-all.deed"
{ cat "$tmp/praxis-all.deed"; echo hypatia/ci_failure_triage/brand_new_rule; } > "$tmp/praxis-new.deed"
cp "$map" "$tmp/map.tsv"; expect 'a triage id the registry adds but the map lacks fails' 1 HYPATIA_PRAXIS="$tmp/praxis-new.deed"
awk -F'\t' 'BEGIN{OFS="\t"} $3=="unmapped" && !done {done=1; next} {print}' "$map" > "$tmp/map.tsv"
expect 'dropping an unmapped row fails the reverse check' 1 HYPATIA_PRAXIS="$tmp/praxis-all.deed"
cp "$map" "$tmp/map.tsv"; printf 'hypatia/ci_failure_triage/zz\tSQ-LOCK-02\tunmapped\tabsent\tnote\n' >> "$tmp/map.tsv"
expect 'an unmapped row that names an SQ id fails' 1
cp "$map" "$tmp/map.tsv"; printf 'hypatia/workflow_audit/zz\tunassigned\tunmapped\tpresent\tnote\n' >> "$tmp/map.tsv"
expect 'an unmapped row outside ci_failure_triage fails' 1
cp "$map" "$tmp/map.tsv"; printf 'hypatia/ci_failure_triage/zz\tunassigned\tunmapped\tpresent\tnote\n' >> "$tmp/map.tsv"
expect 'an unmapped row that says present but the registry lacks fails' 1 HYPATIA_PRAXIS="$tmp/praxis-all.deed"
cp "$map" "$tmp/map.tsv"; printf 'hypatia/ci_failure_triage/zz\tunassigned\tunmapped\tabsent\tnote\n' >> "$tmp/map.tsv"
expect 'a pending row (unmapped, absent) that the registry lacks passes' 0 HYPATIA_PRAXIS="$tmp/praxis-all.deed"
cp "$map" "$tmp/map.tsv"; expect 'HYPATIA_PRAXIS_SOURCE other than 1 is NOT RUN' 2 HYPATIA_PRAXIS="$tmp/praxis-all.deed" HYPATIA_PRAXIS_SOURCE=yes
grep -v '^hypatia/workflow_audit/actions_lock_stale	' "$map" > "$tmp/map.tsv"
expect 'deleting a workflow_audit ADR mapping fails the reverse check' 1 HYPATIA_PRAXIS="$tmp/praxis-all.deed"
echo 'no ids here' > "$tmp/empty.deed"
cp "$map" "$tmp/map.tsv"; expect 'a registry with no A5 ids is NOT RUN, not a failure' 2 HYPATIA_PRAXIS="$tmp/empty.deed"
head -n 1 "$map" > "$tmp/map.tsv"; expect 'an empty map is NOT RUN' 2

# --- A new triage rule lands with nothing merged red (advisor, 2026-11-14).
# pin.deed is the registry at this repository's Hypatia pin, before the rule;
# pr.deed is the Hypatia change that adds it (and Hypatia main once it merges).
new=hypatia/ci_failure_triage/brand_new_rule
cp "$tmp/praxis-all.deed" "$tmp/pin.deed"
{ cat "$tmp/pin.deed"; echo "$new"; } > "$tmp/pr.deed"
cp "$map" "$tmp/map.tsv"
expect 'flow, before: the Hypatia change with no row fails its own CI' 1 HYPATIA_PRAXIS="$tmp/pr.deed" HYPATIA_PRAXIS_SOURCE=1
printf '%s\tunassigned\tunmapped\tpresent\tnote\n' "$new" >> "$tmp/map.tsv"
expect 'flow, the deadlock: a row added present fails here against the pin' 1 HYPATIA_PRAXIS="$tmp/pin.deed"
cp "$map" "$tmp/map.tsv"; printf '%s\tunassigned\tunmapped\tabsent\tnote\n' "$new" >> "$tmp/map.tsv"
expect 'flow, step 1: the row added absent (pending) passes here against the pin' 0 HYPATIA_PRAXIS="$tmp/pin.deed"
expect 'flow, step 2: the Hypatia change passes its own CI' 0 HYPATIA_PRAXIS="$tmp/pr.deed" HYPATIA_PRAXIS_SOURCE=1
grep -q "pending row $new lands with this change" "$tmp/log" && echo 'ok: flow, step 2 says the row lands with the change' || { echo 'FAIL flow, step 2 note missing'; exit 1; }
expect 'flow, step 3: after the merge the weekly run against Hypatia main passes' 0 HYPATIA_PRAXIS="$tmp/pr.deed" HYPATIA_PRAXIS_AT=head
grep -q "WARN pending row $new is in the registry now: flip" "$tmp/log" && echo 'ok: flow, step 3 warns to flip the column' || { echo 'FAIL flow, step 3 WARN missing'; exit 1; }
# The pin moves past the rule (the pinned registry now holds the id). Without
# the flip in the same change that is a FAIL, so the flip cannot be forgotten.
expect 'flow, step 4 without the flip: the pin moved past a pending row fails' 1 HYPATIA_PRAXIS="$tmp/pr.deed" HYPATIA_PRAXIS_AT=pin
grep -q "FAIL the pin has moved past $new: flip its praxis column to present" "$tmp/log" && echo 'ok: the failure names the row and the flip' || { echo 'FAIL pin-moved message missing'; exit 1; }
expect 'an unset HYPATIA_PRAXIS_AT behaves as pin' 1 HYPATIA_PRAXIS="$tmp/pr.deed"
grep -q "FAIL the pin has moved past $new" "$tmp/log" && echo 'ok: unset mode fails for the same reason' || { echo 'FAIL unset mode failed for another reason'; exit 1; }
expect 'a bad HYPATIA_PRAXIS_AT is NOT RUN' 2 HYPATIA_PRAXIS="$tmp/pr.deed" HYPATIA_PRAXIS_AT=main
expect 'the change own registry (HYPATIA_PRAXIS_SOURCE=1) is unchanged by the mode' 0 HYPATIA_PRAXIS="$tmp/pr.deed" HYPATIA_PRAXIS_SOURCE=1 HYPATIA_PRAXIS_AT=pin
sed -i "s#^$new\tunassigned\tunmapped\tabsent\t#$new\tunassigned\tunmapped\tpresent\t#" "$tmp/map.tsv"
grep -q "^$new	unassigned	unmapped	present	" "$tmp/map.tsv" || { echo 'FAIL flow, step 4 flip did not apply'; exit 1; }
expect 'flow, step 4: the flip, with the pin moved, passes' 0 HYPATIA_PRAXIS="$tmp/pr.deed"
! grep -q "pending row $new" "$tmp/log" && echo 'ok: flow, step 4 no longer reports the row as pending' || { echo 'FAIL flow, step 4 still pending'; exit 1; }
expect 'flow: a flip before the pin moves fails' 1 HYPATIA_PRAXIS="$tmp/pin.deed"

# --- Removing a mapped rule: the Hypatia change passes with a WARN, and the
# pin move that passes it fails until the column is set in the same change.
gone=hypatia/ci_failure_triage/pages_not_enabled
grep -vxF "$gone" "$tmp/praxis-all.deed" > "$tmp/removed.deed"
cp "$map" "$tmp/map.tsv"
expect 'removal: the Hypatia change that drops a mapped rule passes its own CI' 0 HYPATIA_PRAXIS="$tmp/removed.deed" HYPATIA_PRAXIS_SOURCE=1
grep -q "WARN $gone: praxis column says present" "$tmp/log" && echo 'ok: removal warns about the column' || { echo 'FAIL removal WARN missing'; exit 1; }
expect 'removal: a pin move past it without setting the column fails' 1 HYPATIA_PRAXIS="$tmp/removed.deed"
sed -i "s#^\($gone\t[^\t]*\tmapped\t\)present\t#\1absent\t#" "$tmp/map.tsv"
expect 'removal: the pin move with the column set to absent passes' 0 HYPATIA_PRAXIS="$tmp/removed.deed"
