#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven/policy/retry.tsv is authoritative for the rerun cap; Hypatia's executable rule
# (lib/rules/ci_failure_triage.ex, the `retries` field) must agree with it. 0=agrees,
# 1=disagrees, 2=cannot run. A guarded row (guard head-current, cap 1) that Hypatia still has
# at 0 is a WARN: it is the pending state while the Hypatia change lands, so neither
# repository merges red. Any other disagreement fails.
#   tests/retry-hypatia.sh <ci_failure_triage.ex> [<repo root>]
set -uo pipefail
rules=${1:-}
root=${2:-$(cd "$(dirname "$0")/.." && pwd)}
policy=$root/proven/policy/retry.tsv
[[ -f $rules && -f $policy ]] || { echo "retry-hypatia: rules file or policy missing; NOT RUN" >&2; exit 2; }
fail=0 n=0
bad() { echo "FAIL $1"; fail=1; }
while IFS=$'\t' read -r a5 sq max scope referral guard source || [[ -n $a5 ]]; do
    [[ -n $a5 && -n $max && -n $guard ]] || continue
    name=${a5##*/}
    # The retries field of the rule block named $name.
    got=$(awk -v n="$name" '/^ *name: "/ { c = $0; sub(/^ *name: "/, "", c); sub(/".*/, "", c) }
        c == n && /^ *retries:/ { v = $2; sub(/,.*/, "", v); print v; exit }' "$rules")
    [[ -n $got ]] || { bad "$a5: no rule named $name with a retries field in the Hypatia file"; continue; }
    n=$((n + 1))
    if [[ $got == "$max" ]]; then continue
    elif [[ $guard == head-current && $max == 1 && $got == 0 ]]; then
        echo "WARN $a5: table says a guarded rerun of 1, Hypatia's rule still says 0 (pending Hypatia change)"
    else bad "$a5: table says max_reruns $max, Hypatia's rule says retries $got"; fi
done < <(tail -n +2 "$policy")
[[ $n -gt 0 ]] || bad "no policy row was compared"
[[ $fail -eq 0 ]] && echo "retry-hypatia: $n rows agree with Hypatia's rule"
exit $fail
