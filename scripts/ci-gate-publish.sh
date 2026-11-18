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
#   WAIT_SECONDS POLL_SECONDS  pull_request: keep polling while the verdict only means
#                    "not finished" (pending, never reported, never completed); 0 elsewhere
#   CI_GATE_CLOCK    test hook: command returning elapsed-clock seconds (default: date +%s)
#   CI_GATE_SLEEP    test hook: the sleep command
#   GITHUB_STEP_SUMMARY, GITHUB_OUTPUT                  optional; `published=true` is written
#                                                       once a verdict status was posted
#
# (The `pending` "re-run started" write for an in_progress event is the FIRST STEP of the
#  workflow, before any suite file is read; this script posts only verdicts.)
#
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
#     read writes anyway. A head whose verdict keeps changing can still reach the cap.
#  g. Fail closed: verdict exit code and state must agree; any API or input error posts a
#     failure status and exits 1; descriptions are at most 140 characters.
set -uo pipefail
MAX_ROUNDS=5
WAIT_SECONDS=${WAIT_SECONDS:-0}; POLL_SECONDS=${POLL_SECONDS:-20}   # pull_request wait; 0 = evaluate once
SUITE=${SUITE:-}; WORK=${WORK:-}
SERVER_URL=${SERVER_URL:-https://github.com}; RUN_ID=${RUN_ID:-0}; WF_REPO=${WF_REPO:-}; WF_SHA=${WF_SHA:-}
for v in REPO HEAD_SHA CONTEXT TIMEOUT_MINUTES GATE_NAME SUITE; do
  [[ -n ${!v:-} ]] || { echo "::error::ci-gate-publish: $v is not set; NO VERDICT WAS PRODUCED"; exit 1; }
done
[[ $HEAD_SHA =~ ^[0-9a-f]{40}$ ]] || { echo "::error::ci-gate-publish: HEAD_SHA is not a 40-hex commit"; exit 1; }
[[ $WAIT_SECONDS =~ ^[0-9]+$ && $POLL_SECONDS =~ ^[1-9][0-9]*$ ]] || { echo "::error::ci-gate-publish: WAIT_SECONDS must be a non-negative and POLL_SECONDS a positive integer; NO VERDICT WAS PRODUCED"; exit 1; }
[[ -n $WORK ]] || WORK=$(mktemp -d) || exit 1
mkdir -p "$WORK" || exit 1
PROFILE="$SUITE/profiles/ci-gate/$REPO.json"
published=0

# The statuses API rejects a description with a 4-byte UTF-8 character (a codepoint above U+FFFF, eg an
# emoji in a job or workflow name): HTTP 422, and the gate would go red for the wrong reason. clip() is the
# one chokepoint every description passes through (post(), so die() too): strip those codepoints FIRST,
# then cut to 140 characters (by characters, whatever the locale).
BMP_ONLY='explode | map(select(. <= 65535)) | implode'   # regex-free: the same on every supported jq (1.6 to 1.8.1)
clip() { jq -rn --arg d "$1" "\$d | $BMP_ONLY | if length > 140 then .[0:139] + \"…\" else . end"; }

current_matches() { # <state> <clipped description> -> prints "same" only if the combined status holds exactly this for $CONTEXT
  local r
  r=$(gh api --paginate "repos/$REPO/commits/$HEAD_SHA/status?per_page=100" --jq '.statuses[]' 2> /dev/null \
    | jq -rs --arg c "$CONTEXT" --arg s "$1" --arg d "$2" \
      'if type == "array" and any(.[]; type == "object" and .context == $c and .state == $s and (.description // "") == $d) then "same" else "differs" end' 2> /dev/null) || return 0
  printf '%s\n' "$r"
}

post() { # <state> <description> — one commit status; returns gh's exit code
  # GitHub keeps at most 1000 statuses per SHA and context, after which every write fails (die()
  # included). A write that would repeat the status already standing for this context (same state,
  # same description; target_url is not compared) is skipped and counts as published. A failed or
  # malformed read of the current status falls toward writing.
  local desc; desc=$(clip "$2")
  if [[ $(current_matches "$1" "$desc") == same ]]; then
    echo "ci-gate: status already $1 with this description on $HEAD_SHA; write skipped (1000-status cap)"
    return 0
  fi
  gh api -X POST "repos/$REPO/statuses/$HEAD_SHA" \
    -f state="$1" -f context="$CONTEXT" -f description="$desc" \
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

clock_now() { "${CI_GATE_CLOCK:-date}" +%s; }
deadline=$(( $(clock_now) + WAIT_SECONDS ))
wait_again() {
  local remaining delay
  remaining=$((deadline - $(clock_now)))
  ((remaining > 0)) || return 1
  delay=$POLL_SECONDS
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
  while read -r run; do
    printf '%s\n' "$run" > "$WORK/run.json" || die 'could not write a workflow run record'
    id=$(jq -r .id "$WORK/run.json")
    [[ $id =~ ^[0-9]+$ ]] || die 'a workflow run has no numeric id'
    { gh api --paginate "repos/$REPO/actions/runs/$id/jobs?filter=latest&per_page=100" --jq '.jobs[]' \
        | jq -c --slurpfile run "$WORK/run.json" '. + {run: {id: $run[0].id, name: $run[0].name, path: $run[0].path, status: $run[0].status}}' \
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
