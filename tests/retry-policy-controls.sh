#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Negative controls: retry-policy.sh must fail on each mutant of a good copy.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pol=$t/r/proven/policy/retry.tsv map=$t/r/proven/registry/sq-map.tsv
mk() { rm -rf "$t/r"; mkdir -p "$t/r/proven/policy" "$t/r/proven/registry"; cp "$here/proven/policy/retry.tsv" "$pol"; cp "$here/proven/registry/sq-map.tsv" "$map"; }
fails=0
expect_fail() { local what=$1; bash "$here/tests/retry-policy.sh" "$t/r" >/dev/null 2>&1 && { echo "MUTANT SURVIVED: $what"; fails=1; } || echo "ok: $what rejected"; }
mk; bash "$here/tests/retry-policy.sh" "$t/r" >/dev/null 2>&1 && echo "ok: good copy accepted" || { echo "good copy rejected"; fails=1; }
mk; sed -i 's/\(api_rate_limit\tSQ-RUN-01\t\)1/\12/' "$pol"; expect_fail "two reruns"
mk; sed -i 's/\(merge_ref_race\tSQ-NOI-02\t\)0/\11/' "$pol"; expect_fail "noise class given a rerun"
mk; sed -i 's/\(api_server_error\tSQ-RUN-03\t\)1/\10/' "$pol"; expect_fail "rerun class given none"
mk; sed -i 's/\(api_rate_limit\t\)SQ-RUN-01/\1SQ-RUN-03/' "$pol"; expect_fail "sq id disagrees with the map"
mk; sed -i 's/\(external_host_unreachable\tSQ-RUN-03\t1\t\)job/\1workflow/' "$pol"; expect_fail "scope is not job"
mk; sed -i '/scan_range_missing_commit/d' "$pol"; expect_fail "a mapped rerun row has no policy row"
mk; printf 'hypatia/ci_failure_triage/not_a_rule\tSQ-RUN-01\t1\tjob\tno\tx\n' >> "$pol"; expect_fail "policy row not in the map"
mk; tail -n 1 "$pol" >> "$pol"; expect_fail "duplicate row"
mk; sed -i 's/\(api_rate_limit\tSQ-RUN-01\t1\tjob\t\)no/\1maybe/' "$pol"; expect_fail "bad then_referral value"
mk; sed -i 's/\(merge_ref_race\tSQ-NOI-02\t0\tjob\t\)no/\1yes/' "$pol"; expect_fail "referral after no rerun"
mk; sed -i 's/^\(hypatia\/ci_failure_triage\/api_rate_limit\tSQ-RUN-01\t1\tjob\tno\t\).*/\1/' "$pol"; expect_fail "empty source field"
mk; printf 'hypatia/ci_failure_triage/new_flaky\tSQ-RUN-01\tmapped\tpresent\tx\n' >> "$map"; expect_fail "new rerun-class map row without a policy row"
exit $fails
