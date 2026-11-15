#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The rerun policy table agrees with the one A5<->SQ map and with the cap of one rerun
# per job. 0=conforms, 1=a rule is broken, 2=cannot run.
set -uo pipefail
root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
policy=$root/proven/policy/retry.tsv map=$root/proven/registry/sq-map.tsv
[[ -f $policy && -f $map ]] || { echo "retry-policy: policy or map missing; NOT RUN" >&2; exit 2; }
fail=0
bad() { echo "FAIL $1"; fail=1; }

[[ $(head -n 1 "$policy") == $'a5_id\tsq_id\tmax_reruns\tscope\tthen_referral\tguard\tsource' ]] || bad "unexpected header"
# Raw field check first: read would merge consecutive tabs.
while IFS= read -r row; do bad "malformed row (need 7 non-empty tab fields): $row"; done < <(
    tail -n +2 "$policy" | awk -F'\t' 'NF != 7 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "" || $6 == "" || $7 == "" { print }')

declare -A seen=()   # set -u: an empty population (no rerun or noise rows) must not be unbound
# `|| [[ -n $a5 ]]`: read returns non-zero at EOF, which would skip a final row with no newline.
while IFS=$'\t' read -r a5 sq max scope referral guard source || [[ -n $a5 ]]; do
    [[ -n $a5 && -n $sq && -n $max && -n $scope && -n $referral && -n $guard && -n $source ]] || continue
    [[ -z ${seen[$a5]:-} ]] || bad "$a5: duplicate row"
    seen[$a5]=1
    [[ $max == 0 || $max == 1 ]] || bad "$a5: max_reruns '$max' must be 0 or 1 (one rerun per job at most)"
    [[ $scope == job ]] || bad "$a5: scope '$scope' must be job"
    [[ $referral == yes || $referral == no ]] || bad "$a5: then_referral '$referral' must be yes or no"
    # The map is the authority for the id pairing.
    pair=$(awk -F'\t' -v a="$a5" '$1 == a { print $2 "\t" $3 }' "$map")
    [[ -n $pair ]] || { bad "$a5: not in sq-map.tsv"; continue; }
    [[ $pair == "$sq"$'\t'mapped ]] || bad "$a5: policy says $sq, map says ${pair//$'\t'/ }"
    # The cap and the guard are structured fields here; the map's note wording is not read.
    [[ $guard == none || $guard == head-current ]] || bad "$a5: guard '$guard' must be none or head-current"
    [[ $guard == none || $max == 1 ]] || bad "$a5: a guard only makes sense with max_reruns 1"
    case $sq in
        SQ-RUN-*) [[ $max == 1 ]] || bad "$a5: $sq is a rerun class, max_reruns must be 1" ;;
        # A noise rule that is re-run at all (a cancelled run) must be guarded: re-running a
        # run whose head was replaced re-enters its concurrency group and can cancel the
        # run for the current head.
        SQ-NOI-*) [[ $max == 0 || $guard == head-current ]] || bad "$a5: $sq is noise, so a rerun needs guard head-current" ;;
        *) bad "$a5: $sq is neither SQ-RUN-* nor SQ-NOI-*" ;;
    esac
    # Owner ruling 2026-11-14: a merge race is never a re-run.
    [[ $sq != SQ-NOI-02 || $max == 0 ]] || bad "$a5: SQ-NOI-02 (merge race) must never be re-run, max_reruns must be 0"
    [[ $referral == no || $max == 1 ]] || bad "$a5: a referral after a rerun needs max_reruns 1"
done < <(tail -n +2 "$policy")

# Completeness: every mapped A5 row in a rerun or noise family has a policy row.
while IFS= read -r a5; do
    [[ -n ${seen[$a5]:-} ]] || bad "$a5: mapped to a rerun or noise class but has no policy row"
done < <(awk -F'\t' '$3 == "mapped" && $2 ~ /^SQ-(RUN|NOI)-/ { print $1 }' "$map")

[[ $fail -eq 0 ]] && echo "retry-policy: ${#seen[@]} rows conform"
exit $fail
