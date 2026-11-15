#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Negative controls for retry-hypatia.sh. A fixture stands in for Hypatia's rule file.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fails=0
mkrules() { # name=retries[:guard] ...  (guard is Hypatia's atom, e.g. head_current)
    : > "$t/r.ex"; local kv v
    for kv in "$@"; do
        v=${kv#*=}
        printf '    %%{\n      name: "%s",\n      action: :x,\n      retries: %s,\n' "${kv%=*}" "${v%%:*}" >> "$t/r.ex"
        [[ $v == *:* ]] && printf '      guard: :%s,\n' "${v#*:}" >> "$t/r.ex"
        printf '      fix: nil\n    },\n' >> "$t/r.ex"
    done
}
good=(api_rate_limit=1 api_server_error=1 external_host_unreachable=1 scan_range_missing_commit=1 merge_ref_race=0 runner_cancelled=1:head_current)
run() { bash "$here/tests/retry-hypatia.sh" "$t/r.ex" "$here"; }
chk() { local what=$1 want=$2 out rc=0; out=$(run 2>&1) || rc=$?; [[ $rc -eq $want ]] && echo "ok: $what" || { echo "FAILED: $what (rc=$rc want $want: $out)"; fails=1; }; }
mkrules "${good[@]}"; chk "agreeing rules accepted" 0
mkrules api_rate_limit=1 api_server_error=1 external_host_unreachable=1 scan_range_missing_commit=1 merge_ref_race=0 runner_cancelled=1; chk "Hypatia reruns a cancelled run with no guard" 1
mkrules api_rate_limit=1 api_server_error=1 external_host_unreachable=1 scan_range_missing_commit=1 merge_ref_race=0 runner_cancelled=1:always; chk "Hypatia guard differs from the table" 1
mkrules api_rate_limit=1:head_current api_server_error=1 external_host_unreachable=1 scan_range_missing_commit=1 merge_ref_race=0 runner_cancelled=1:head_current; chk "Hypatia guards a row the table leaves unguarded" 1
mkrules api_rate_limit=1 api_server_error=1 external_host_unreachable=1 scan_range_missing_commit=1 merge_ref_race=0 runner_cancelled=0
chk "table guards a rerun that Hypatia still has at 0" 1
mkrules api_rate_limit=1 api_server_error=0 external_host_unreachable=1 scan_range_missing_commit=1 merge_ref_race=0 runner_cancelled=1; chk "unguarded row disagreeing is rejected" 1
mkrules api_rate_limit=1 api_server_error=1 external_host_unreachable=1 scan_range_missing_commit=1 merge_ref_race=1 runner_cancelled=1:head_current; chk "Hypatia allows a merge-race rerun" 1
mkrules api_rate_limit=1 api_server_error=1 external_host_unreachable=1 scan_range_missing_commit=1 merge_ref_race=0 runner_cancelled=2:head_current; chk "Hypatia allows more than the table" 1
mkrules api_rate_limit=1 api_server_error=1 external_host_unreachable=1 scan_range_missing_commit=1 merge_ref_race=0; chk "rule missing from the Hypatia file" 1
bash "$here/tests/retry-hypatia.sh" "$t/none.ex" "$here" >/dev/null 2>&1; [[ $? -eq 2 ]] && echo "ok: missing file is NOT RUN" || { echo "FAILED: missing file"; fails=1; }
exit $fails
