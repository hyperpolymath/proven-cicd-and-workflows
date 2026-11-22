#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# permissions.sh WORKFLOW_FILE
#
# Static check of a Scorecard caller. The reusable's jobs ask for
#   actions: read, contents: read, security-events: write, id-token: write.
# GitHub refuses to start a reusable job that asks for more than the calling
# job grants, before any step runs. So a reusable cannot report this itself:
# it must be checked in the caller file, before the caller is pinned.
#
# Exit 0: every Scorecard job grants all four.
# Exit 1: a job is missing one; the fix is printed.
# Exit 2: nothing was checked (unreadable file, no Scorecard job, no yq).
set -euo pipefail

file=${1:-}
command -v yq >/dev/null || { echo 'yq is unavailable. NO CHECK WAS PERFORMED.' >&2; exit 2; }
[[ -n "$file" && -f "$file" && ! -L "$file" ]] \
  || { echo "usage: permissions.sh WORKFLOW_FILE (got '${file}'). NO CHECK WAS PERFORMED." >&2; exit 2; }

pattern='^hyperpolymath/(cicd-suite|proven-cicd|proven-cicd-and-workflows)/\.github/workflows/scorecard-reusable\.yml@'
jobs=$(yq -r '.jobs | to_entries[] | select(.value | has("uses")) | .key + " " + .value.uses' "$file" 2>/dev/null) \
  || { echo "$file cannot be parsed. NO CHECK WAS PERFORMED." >&2; exit 2; }

checked=0 missing=0
while read -r job ref; do
  [[ -n "${job:-}" && "$ref" =~ $pattern ]] || continue
  checked=$((checked + 1))
  # A job-level block REPLACES the workflow-level one; it is never merged.
  if [[ $(yq -r ".jobs[\"$job\"] | has(\"permissions\")" "$file") == true ]]; then
    scope=".jobs[\"$job\"].permissions"
  elif [[ $(yq -r 'has("permissions")' "$file") == true ]]; then
    scope='.permissions'
  else
    echo "::error file=$file::job '$job' declares no permissions, so it gets the repository default token. Add the four permissions below to the job."
    missing=$((missing + 1))
    continue
  fi
  kind=$(yq -r "$scope | type" "$file")
  for pair in actions:read contents:read security-events:write id-token:write; do
    name=${pair%%:*} need=${pair#*:}
    if [[ "$kind" == '!!str' ]]; then
      have=$(yq -r "$scope" "$file")
      case "$have" in write-all) have=write ;; read-all) have=read ;; *) have=none ;; esac
    elif [[ "$kind" == '!!map' ]]; then
      have=$(yq -r "$scope[\"$name\"] // \"none\"" "$file")
    else
      have=none
    fi
    case "$need:$have" in
      read:read|read:write|write:write) ;;
      *)
        echo "::error file=$file::job '$job' grants '$name: $have'; Scorecard needs '$name: $need' on the calling job or GitHub will not start it."
        missing=$((missing + 1))
        ;;
    esac
  done
done <<< "$jobs"

if [[ $checked -eq 0 ]]; then
  echo "$file has no job that calls scorecard-reusable.yml at an admitted suite repository. NO CHECK WAS PERFORMED." >&2
  exit 2
fi
if [[ $missing -gt 0 ]]; then
  cat <<'FIX'
Fix: give the calling job exactly this block (job level, not workflow level):
    permissions:
      actions: read
      contents: read
      security-events: write
      id-token: write
FIX
  exit 1
fi
echo "$file: $checked Scorecard job(s) grant all four permissions."
