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
#   SERVER_URL RUN_ID WF_REPO WF_SHA                    for target_url and the step summary
#   CI_GATE_NOW      test hook: epoch seconds instead of `date +%s`
#   GITHUB_STEP_SUMMARY, GITHUB_OUTPUT                  optional; `published=true` is written
#                                                       once a verdict status was posted
#
# (The `pending` "re-run started" write for an in_progress event is the FIRST STEP of the
#  workflow, before any suite file is read; this script posts only verdicts.)
#
# Order of work, each round (at most 5 rounds in all):
#  b. Snapshot the workflow runs of the SHA, fingerprint them (id, status, conclusion,
#     run_attempt, updated_at of every run but the gate's own), read the jobs, run the verdict.
#  c. Guard: just before the POST, fetch the runs again. If the fingerprint moved, do not
#     write; start the next round.
#  d. POST the status, then fetch the runs once more (post-write verification). If the
#     fingerprint moved since the snapshot, start the next round: re-evaluate and re-POST.
#     This shortens, but cannot remove, the window in which an evaluator paused between its
#     last check and its POST overwrites a newer status: the statuses API has no
#     compare-and-swap.
#  e. Still moving after 5 rounds: the last write is `pending` "runs still changing", never
#     success. Every state is guarded and verified, which narrows but does not close the
#     window for a stale write of any state (statuses are last-writer-wins); see
#     docs/CI-GATE.adoc, "Residual limit".
#  f. Fail closed: verdict exit code and state must agree; any API or input error posts a
#     failure status and exits 1; descriptions are at most 140 characters.
set -uo pipefail
MAX_ROUNDS=5
SUITE=${SUITE:-}; WORK=${WORK:-}
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

[[ -f $PROFILE ]] || die "no profile for $REPO"
bash "$SUITE/scripts/validate-ci-gate-profile.sh" "$PROFILE" "$REPO" "$CONTEXT" > /dev/null 2>&1 \
  || die 'profile invalid for this repository'

write_summary() { # <state> <description> <detail-from-summary-file: 1|0>
  {
    echo "### $CONTEXT: $1"
    echo
    echo "Commit \`$HEAD_SHA\` · profile \`$REPO\` at \`${WF_REPO:-?}@${WF_SHA:-?}\`"
    echo
    if [[ $3 == 1 ]]; then cat "$WORK/summary.md" 2> /dev/null || echo "$2"; else echo "$2"; fi
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

state='' description='' rc=1 settled=0
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
  fp_guard=$(fingerprint "$WORK/workflow-runs.json") || die 'workflow runs are malformed'
  if [[ $fp_before != "$fp_guard" ]]; then
    echo "round $round: the workflow runs changed while evaluating; evaluating again"
    continue
  fi
  # d. write, then verify the write against the runs as they are now
  write_summary "$state" "$description" 1
  post "$state" "$description" || die 'could not publish the status'
  finish_output
  echo "$CONTEXT = $state: $description"
  fetch_runs || die 'could not re-read the workflow runs after publishing'
  fp_post=$(fingerprint "$WORK/workflow-runs.json") || die 'workflow runs are malformed'
  if [[ $fp_before == "$fp_post" ]]; then settled=1; break; fi
  echo "round $round: the workflow runs changed while publishing; evaluating again"
done

# e. never settled: the last write is pending, never success
if [[ $settled -ne 1 ]]; then
  state=pending; description='runs still changing'; rc=0
  echo "::warning::the workflow runs of $HEAD_SHA kept changing for $MAX_ROUNDS rounds; publishing pending"
  write_summary "$state" "$description" 0
  post "$state" "$description" || die 'could not publish the status'
  finish_output
  echo "$CONTEXT = $state: $description"
fi
# A pending verdict is a normal wait for the next workflow_run; only failure is red.
if [[ $state == failure ]]; then echo "::error::$CONTEXT failed: $description"; exit 1; fi
exit 0
