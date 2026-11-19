#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven/policy/generated.tsv: for each generated-file rule, the generator is named in the rule
# (never read from a log), the tool it needs is pinned, and the ids agree with the one A5<->SQ map.
# 0=conforms, 1=a rule is broken, 2=cannot run.
#   tests/generated-policy.sh [<repo root>]
#   HYPATIA_RULES=<ci_failure_triage.ex>  also check kind, generator and escalation against the
#                  same-named Hypatia rule (`action`, `fix`, `escalation`).
set -uo pipefail
root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
policy=$root/proven/policy/generated.tsv map=$root/proven/registry/sq-map.tsv pins=$root/proven/pins/toolchain.tsv
[[ -f $policy && -f $map && -f $pins ]] || { echo "generated-policy: policy, map or pins missing; NOT RUN" >&2; exit 2; }
rules=${HYPATIA_RULES:-}
[[ -z $rules || -f $rules ]] || { echo "generated-policy: HYPATIA_RULES=$rules missing; NOT RUN" >&2; exit 2; }
fail=0
bad() { echo "FAIL $1"; fail=1; }

[[ $(head -n 1 "$policy") == $'a5_id\tsq_id\tkind\tgenerator\ttool\tescalation\tsource' ]] || bad "unexpected header"
# Raw field check first: read would merge consecutive tabs.
while IFS= read -r row; do bad "malformed row (need 7 non-empty tab fields): $row"; done < <(
    tail -n +2 "$policy" | awk -F'\t' 'NF != 7 { print; next } { for (i = 1; i <= 7; i++) if ($i == "") { print; next } }')

declare -A seen=()   # set -u: an empty population must not be unbound
# `|| [[ -n $a5 ]]`: read returns non-zero at EOF, which would skip a final row with no newline.
while IFS=$'\t' read -r a5 sq kind generator tool escalation source || [[ -n $a5 ]]; do
    [[ -n $a5 && -n $sq && -n $kind && -n $generator && -n $tool && -n $escalation && -n $source ]] || continue
    [[ -z ${seen[$a5]:-} ]] || bad "$a5: duplicate row"
    seen[$a5]=1
    pair=$(awk -F'\t' -v a="$a5" '$1 == a { print $2 "\t" $3 }' "$map")
    [[ -n $pair ]] || { bad "$a5: not in sq-map.tsv"; continue; }
    case $kind in
        generator|static)
            [[ $pair == "$sq"$'\t'mapped ]] || bad "$a5: policy says $sq, map says ${pair//$'\t'/ }"
            [[ $sq == SQ-GEN-* ]] || bad "$a5: kind $kind needs an SQ-GEN-* rule, not $sq"
            [[ $generator != "-" ]] || bad "$a5: kind $kind must name its generator or fix"
            # Named in the rule, never read from a log: no log placeholders.
            [[ $generator != *'$LOG'* && $generator != *'{{'* && $generator != *'<log'* ]] || bad "$a5: the generator must not be read from a log"
            ;;
        referral)
            [[ $pair == "$sq"$'\t'hypatia-only ]] || bad "$a5: a referral row must be hypatia-only in the map, got ${pair//$'\t'/ }"
            [[ $generator == "-" && $tool == "-" ]] || bad "$a5: a referral names no generator and no tool"
            ;;
        *) bad "$a5: kind '$kind' must be generator, static or referral" ;;
    esac
    [[ $escalation == owner ]] || bad "$a5: escalation '$escalation' must be owner"
    # The tool a generator needs is pinned in one file.
    if [[ $tool != "-" ]]; then
        awk -F'\t' -v t="$tool" '$1 == t { f = 1 } END { exit !f }' "$pins" || bad "$a5: tool '$tool' is not pinned in toolchain.tsv"
    fi
    if [[ -n $rules ]]; then
        name=${a5##*/}
        read -r h_action h_fix h_esc < <(awk -v n="$name" '
            /^ *name: "/ { if (c == n) exit; c = $0; sub(/^ *name: "/, "", c); sub(/".*/, "", c) }
            c == n && /^ *action:/ && a == "" { a = $2; sub(/,.*/, "", a); sub(/^:/, "", a) }
            c == n && /^ *escalation:/ && e == "" { e = $2; sub(/,.*/, "", e); sub(/^:/, "", e) }
            c == n && /^ *fix:/ && !g { g = 1; f = $0; sub(/^ *fix: */, "", f); sub(/,$/, "", f); gsub(/^"|"$/, "", f); gsub(/ /, "_", f) }
            END { if (c == n) print a, (f == "" ? "nil" : f), e }' "$rules")
        [[ -n ${h_action:-} ]] || { bad "$a5: no rule named $name in the Hypatia file"; continue; }
        want_fix=${generator// /_}
        case $kind in
            generator) [[ $h_action == fix ]] || bad "$a5: Hypatia action is $h_action, the table says a generator" ;;
            static) [[ $h_action == fix ]] || bad "$a5: Hypatia action is $h_action, the table says a static fix" ;;
            referral) [[ $h_action == report && $h_fix == nil ]] || bad "$a5: Hypatia must refer (action report, no fix), got $h_action" ;;
            *) bad "$a5: kind '$kind' has no Hypatia comparison" ;;   # the kind was validated above; fail closed
        esac
        [[ $kind == referral || $h_fix == "$want_fix" ]] || bad "$a5: Hypatia's fix text differs from the table's generator"
        [[ $h_esc == "$escalation" ]] || bad "$a5: Hypatia escalation is $h_esc, the table says $escalation"
    fi
done < <(tail -n +2 "$policy")

# Completeness: every mapped SQ-GEN rule has a row, and the hypatia-only generated-file rule too.
while IFS= read -r a5; do
    [[ -n ${seen[$a5]:-} ]] || bad "$a5: mapped to an SQ-GEN rule but has no policy row"
done < <(awk -F'\t' '$3 == "mapped" && $2 ~ /^SQ-GEN-/ { print $1 }' "$map")
[[ -n ${seen[hypatia/ci_failure_triage/generated_file_stale]:-} ]] || bad "hypatia/ci_failure_triage/generated_file_stale: the referral row is missing"

[[ $fail -eq 0 ]] && echo "generated-policy: ${#seen[@]} rows conform${rules:+ (and agree with the Hypatia rules)}"
exit $fail
