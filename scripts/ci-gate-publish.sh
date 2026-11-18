#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-publish.sh — read the commit, decide, and publish the CI/gate commit status.
# It talks to GitHub only through scripts/ci-gate-lib.sh (gate_api over `gh` on PATH), so a stub
# can drive it (tests/ci-gate.sh). It never waits for checks and never polls: it evaluates, writes,
# and exits. The next verdict comes from the next workflow_run completion or the sweep.
#
# Environment (every value arrives through env:, never interpolated into a script):
#   REPO HEAD_SHA CONTEXT TIMEOUT_MINUTES GATE_NAME   what and where to publish
#   SUITE            directory holding scripts/, profiles/ fetched from the suite at one commit
#   EVENT_NAME       `pull_request` writes ONE pending first ("waiting for the required checks to
#                    report", skipped when that exact status already stands); anything else does not
#   WORKFLOW_RUN_ACTION  the workflow_run event action (`completed` or `requested`). `requested` (with
#                    EVENT_NAME=workflow_run) is a RE-RUN starting: nothing is read or evaluated; the one
#                    write is a deduplicated `pending` ("a required workflow is re-running"), never a
#                    failure or a success, and the publisher exits 0 (75 if the API is unavailable)
#   WORK             scratch directory (default: a fresh mktemp -d)
#   SERVER_URL RUN_ID WF_REPO WF_SHA                    for target_url and the step summary
#   CI_GATE_NOW      test hook: epoch seconds for the verdict instead of `date +%s`
#   CI_GATE_BACKOFF_MAX_SECONDS  total back-off bound for rate limits (default 300; 0 = never wait)
#   CI_GATE_CLOCK CI_GATE_SLEEP CI_GATE_JITTER           test hooks (scripts/ci-gate-lib.sh)
#   GITHUB_STEP_SUMMARY, GITHUB_OUTPUT                  optional; `published=true` is written only when the
#                    evaluation, or its error handler, wrote a status (the initial pull_request pending is
#                    not such a write), or a `requested` event wrote its re-run pending;
#                    `unavailable=true` when the GitHub API could not be used
#
# Reads: TWO per evaluation however many workflows the commit has: the workflow runs of the head SHA
# (actions/runs?head_sha=) and the latest check runs of the commit (commits/<sha>/check-runs), joined
# on check suite id (profiles/ci-gate/join-checks.jq), plus one further request per page of 100.
#
# Order of work, each round (at most 5):
#  b. Snapshot (the two reads), fingerprint the runs (id, status, conclusion, run_attempt,
#     updated_at of every run but the gate's own), run the verdict.
#  c. Guard: just before the POST re-list the runs. If the fingerprint moved, do not write;
#     start the next round.
#  d. POST the status, then re-list the runs once more (post-write verification). If the
#     fingerprint moved since the snapshot, start the next round: re-evaluate and re-POST.
#     This shortens, but cannot remove, the window in which an evaluator paused between its
#     last check and its POST overwrites a newer status: the statuses API has no
#     compare-and-swap. (The reusable's per-SHA concurrency group cancels an evaluation a newer event
#     replaces; that narrows the window as well and closes nothing.)
#  e. Still moving after 5 rounds: leave `pending` "runs still changing", never success.
#  f. Every write (gate_post) sanitises the description (no codepoint above U+FFFF, at most 140
#     characters), first reads the combined status and skips a POST that would repeat the standing
#     status for this context (GitHub keeps at most 1000 statuses per SHA and context).
#  g. Fail closed for real errors: verdict exit code and state must agree; a real error (a 4xx that
#     is not a rate limit, an unusable body, a bad profile) posts a failure status and exits 1.
#  h. NEVER failure for an unavailable API. A rate limit (429, or 403 that says so), a 5xx or no
#     answer is retried with back-off (Retry-After, else x-ratelimit-reset, else exponential with
#     jitter, bounded by CI_GATE_BACKOFF_MAX_SECONDS). When it outlasts the bound the status becomes
#     `pending` "ci-gate: GitHub API rate-limited or unavailable; re-evaluating later" and the exit
#     code is 75. If that pending write is itself refused, it is retried with its own back-off budget;
#     if that also fails the exit code is 1, loudly, and NO failure status is written.
# Exit: 0 success or pending verdict; 1 failure verdict or error; 75 API unavailable (pending written).
set -uo pipefail
MAX_ROUNDS=5
SUITE=${SUITE:-}; WORK=${WORK:-}; EVENT_NAME=${EVENT_NAME:-}
SERVER_URL=${SERVER_URL:-https://github.com}; RUN_ID=${RUN_ID:-0}; WF_REPO=${WF_REPO:-}; WF_SHA=${WF_SHA:-}
for v in REPO HEAD_SHA CONTEXT TIMEOUT_MINUTES GATE_NAME SUITE; do
  [[ -n ${!v:-} ]] || { echo "::error::ci-gate-publish: $v is not set; NO VERDICT WAS PRODUCED"; exit 1; }
done
[[ $HEAD_SHA =~ ^[0-9a-f]{40}$ ]] || { echo "::error::ci-gate-publish: HEAD_SHA is not a 40-hex commit"; exit 1; }
[[ -n $WORK ]] || WORK=$(mktemp -d) || exit 1
[[ $REPO =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && ${REPO#*/} != . && ${REPO#*/} != .. ]] \
  || { echo "::error::ci-gate-publish: REPO is not an owner/name coordinate; NO VERDICT WAS PRODUCED"; exit 1; }
mkdir -p "$WORK" || exit 1
[[ -f $SUITE/scripts/ci-gate-lib.sh ]] || { echo "::error::ci-gate-publish: $SUITE/scripts/ci-gate-lib.sh is missing; NO VERDICT WAS PRODUCED"; exit 1; }
# One back-off budget per publisher, in a file (shared with a sweep's other publishers when it sets one).
[[ -n ${GATE_WAITED_FILE:-} ]] || { GATE_WAITED_FILE="$WORK/.waited"; rm -f "$GATE_WAITED_FILE"; }
export GATE_WAITED_FILE
# shellcheck source-path=SCRIPTDIR source=ci-gate-lib.sh
source "$SUITE/scripts/ci-gate-lib.sh" || exit 1
PROFILE="$SUITE/profiles/ci-gate/$REPO.json"
TARGET_URL="$SERVER_URL/$REPO/actions/runs/$RUN_ID"
RERUN_DESC='ci-gate: a required workflow is re-running; re-evaluating on completion'

finish_output() { [[ -z ${GITHUB_OUTPUT:-} ]] || echo "published=true" >> "$GITHUB_OUTPUT"; }

write_summary() { # <state> <description> <detail-from-summary-file: 1|0>
  {
    echo "### $CONTEXT: $1"
    echo
    echo "Commit \`$HEAD_SHA\` · profile \`$REPO\` at \`${WF_REPO:-?}@${WF_SHA:-?}\`"
    echo
    if [[ $3 == 1 ]]; then cat "$WORK/summary.md" 2> /dev/null || echo "$2"; else echo "$2"; fi
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

post() { gate_post "$REPO" "$HEAD_SHA" "$CONTEXT" "$1" "$2" "$TARGET_URL"; } # <state> <description>

die() { # <description> — a real error, no verdict can be produced: failure status, red job
  local rc
  echo "::error::ci-gate: $1; NO VERDICT WAS PRODUCED"
  post failure "ci-gate: $1"; rc=$?
  if ((rc == 0)); then finish_output; fi
  exit 1
}

unavailable() { # <what failed> — the API is rate-limited or down: pending, never failure
  local what=$1 rc
  echo "::warning::ci-gate: $what: GitHub API rate-limited or unavailable ($GATE_API_ERR); posting pending, NOT failure"
  [[ -z ${GITHUB_OUTPUT:-} ]] || echo "unavailable=true" >> "$GITHUB_OUTPUT"
  gate_post_unavailable "$REPO" "$HEAD_SHA" "$CONTEXT" "$TARGET_URL"; rc=$?
  if ((rc == 0)); then
    finish_output
    write_summary pending "$GATE_UNAVAILABLE_DESC" 0
    echo "$CONTEXT = pending: $GATE_UNAVAILABLE_DESC"
    exit 75
  fi
  echo "::error::ci-gate: could not write the pending status either ($GATE_API_ERR); NO STATUS WAS WRITTEN and NO FAILURE WAS POSTED (the API was unavailable, not the checks)"
  exit 1
}

api_stop() { # <rc of a gate_* call> <what> — turn a gate_* failure into the right ending; returns for rc 0 only
  case $1 in
    0) return 0 ;;
    75) unavailable "$2" ;;
    *) die "$2 ($GATE_API_ERR)" ;;
  esac
}

fingerprint() { # <runs file> -> one line; the gate's own runs are not part of it
  jq -c --arg gate "$GATE_NAME" \
    '[.[] | select(.name != $gate) | [.id, .status, .conclusion, .run_attempt, .updated_at]] | sort' "$1"
}

fresh_fingerprint() { # re-list the runs (one request) -> $FP, or the gate_read_runs code
  local rc
  gate_read_runs "$REPO" "$HEAD_SHA" "$WORK/fresh-runs.json"; rc=$?
  ((rc == 0)) || return "$rc"
  FP=$(fingerprint "$WORK/fresh-runs.json") || { GATE_API_ERR='workflow runs are malformed'; return 1; }
}

# A re-run starting (workflow_run `requested`): no read, no evaluation, no verdict. The one write is a
# deduplicated `pending`; never a failure and never a success. A real error here writes nothing (the
# next `completed` evaluation decides); an unavailable API gets the same pending-only handling as ever.
if [[ ${WORKFLOW_RUN_ACTION:-} == requested ]]; then
  [[ $EVENT_NAME == workflow_run ]] || { echo "::error::ci-gate-publish: a requested action needs EVENT_NAME=workflow_run; NOTHING WAS WRITTEN"; exit 1; }
  post pending "$RERUN_DESC"; rc=$?
  case $rc in
    0) finish_output; write_summary pending "$RERUN_DESC" 0; echo "$CONTEXT = pending: $RERUN_DESC"; exit 0 ;;
    75) unavailable 'could not write the re-run pending' ;;
    *) echo "::error::ci-gate: could not write the re-run pending ($GATE_API_ERR); NOTHING WAS WRITTEN and no verdict was produced"; exit 1 ;;
  esac
