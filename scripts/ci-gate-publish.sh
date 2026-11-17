#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-publish.sh — read the commit, decide, and publish the CI/gate commit status.
# It talks to GitHub only through `gh` on PATH, so a stub can drive it (tests/ci-gate.sh).
#
# Environment (every value arrives through env:, never interpolated into a script):
#   REPO HEAD_SHA CONTEXT TIMEOUT_MINUTES GATE_NAME   what and where to publish
#   SUITE            directory holding scripts/, profiles/ fetched from the suite at one commit
#   WORK             scratch directory (default: a fresh mktemp -d)
#   EVENT_ACTION     the workflow_run event action (`completed`, `in_progress`, ...)
#   RUN_NAME         the triggering workflow run's name (for the "re-run started" text)
#   SERVER_URL RUN_ID WF_REPO WF_SHA                    for target_url and the step summary
#   CI_GATE_NOW      test hook: epoch seconds instead of `date +%s`
#   GITHUB_STEP_SUMMARY, GITHUB_OUTPUT                  optional; `published=true` is written
#                                                       once a verdict status was posted
#
# Order of work:
#  a. EVENT_ACTION = in_progress: POST `pending` ("re-run started: <name>") BEFORE reading the
#     profile or any job, so a stale success never outlives the start of a run.
#  b. Snapshot the workflow runs of the SHA, fingerprint them (id, status, conclusion,
#     run_attempt, updated_at of every run but the gate's own), read the jobs, run the verdict.
#  c. Guard: just before the POST, fetch the runs again and recompute the fingerprint. If it
#     moved, evaluate again from (b), at most 5 rounds. Still moving after 5: POST `pending`
#     "runs still changing", never success. The guard applies to EVERY state written, so a
#     late evaluator cannot leave a stale pending or failure either.
#  d. Fail closed: verdict exit code and state must agree; any API or input error posts a
#     failure status and exits 1; descriptions are at most 140 characters.
set -uo pipefail

