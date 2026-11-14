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

header=$(head -1 "$pins")
[[ $header == $'tool\tversion\tenv_var\tsource\tnote' ]] || bad "unexpected header"
declare -A ver env
while IFS=$'\t' read -r tool version envvar source note; do
    [[ -n $tool && -n $version && -n $envvar && -n $source ]] || { bad "incomplete row for '$tool'"; continue; }
    [[ -n ${ver[$tool]:-} ]] && bad "duplicate tool $tool"
    [[ $version =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]] || bad "$tool: version '$version' is not an exact version"
    ver[$tool]=$version env[$tool]=$envvar
done < <(tail -n +2 "$pins")
for t in otp bun nickel yq; do [[ -n ${ver[$t]:-} ]] || bad "required tool $t not pinned"; done

# A pinned tool that names an env var must be set to that version in every template that sets it.
shopt -s nullglob
for tool in "${!ver[@]}"; do
    var=${env[$tool]}
    [[ $var == - ]] && continue
    for f in "$root"/templates/*.yml; do
        while IFS= read -r line; do
            val=${line#*:}; val=${val//[\" ]/}
            [[ $val == "${ver[$tool]}" ]] || bad "$(basename "$f"): $var is '$val', pin is '${ver[$tool]}'"
        done < <(grep -E "^[[:space:]]+$var:" "$f")
    done
done
[[ $fail -eq 0 ]] && echo "toolchain pins: ok"
exit $fail
