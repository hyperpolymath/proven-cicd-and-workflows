#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The toolchain pins file is well formed, and every stamped template that names a
# pinned tool uses the pinned version. 0=pass, 1=violation, 2=cannot run.
set -uo pipefail
root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
pins=$root/proven/pins/toolchain.tsv
[[ -f $pins ]] || { echo "missing $pins" >&2; exit 2; }
fail=0
bad() { echo "FAIL: $1" >&2; fail=1; }

command -v yq >/dev/null && yq --version 2>/dev/null | grep -q mikefarah || { echo 'mikefarah yq v4 required' >&2; exit 2; }
header=$(head -1 "$pins")
[[ $header == $'tool\tversion\tenv_var\tsource\tnote' ]] || bad "unexpected header"
# read collapses empty tab fields, so count and check the raw fields first.
while IFS= read -r bad_row; do bad "malformed row (need 5 non-empty tab fields): $bad_row"; done < <(
    tail -n +2 "$pins" | awk -F'\t' 'NF != 5 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "" { print }')
declare -A ver env
# `|| [[ -n $tool ]]`: read returns non-zero at EOF, which would skip a final row with no newline.
while IFS=$'\t' read -r tool version envvar source note || [[ -n $tool ]]; do
    [[ -n $tool && -n $version && -n $envvar && -n $source && -n $note ]] || continue
    [[ -n ${ver[$tool]:-} ]] && bad "duplicate tool $tool"
    [[ $version =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]] || bad "$tool: version '$version' is not an exact version"
    ver[$tool]=$version env[$tool]=$envvar
done < <(tail -n +2 "$pins")
for t in otp bun nickel yq; do [[ -n ${ver[$t]:-} ]] || bad "required tool $t not pinned"; done

# Every value a template gives a pinned tool's env var, however the YAML quotes the key or value,
# must equal the pin. yq decodes the scalar; nothing is stripped by hand. At least one template
# must set each such var, or the check would pass on nothing.
shopt -s nullglob
for tool in "${!ver[@]}"; do
    var=${env[$tool]}
    [[ $var == - ]] && continue
    seen=0
    for f in "$root"/templates/*.yml; do
        # Compare inside yq: shell command substitution would strip a trailing newline from the value.
        rows=$(VAR=$var PIN=${ver[$tool]} yq -r '.. | select(tag == "!!map") | to_entries | .[] | select(.key == strenv(VAR)) | [(.value == strenv(PIN)), (.value | @json)] | @tsv' "$f") \
            || { bad "$(basename "$f"): does not parse"; continue; }
        [[ -n $rows ]] || continue
        while IFS=$'\t' read -r same shown; do
            seen=1
            [[ $same == true ]] || bad "$(basename "$f"): $var is $shown, pin is '${ver[$tool]}'"
        done <<< "$rows"
    done
    [[ $seen -eq 1 ]] || bad "no template sets $var, so the $tool pin is unchecked"
done
[[ $fail -eq 0 ]] && echo "toolchain pins: ok"
exit $fail