fi

[[ -f $PROFILE ]] || die "no profile for $REPO"
bash "$SUITE/scripts/validate-ci-gate-profile.sh" "$PROFILE" "$REPO" "$CONTEXT" > /dev/null 2>&1 \
  || die 'profile invalid for this repository'

# The pull_request start: one pending first, so a pull request that has no verdict yet shows pending
# and a standing status of an earlier head is never the answer. De-duplicated by gate_post.
if [[ $EVENT_NAME == pull_request ]]; then
  post pending 'waiting for the required checks to report'; rc=$?
  api_stop "$rc" 'could not write the pending status'
fi

state='' description='' rc=1 settled=0 round=0 FP=''
while ((round < MAX_ROUNDS)); do
  round=$((round + 1))
  # b. snapshot (two reads), fingerprint, verdict
  gate_read_snapshot "$REPO" "$HEAD_SHA" "$WORK" "$SUITE/profiles/ci-gate/join-checks.jq"; rc=$?
  api_stop "$rc" 'could not read the workflow runs and check runs'
  fp_before=$(fingerprint "$WORK/workflow-runs.json") || die 'workflow runs are malformed'
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
  fresh_fingerprint; rc=$?
  api_stop "$rc" 'could not re-read the workflow runs'
  if [[ $fp_before != "$FP" ]]; then
    echo "round $round: the workflow runs changed while evaluating; evaluating again"
    continue
  fi
  # d. write, then verify the write against the runs as they are now
  write_summary "$state" "$description" 1
  post "$state" "$description"; rc=$?
  api_stop "$rc" 'could not publish the status'
  finish_output
  echo "$CONTEXT = $state: $description"
  fresh_fingerprint; rc=$?
  if ((rc == 75)); then
    # An unverified success must not stand; a pending or failure already written is the safe side.
    if [[ $state == success ]]; then api_stop "$rc" 'could not verify the published success'; fi
    echo "::warning::ci-gate: could not verify the write ($GATE_API_ERR); the $state status stands"
    settled=1; break
  fi
  api_stop "$rc" 'could not re-read the workflow runs after publishing'
  if [[ $fp_before == "$FP" ]]; then settled=1; break; fi
  echo "round $round: the workflow runs changed while publishing; evaluating again"
done

# e. never settled: pending, never success
if [[ $settled -ne 1 ]]; then
  state=pending; description='runs still changing'
  echo "::warning::the workflow runs of $HEAD_SHA kept changing for $MAX_ROUNDS rounds; publishing $state"
  write_summary "$state" "$description" 0
  post "$state" "$description"; rc=$?
  api_stop "$rc" 'could not publish the status'
  finish_output
  echo "$CONTEXT = $state: $description"
fi
# A pending verdict is a normal wait for the next workflow_run; only failure is red.
if [[ $state == failure ]]; then echo "::error::$CONTEXT failed: $description"; exit 1; fi
exit 0
