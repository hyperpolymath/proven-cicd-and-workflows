#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-publish.sh — read the commit, decide, and publish the CI/gate commit status.
# It talks to GitHub only through `gh` on PATH, so a stub can drive it (tests/ci-gate.sh).
#
# Environment (every value arrives through env:, never interpolated into a script):
#   REPO HEAD_SHA CONTEXT TIMEOUT_MINUTES GATE_NAME   what and where to publish
#   SUITE            directory holding scripts/, profiles/ fetched from the suite at one commit
#   CI_GATE_STATUS_LIB  the status writer written by ci-gate.yml ("Write the status writer"); every
#                    status goes through its post_status (de-duplicated, retried when rate limited)
#   WORK             scratch directory (default: a fresh mktemp -d)
#   SERVER_URL RUN_ID WF_REPO WF_SHA                    for target_url and the step summary
#   CI_GATE_NOW      test hook: epoch seconds instead of `date +%s`
#   WAIT_SECONDS POLL_SECONDS  pull_request: keep polling while the verdict only means
#                    "not finished" (pending, never reported, never completed); 0 elsewhere
#   CI_GATE_CLOCK    test hook: command returning elapsed-clock seconds (default: date +%s)
#   CI_GATE_SLEEP    test hook: the sleep command
#   GITHUB_STEP_SUMMARY, GITHUB_OUTPUT                  optional; `published=true` is written
#                                                       once a verdict status was posted
#   GUARD_PRS GUARD_NO_LOOKUP GUARD_EVENT_PRS GUARD_HEAD_REPO GUARD_HEAD_BRANCH  which pull requests the
#                    tamper guard checks: the union of all sources (step a. below)
#
# (The `pending` "re-run started" write for an in_progress event is the FIRST STEP of the
#  workflow, before any suite file is read; this script posts only verdicts.)
#
# a. Once, before any round: the tamper guard for each open pull request into REPO (fork or not) headed by
#    HEAD_SHA (scripts/ci-gate-tamper-guard.sh). Not approved: failure at once. Error: no verdict.
# Order of work, each round (5 rounds, or the pull_request elapsed wait deadline):
#  b. Snapshot the workflow runs of the SHA, fingerprint them (id, status, conclusion,
#     run_attempt, updated_at of every run but the gate's own), read the jobs, run the verdict.
#  c. Guard: just before the POST, fetch the runs again. If the fingerprint moved, do not
#     write; start the next round.
#  d. POST the status, then fetch the runs once more (post-write verification). If the
#     fingerprint moved since the snapshot, start the next round: re-evaluate and re-POST.
#     This shortens, but cannot remove, the window in which an evaluator paused between its
#     last check and its POST overwrites a newer status: the statuses API has no
#     compare-and-swap.
#  e. Still moving after 5 rounds: retry until the pull_request deadline, then fail;
#     other events leave `pending` "runs still changing", never
#     success. Every state is guarded and verified, which narrows but does not close the
#     window for a stale write of any state (statuses are last-writer-wins); see
#     docs/CI-GATE.adoc, "Residual limit".
#  f. Every write (post(), die() included) first reads the combined status of the commit and skips
#     a POST that would repeat the standing status for this context (same state, same description
#     after the clip): GitHub keeps at most 1000 statuses per SHA and context. A failed or malformed
#     read writes anyway. A head whose verdict keeps changing can still reach the cap. A rate-limited
#     POST is retried (the writer's rules); exhausted, the job fails with "rate limited, no verdict"
#     and die() writes nothing more, since that write would meet the same limit.
#  g. Fail closed: verdict exit code and state must agree; any API or input error posts a
#     failure status and exits 1; descriptions are at most 140 characters.
set -uo pipefail
MAX_ROUNDS=5
WAIT_SECONDS=${WAIT_SECONDS:-0}; POLL_SECONDS=${POLL_SECONDS:-20}   # pull_request wait; 0 = evaluate once
SUITE=${SUITE:-}; WORK=${WORK:-}
SERVER_URL=${SERVER_URL:-https://github.com}; RUN_ID=${RUN_ID:-0}; WF_REPO=${WF_REPO:-}; WF_SHA=${WF_SHA:-}
for v in REPO HEAD_SHA CONTEXT TIMEOUT_MINUTES GATE_NAME SUITE CI_GATE_STATUS_LIB; do
  [[ -n ${!v:-} ]] || { echo "::error::ci-gate-publish: $v is not set; NO VERDICT WAS PRODUCED"; exit 1; }
done
[[ $HEAD_SHA =~ ^[0-9a-f]{40}$ ]] || { echo "::error::ci-gate-publish: HEAD_SHA is not a 40-hex commit"; exit 1; }
[[ $WAIT_SECONDS =~ ^[0-9]+$ && $POLL_SECONDS =~ ^[1-9][0-9]*$ ]] || { echo "::error::ci-gate-publish: WAIT_SECONDS must be a non-negative and POLL_SECONDS a positive integer; NO VERDICT WAS PRODUCED"; exit 1; }
[[ -n $WORK ]] || WORK=$(mktemp -d) || exit 1
[[ $REPO =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && ${REPO#*/} != . && ${REPO#*/} != .. ]] \
  || { echo "::error::ci-gate-publish: REPO is not an owner/name coordinate; NO VERDICT WAS PRODUCED"; exit 1; }
mkdir -p "$WORK" || exit 1
# shellcheck source=/dev/null
source "$CI_GATE_STATUS_LIB" && declare -F post_status > /dev/null \
  || { echo "::error::ci-gate-publish: the status writer $CI_GATE_STATUS_LIB is unreadable; NO VERDICT WAS PRODUCED"; exit 1; }
PROFILE="$SUITE/profiles/ci-gate/$REPO.json"
published=0
# Invocation-local cache: never reuse data left by a previous publisher or sweep head.
declare -A completed_keys=() completed_jobs=()
poll_cost=10

# By characters, whatever the locale. A character outside the BMP (an emoji such as a red circle in
# a job or workflow name) becomes '?': GitHub's statuses API answers HTTP 422 "Description doesn't
# accept 4-byte Unicode", which would make the gate publish no verdict. It is one character for one,
# so the 140-character count is unchanged.
clip() { local text=$1; jq -rn --arg d "$text" '($d | explode | map(if . > 65535 then 63 else . end) | implode) | if length > 140 then .[0:139] + "…" else . end'; }

post() { # <state> <description> — one commit status through the writer; 0 written or skipped
  # GitHub keeps at most 1000 statuses per SHA and context, after which every write fails (die()
  # included). The writer skips a write that would repeat the status already standing for this
  # context (same state, same description; target_url is not compared), which counts as published;
  # a failed or malformed read of the current status falls toward writing.
  post_status "$1" "$(clip "$2")"
}

die() { # <description> — no verdict could be produced: failure status, red job
  echo "::error::ci-gate: $1; NO VERDICT WAS PRODUCED"
  ((CI_GATE_RATE_LIMITED == 0)) || exit 1
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

# a. Tamper guard, folded into this verdict (docs/CI-GATE.adoc, "Tamper guard"). For EVERY open pull
# request into this repository (base = REPO) whose head is HEAD_SHA, from a branch of this repository
# or from a FORK, run scripts/ci-gate-tamper-guard.sh with the profile's producer workflows as extra
# protected paths. The status is per commit, and several pull requests can share one head (two
# branches at one commit, or one branch into two bases), so the guard covers all of them: the set is
# the UNION of every source below, de-duplicated. A pull request that touches a protected path
# without the owner's approval makes the verdict `failure` at once, whatever the checks say. Any
# error of the guard or of any lookup is "no verdict" (die). Sources:
#   GUARD_PRS        numbers the caller already knows are open with base REPO at HEAD_SHA (the sweep's
#                    listing; gate-pr's own number). Taken as they are.
#   GUARD_NO_LOOKUP=1  the caller listed EVERY open pull request of the repository (the sweep): no
#                    lookup. Otherwise all of the following are added:
#   GUARD_EVENT_PRS  the workflow_run event's pull_requests (JSON; empty for a fork's run) whose
#                    head.sha is HEAD_SHA, each confirmed with GET pulls/<n> (open, base REPO, head SHA).
#   GUARD_HEAD_REPO GUARD_HEAD_BRANCH  when the run's head repository is not REPO (a fork):
#                    GET pulls?state=open&head=<owner>:<branch>, each confirmed the same way.
#   always:          GET commits/<sha>/pulls, kept if open, base REPO and head HEAD_SHA.
# The guard's per-pull-request calls (files, label events, permission, commits) are base-repository
# endpoints and are made only for a matched pull request.
GUARD="$SUITE/scripts/ci-gate-tamper-guard.sh"
[[ -f $GUARD ]] || die 'the tamper guard script is missing from the suite'
guard_prs=()
pr_num_ok() { [[ $1 =~ ^[1-9][0-9]{0,9}$ ]]; }
confirm_pr() { # <n>: append it to guard_prs if it is open, into REPO, and headed by HEAD_SHA
  local pr pstate psha pbase
  pr=$(gh api "repos/$REPO/pulls/$1" --jq '[.state, .head.sha, (.base.repo.full_name // "")] | @tsv') \
    || die "could not read pull request #$1 for the tamper guard"
  IFS=$'\t' read -r pstate psha pbase <<< "$pr"
  if [[ $pstate == open && $psha == "$HEAD_SHA" && $pbase == "$REPO" ]]; then guard_prs+=("$1"); fi
  return 0
}
for n in ${GUARD_PRS:-}; do
  pr_num_ok "$n" || die 'GUARD_PRS holds something that is not a pull request number'
  guard_prs+=("$n")
done
if [[ ${GUARD_NO_LOOKUP:-} != 1 ]]; then
  if [[ -n ${GUARD_EVENT_PRS:-} && $GUARD_EVENT_PRS != null ]]; then
    hints=$(jq -r --arg sha "$HEAD_SHA" 'if type == "array" then .[] | select(type == "object" and .head.sha == $sha) | .number | tostring else error("not an array") end' <<< "$GUARD_EVENT_PRS") \
      || die 'the workflow_run pull request list is malformed'
    for n in $hints; do
      pr_num_ok "$n" || die 'the workflow_run pull request list has a malformed number'
      confirm_pr "$n"
    done
  fi
  if [[ -n ${GUARD_HEAD_REPO:-} && $GUARD_HEAD_REPO != "$REPO" ]]; then
    # a fork's run: workflow_run.pull_requests is empty, so ask for open pull requests from its branch
    [[ $GUARD_HEAD_REPO =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] \
      || die 'the workflow_run head repository is not an owner/name coordinate'
    [[ -n ${GUARD_HEAD_BRANCH:-} && ${#GUARD_HEAD_BRANCH} -le 255 && $GUARD_HEAD_BRANCH != *[[:cntrl:]]* ]] \
      || die 'the workflow_run head branch is empty, too long or has control characters'
    found=$(gh api -X GET --paginate "repos/$REPO/pulls" -f state=open -f per_page=100 \
      -f head="${GUARD_HEAD_REPO%%/*}:$GUARD_HEAD_BRANCH" --jq '.[] | .number') \
      || die 'could not list the pull requests of the fork branch for the tamper guard'
    for n in $found; do
      pr_num_ok "$n" || die 'a fork pull request has a malformed number'
      confirm_pr "$n"
    done
  fi
  found=$(gh api --paginate "repos/$REPO/commits/$HEAD_SHA/pulls?per_page=100" --jq '.[] | [.number, .state, .head.sha, (.base.repo.full_name // "")] | @tsv') \
    || die 'could not list the pull requests of this commit for the tamper guard'
  while IFS=$'\t' read -r n pstate psha pbase; do
    [[ -n $n ]] || continue
    pr_num_ok "$n" || die 'a pull request of this commit has a malformed number'
    if [[ $pstate == open && $psha == "$HEAD_SHA" && $pbase == "$REPO" ]]; then guard_prs+=("$n"); fi
  done <<< "$found"
fi
if ((${#guard_prs[@]} > 0)); then
  jq -r '.checks[].workflow' "$PROFILE" | LC_ALL=C sort -u > "$WORK/guard-protected.txt" \
    || die 'could not list the profile workflows for the tamper guard'
  guard_touched=()
  for n in $(printf '%s\n' "${guard_prs[@]}" | sort -un); do
    : > "$WORK/guard-result.txt" || die 'could not prepare the tamper guard result file'
    gout=$(env -u APPROVAL_LABEL REPO="$REPO" PR_NUMBER="$n" EXTRA_PROTECTED_FILE="$WORK/guard-protected.txt" \
      GUARD_RESULT_FILE="$WORK/guard-result.txt" bash "$GUARD" 2>&1)
    grc=$?
    printf '%s\n' "$gout" | sed "s/^/tamper guard PR #$n: /"
    ((grc == 0)) && continue
    [[ -s $WORK/guard-result.txt ]] || die "tamper guard could not check PR #$n"
    mapfile -t -O "${#guard_touched[@]}" guard_touched < "$WORK/guard-result.txt"
  done
  if ((${#guard_touched[@]} > 0)); then
    state=failure
    description="gate files changed without owner approval: $(printf '%s\n' "${guard_touched[@]}" | LC_ALL=C sort -u | grep . | paste -sd, -)"
    write_summary "$state" "$description" 0
    post "$state" "$description" || die 'could not publish the status'
    finish_output
    echo "$CONTEXT = $state: $(clip "$description")"
    echo "::error::$CONTEXT failed: $description"
    exit 1
  fi
fi

clock_now() { "${CI_GATE_CLOCK:-date}" +%s; }
deadline=$(( $(clock_now) + WAIT_SECONDS ))
wait_again() {
  local remaining delay quota available reset quota_delay
  remaining=$((deadline - $(clock_now)))
  ((remaining > 0)) || return 1
  # Leave quota for the settle guard and final status. Spread estimated poll requests
  # across the reset window; a depleted budget sleeps to reset (or the deadline).
  quota=$(gh api rate_limit --jq '[.resources.core.remaining, .resources.core.reset] | @tsv') \
    || die 'could not read the API quota'
  IFS=$'\t' read -r available reset <<< "$quota"
  [[ $available =~ ^[0-9]+$ && $reset =~ ^[0-9]+$ ]] || die 'API quota is malformed'
  remaining=$((deadline - $(clock_now)))
  ((remaining > 0)) || return 1
  delay=$POLL_SECONDS
  reset=$((reset - $(clock_now)))
  if ((reset > 0)); then
    if ((available <= 20)); then
      quota_delay=$reset
    else
      quota_delay=$(((reset * poll_cost + available - 21) / (available - 20)))
    fi
    ((delay >= quota_delay)) || delay=$quota_delay
  fi
  ((delay <= remaining)) || delay=$remaining
  echo "wait: $state ($description); ${remaining}s remaining, polling again in ${delay}s"
  "${CI_GATE_SLEEP:-sleep}" "$delay"
}

state='' description='' rc=1 settled=0 round=0
while :; do
  if ((round > 0 && WAIT_SECONDS > 0 && $(clock_now) >= deadline)); then break; fi
  if ((round >= MAX_ROUNDS)); then
    if ((WAIT_SECONDS > 0)) && wait_again && (($(clock_now) < deadline)); then
      round=0
    else
      break
    fi
  fi
  round=$((round + 1))
  # b. snapshot, fingerprint, jobs, verdict
  fetch_runs || die 'could not read the workflow runs'
  fp_before=$(fingerprint "$WORK/workflow-runs.json") || die 'workflow runs are malformed'
  jq --arg gate "$GATE_NAME" -c -f "$SUITE/profiles/ci-gate/select-runs.jq" "$WORK/workflow-runs.json" > "$WORK/kept-runs.json" \
    || die 'workflow runs are malformed'
  : > "$WORK/jobs.ndjson"
  poll_cost=10
  while read -r run; do
    printf '%s\n' "$run" > "$WORK/run.json" || die 'could not write a workflow run record'
    id=$(jq -r .id "$WORK/run.json")
    [[ $id =~ ^[0-9]+$ ]] || die 'a workflow run has no numeric id'
    key=$(fingerprint "$WORK/kept-runs.json" | jq -c --argjson id "$id" '.[] | select(.[0] == $id)') \
      || die 'workflow run fingerprint is malformed'
    status=$(jq -r .status "$WORK/run.json")
    if [[ $status == completed && ${completed_keys[$id]:-} == "$key" ]]; then
      printf '%s\n' "${completed_jobs[$id]}" >> "$WORK/jobs.ndjson"
    else
      unset 'completed_keys[$id]' 'completed_jobs[$id]'
      jobs=$(gh api --paginate "repos/$REPO/actions/runs/$id/jobs?filter=latest&per_page=100" --jq '.jobs[]' \
        | jq -c --slurpfile run "$WORK/run.json" '. + {run: {id: $run[0].id, name: $run[0].name, path: $run[0].path, status: $run[0].status}}') \
        || die "could not read the jobs of run $id"
      printf '%s\n' "$jobs" >> "$WORK/jobs.ndjson"
      if [[ $status == completed ]]; then
        completed_keys[$id]=$key
        completed_jobs[$id]=$jobs
      fi
      # Include pagination and headroom for another active-run jobs fetch.
      job_count=$(jq -s length <<< "$jobs")
      poll_cost=$((poll_cost + 1 + job_count / 100))
    fi
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
  # b2. pull_request wait (pull_request only; WAIT_SECONDS=0 everywhere else, so workflow_run and
  # the sweep are untouched). A pull_request run evaluates once, with no later workflow_run to
  # re-evaluate it, and it can start before the other workflows have created their runs. So a
  # verdict that only means "not finished yet" (pending, or never reported / never completed)
  # is not written: poll, and do not count the poll as a settle round. A real failure, and
  # success, are written at once. When the wait is used up, pending becomes a failure that
  # names what was still running; never reported / never completed already name theirs.
  if ((WAIT_SECONDS > 0)); then
    case "$state:$description" in
      pending:* | failure:'never reported: '* | failure:'never completed: '*)
        if wait_again; then
          round=$((round - 1))
          continue
        fi
        if [[ $state == pending ]]; then
          state=failure; rc=1
          description="gave up after $((WAIT_SECONDS / 60)) min: $description"
        fi ;;
    esac
  fi
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
  # A bootstrap PR may have no default-branch evaluator to clear our stale success.
  if ((WAIT_SECONDS > 0)) && [[ $state == success ]]; then
    post pending 'runs still changing' || die 'could not publish the status'
    finish_output
  fi
  echo "round $round: the workflow runs changed while publishing; evaluating again"
done

# e. never settled: fail at the pull_request deadline, pending for other events
if [[ $settled -ne 1 ]]; then
  state=pending; description='runs still changing'; rc=0
  if ((WAIT_SECONDS > 0)); then
    state=failure; description='gave up waiting: runs still changing'; rc=1
  fi
  echo "::warning::the workflow runs of $HEAD_SHA kept changing for $MAX_ROUNDS rounds; publishing $state"
  write_summary "$state" "$description" 0
  post "$state" "$description" || die 'could not publish the status'
  finish_output
  echo "$CONTEXT = $state: $description"
fi
# A pending verdict is a normal wait for the next workflow_run; only failure is red.
if [[ $state == failure ]]; then echo "::error::$CONTEXT failed: $description"; exit 1; fi
exit 0
