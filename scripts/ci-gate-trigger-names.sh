#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The `workflow_run.workflows` list of a CI/gate caller, derived from its profile.
# Usage: ci-gate-trigger-names.sh PROFILE.json REPO-ROOT
# `workflow_run.workflows` matches workflow NAMES (the top-level `name:` of a workflow file), not paths;
# a profile (profiles/ci-gate/<owner>/<repo>.json) lists workflow FILES. This prints the JSON array
# (sorted, unique, one line) of the `name:` of each distinct workflow file the profile names.
# Exit 0 = printed; 2 = usage/tool error or an unusable workflow (file missing, no `name:`, a glob
# character in the name, or the name of the gate itself). Fail-closed: it never prints a partial list.
set -euo pipefail
GATE_NAME='CI gate'
[[ $# -eq 2 && -f $1 && -d $2 ]] || { echo 'usage: ci-gate-trigger-names.sh PROFILE.json REPO-ROOT' >&2; exit 2; }
command -v jq >/dev/null || { echo 'jq required' >&2; exit 2; }
command -v yq >/dev/null || { echo 'yq (mikefarah v4) required' >&2; exit 2; }
profile=$1 root=$2
files=$(jq -r '.checks[].workflow' "$profile") || { echo "cannot read workflow files from $profile" >&2; exit 2; }
[[ -n $files ]] || { echo "profile $profile names no workflow" >&2; exit 2; }
names=()
while IFS= read -r wf; do
  [[ -f $root/$wf ]] || { echo "workflow file missing: $wf" >&2; exit 2; }
  name=$(yq -r '.name // ""' "$root/$wf") || { echo "cannot parse $wf" >&2; exit 2; }
  [[ -n $name && $name != null ]] || { echo "workflow has no name: $wf" >&2; exit 2; }
  [[ $name != *[\*\?\[\]\!+]* ]] || { echo "workflow name contains a glob character (* ? [ ] ! +): '$name' in $wf" >&2; exit 2; }
  [[ $name != "$GATE_NAME" ]] || { echo "workflow name is the gate's own ('$GATE_NAME'): $wf" >&2; exit 2; }
  names+=("$name")
done < <(sort -u <<<"$files")
printf '%s\n' "${names[@]}" | jq -Rn -c '[inputs] | unique'