MAX_ROUNDS=5
SUITE=${SUITE:-}; WORK=${WORK:-}; EVENT_ACTION=${EVENT_ACTION:-}; RUN_NAME=${RUN_NAME:-}
SERVER_URL=${SERVER_URL:-https://github.com}; RUN_ID=${RUN_ID:-0}; WF_REPO=${WF_REPO:-}; WF_SHA=${WF_SHA:-}
for v in REPO HEAD_SHA CONTEXT TIMEOUT_MINUTES GATE_NAME SUITE; do
  [[ -n ${!v:-} ]] || { echo "::error::ci-gate-publish: $v is not set; NO VERDICT WAS PRODUCED"; exit 1; }
done
[[ $HEAD_SHA =~ ^[0-9a-f]{40}$ ]] || { echo "::error::ci-gate-publish: HEAD_SHA is not a 40-hex commit"; exit 1; }
[[ -n $WORK ]] || WORK=$(mktemp -d) || exit 1
mkdir -p "$WORK" || exit 1
PROFILE="$SUITE/profiles/ci-gate/$REPO.json"
published=0

clip() { jq -rn --arg d "$1" 'if ($d | length) > 140 then $d[0:139] + "…" else $d end'; }  # by characters, whatever the locale

post() { # <state> <description> — one commit status; returns gh's exit code
  gh api -X POST "repos/$REPO/statuses/$HEAD_SHA" \
    -f state="$1" -f context="$CONTEXT" -f description="$(clip "$2")" \
    -f target_url="$SERVER_URL/$REPO/actions/runs/$RUN_ID" > /dev/null
}

die() { # <description> — no verdict could be produced: failure status, red job
  echo "::error::ci-gate: $1; NO VERDICT WAS PRODUCED"
  post failure "ci-gate: $1" && finish_output
  exit 1
}

finish_output() { [[ -z ${GITHUB_OUTPUT:-} ]] || echo "published=true" >> "$GITHUB_OUTPUT"; published=1; }

fetch_runs() { # -> $WORK/workflow-runs.json (every page)
  gh api --paginate "repos/$REPO/actions/runs?head_sha=$HEAD_SHA&per_page=100" --jq '.workflow_runs[]' \
    | jq -s '.' > "$WORK/workflow-runs.json.new" \
    && jq -e 'type == "array"' "$WORK/workflow-runs.json.new" > /dev/null \
    && mv "$WORK/workflow-runs.json.new" "$WORK/workflow-runs.json"
}

fingerprint() { # <runs file> -> one line; the gate's own runs are not part of it
  jq -c --arg gate "$GATE_NAME" \
    '[.[] | select(.name != $gate) | [.id, .status, .conclusion, .run_attempt, .updated_at]] | sort' "$1"
}

# a. a started or re-run workflow invalidates the previous verdict at once
if [[ $EVENT_ACTION == in_progress ]]; then
  post pending "re-run started: ${RUN_NAME:-workflow}" || die 'could not publish the re-run pending status'
  echo "$CONTEXT = pending: re-run started"
fi

[[ -f $PROFILE ]] || die "no profile for $REPO"
bash "$SUITE/scripts/validate-ci-gate-profile.sh" "$PROFILE" "$REPO" "$CONTEXT" > /dev/null 2>&1 \
  || die 'profile invalid for this repository'

state='' description='' rc=1
for ((round = 1; round <= MAX_ROUNDS; round++)); do
  # b. snapshot, fingerprint, jobs, verdict
  fetch_runs || die 'could not read the workflow runs'
  fp_before=$(fingerprint "$WORK/workflow-runs.json") || die 'workflow runs are malformed'
  jq --arg gate "$GATE_NAME" -c -f "$SUITE/profiles/ci-gate/select-runs.jq" "$WORK/workflow-runs.json" > "$WORK/kept-runs.json" \
    || die 'workflow runs are malformed'
  : > "$WORK/jobs.ndjson"
  while read -r run; do
    id=$(jq -r .id <<<"$run")
    [[ $id =~ ^[0-9]+$ ]] || die 'a workflow run has no numeric id'
    { gh api --paginate "repos/$REPO/actions/runs/$id/jobs?filter=latest&per_page=100" --jq '.jobs[]' \
        | jq -c --argjson run "$run" '. + {run: {id: $run.id, name: $run.name, path: $run.path, status: $run.status}}' \
        >> "$WORK/jobs.ndjson"; } || die "could not read the jobs of run $id"
  done < <(jq -c '.[]' "$WORK/kept-runs.json")
  jq -s '.' "$WORK/jobs.ndjson" > "$WORK/jobs.json" || die 'jobs are malformed'
  rc=0
  bash "$SUITE/scripts/ci-gate-verdict.sh" \
    --profile "$PROFILE" --repository "$REPO" \
    --jobs "$WORK/jobs.json" --workflow-runs "$WORK/workflow-runs.json" \
    --gate-name "$GATE_NAME" --context "$CONTEXT" --now "${CI_GATE_NOW:-$(date +%s)}" \
    --timeout-minutes "$TIMEOUT_MINUTES" --summary "$WORK/summary.md" > "$WORK/verdict.txt" || rc=$?
  state=$(sed -n 's/^state=//p' "$WORK/verdict.txt")
  description=$(sed -n 's/^description=//p' "$WORK/verdict.txt")
  # the exit code and the printed state must agree; anything else is a failure
  case "$rc:$state" in
    0:success | 3:pending | 1:failure) ;;
    *) state=failure; description="ci-gate: verdict script gave exit $rc and state '${state:-none}'"; rc=1 ;;
  esac
  # c. guard: did the runs move while we evaluated? Applies to every state.
  fetch_runs || die 'could not re-read the workflow runs'
  fp_after=$(fingerprint "$WORK/workflow-runs.json") || die 'workflow runs are malformed'
  [[ $fp_before == "$fp_after" ]] && break
  echo "round $round: the workflow runs changed while evaluating; evaluating again"
  state=''
done

if [[ -z $state ]]; then
  state=pending; description='runs still changing'; rc=0
  echo "::warning::the workflow runs of $HEAD_SHA changed in all $MAX_ROUNDS rounds; publishing pending"
fi

{
  echo "### $CONTEXT: $state"
  echo
  echo "Commit \`$HEAD_SHA\` · profile \`$REPO\` at \`${WF_REPO:-?}@${WF_SHA:-?}\`"
  echo
  if [[ $description == 'runs still changing' ]]; then echo "$description"; else cat "$WORK/summary.md" 2> /dev/null || echo "$description"; fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

post "$state" "$description" || die 'could not publish the status'
finish_output
echo "$CONTEXT = $state: $description"
# A pending verdict is a normal wait for the next workflow_run; only failure is red.
if [[ $state == failure ]]; then echo "::error::$CONTEXT failed: $description"; exit 1; fi
exit 0
