#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Structural check of a CI/gate profile (profiles/ci-gate/<owner>/<repo>.json).
# Usage: validate-ci-gate-profile.sh PROFILE.json OWNER/REPO [CONTEXT]
# Exit 0 = structurally valid for that repository; 1 = invalid; 2 = usage/tool error.
# Fail-closed: there is no "valid because absent" path. It checks structure only; it does
# not say the listed checks exist, and it authenticates nothing.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[[ $# -ge 2 && $# -le 3 && -f $1 ]] || { echo 'usage: validate-ci-gate-profile.sh PROFILE.json OWNER/REPO [CONTEXT]' >&2; exit 2; }
command -v jq >/dev/null || { echo 'jq required' >&2; exit 2; }
profile=$1 repository=$2 context=${3:-CI/gate}
jq -se 'length == 1 and (.[0] | type == "object")' "$profile" >/dev/null 2>&1 || {
  echo 'expected exactly one JSON object' >&2; exit 1;
}
# jq otherwise accepts duplicate object keys with last-value-wins semantics. Streaming
# exposes decoded key paths; revisiting a completed leaf or container is a duplicate.
jq --stream -s -e '
  reduce .[] as $event ({closed: {}, valid: true};
    if ($event | length) == 2 then
      . as $state | $event[0] as $path |
      .valid = (.valid and all(range(1; ($path | length) + 1);
        . as $n | $state.closed[($path[:$n] | tojson)] != true)) |
      .closed[($path | tojson)] = true
    else .closed[($event[0][:-1] | tojson)] = true end) | .valid
' "$profile" >/dev/null || { echo 'duplicate JSON member' >&2; exit 1; }
jq -se --arg repository "$repository" \
  --argjson forbidden "$(jq -cn --arg c "$context" '[$c, "CI/gate", "estate-gate"] | unique')" \
  -f "$ROOT/profiles/ci-gate/validate.jq" "$profile" >/dev/null || {
    echo 'invalid CI/gate profile (members, repository, or check list)' >&2; exit 1;
  }
echo "valid CI/gate profile for $repository"
