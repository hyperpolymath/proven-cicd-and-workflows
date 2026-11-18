#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-sweep.sh — re-evaluate the CI/gate status of every open pull request head and of the
# default branch head, by running the guarded publisher (scripts/ci-gate-publish.sh) once per
# distinct head SHA. It is the body of the `schedule` and `workflow_dispatch` events of the
# reusable; the `workflow_run` event runs the publisher directly on one SHA. It talks to GitHub
# only through scripts/ci-gate-lib.sh (gate_api over `gh` on PATH), so a stub can drive it (tests/ci-gate.sh).
#
# Environment (values arrive through env:, never interpolated into a script):
#   REPO CONTEXT TIMEOUT_MINUTES GATE_NAME SUITE   as for the publisher
#   CI_GATE_BACKOFF_MAX_SECONDS                    the back-off bound, shared by the whole sweep (scripts/ci-gate-lib.sh)
#   WORK              scratch directory (default: a fresh mktemp -d)
#   SERVER_URL RUN_ID WF_REPO WF_SHA                 passed through to the publisher
#   CI_GATE_SWEEP_MAX test hook: the cap on SHAs (default 100)
#   GITHUB_STEP_SUMMARY                              optional; the table is appended to it
#
# What it does:
#  1. Lists the open pull requests (`pulls?state=open&per_page=100`, all pages) and the head of
#     the default branch.
#  2. De-duplicates the head SHAs. Above the cap (100) it keeps the most recently updated and
#     prints a ::warning:: naming how many were skipped. The default branch head counts as the
#     most recently updated. It never skips silently.
#  3. Runs the publisher for each SHA (no pending write first: only a pull_request start writes one).
#     A failure on one SHA does not stop the others. The exception is an unavailable API (the
#     publisher exits 75 after writing pending, or reports unavailable=true in its own GITHUB_OUTPUT file
#     even though its pending write failed and it exited 1): the remaining SHAs are then NOT evaluated, a
#     loud ::error:: names how many and whether the pending was written or its write failed, and the sweep
#     ends red. No failure status is ever posted for it. The same stop applies to a discovery read (the
#     repository, the default branch, the pull request listing) that meets an outage: it ends the sweep
#     at once, before any further API call or publisher run, naming the step and the heads not evaluated.
#     Other discovery errors keep the partial discovery.
#  4. Writes a table (SHA, source, state, description) to the step summary and exits non-zero if
#     any SHA ended in failure or error, or if a listing could not be read.
#
# Because the publisher skips a write that repeats the standing status (the 1000-status cap per SHA
# and context), an unchanged head costs this sweep no new status.
# The sweep is itself an evaluator: it writes a commit status, last-writer-wins like every other
# evaluator (docs/CI-GATE.adoc, "Residual limit"). It does not remove that limit.
set -uo pipefail
SUITE=${SUITE:-}; WORK=${WORK:-}
SERVER_URL=${SERVER_URL:-https://github.com}; RUN_ID=${RUN_ID:-0}; WF_REPO=${WF_REPO:-}; WF_SHA=${WF_SHA:-}
MAX=${CI_GATE_SWEEP_MAX:-100}
for v in REPO CONTEXT TIMEOUT_MINUTES GATE_NAME SUITE; do
  [[ -n ${!v:-} ]] || { echo "::error::ci-gate-sweep: $v is not set; NO VERDICT WAS PRODUCED"; exit 1; }
done
[[ $REPO =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && ${REPO#*/} != . && ${REPO#*/} != .. ]] \
  || { echo "::error::ci-gate-sweep: REPO is not an owner/name coordinate; NO VERDICT WAS PRODUCED"; exit 1; }
[[ $MAX =~ ^[1-9][0-9]*$ ]] || { echo "::error::ci-gate-sweep: the cap is not a positive integer"; exit 1; }
[[ -n $WORK ]] || WORK=$(mktemp -d) || exit 1
mkdir -p "$WORK" || exit 1
PUBLISH="$SUITE/scripts/ci-gate-publish.sh"
[[ -f $PUBLISH ]] || { echo "::error::ci-gate-sweep: $PUBLISH is missing; NO VERDICT WAS PRODUCED"; exit 1; }
[[ -f $SUITE/scripts/ci-gate-lib.sh ]] || { echo "::error::ci-gate-sweep: $SUITE/scripts/ci-gate-lib.sh is missing; NO VERDICT WAS PRODUCED"; exit 1; }
# One back-off budget for the whole sweep, shared with every publisher it starts.
GATE_WAITED_FILE="$WORK/.waited"; rm -f "$GATE_WAITED_FILE" "$GATE_WAITED_FILE.reserve"
export GATE_WAITED_FILE
# shellcheck source-path=SCRIPTDIR source=ci-gate-lib.sh
source "$SUITE/scripts/ci-gate-lib.sh" || exit 1
TAB=$'\t'
errors=0
rows="$WORK/rows.tsv"; : > "$rows"        # sha<TAB>source<TAB>state<TAB>description
cand="$WORK/candidates.tsv"; : > "$cand"  # updated_at<TAB>sha<TAB>source

write_table() { # <headline> — the step summary table
  {
    echo "### $CONTEXT sweep of $REPO"
    echo
    echo "$1"
    echo
    echo '| Commit | Source | State | Description |'
    echo '|---|---|---|---|'
    while IFS=$'\t' read -r sha src state desc; do
      desc=${desc//|/\\|}
      printf '| `%s` | %s | %s | %s |\n' "${sha:0:12}" "$src" "$state" "$desc"
    done < "$rows"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}
discovery_outage() { # <step that was reading> — the API is unavailable: stop NOW, no further call, no publisher
  local found
  found=$(cut -f2 "$cand" | sort -u | grep -c . || true)
  echo "::error::ci-gate-sweep: the GitHub API was rate-limited or unavailable while $1 (${GATE_API_ERR:-no detail}); the sweep stopped before evaluating any head. $found head(s) already discovered were NOT evaluated, and the open pull requests may not all be known. No status was written and no failure was posted."
  printf '%s\t%s\tunavailable\t%s\n' '-' "$1" "discovery stopped (API unavailable); $found discovered head(s) not evaluated" >> "$rows"
  write_table "Discovery stopped: the GitHub API was unavailable while $1; no head was evaluated."
  exit 1
}

# 1. the default branch head, first: it sorts above every pull request
branch=''; dsha=''
rc=0; gate_api GET "repos/$REPO" "$WORK/repo.json" || rc=$?
((rc == 75)) && discovery_outage 'reading the repository (default branch name)'
if ((rc == 0)); then branch=$(jq -r '.default_branch // empty' "$WORK/repo.json" 2> /dev/null) || branch=''; fi
if [[ $branch =~ ^[A-Za-z0-9._/-]+$ ]]; then
  rc=0; gate_api GET "repos/$REPO/branches/$branch" "$WORK/branch.json" || rc=$?
  ((rc == 75)) && discovery_outage 'reading the default branch head'
  if ((rc == 0)); then dsha=$(jq -r '.commit.sha // empty' "$WORK/branch.json" 2> /dev/null) || dsha=''; fi
fi
if [[ $dsha =~ ^[0-9a-f]{40}$ ]]; then
  printf '9999-12-31T23:59:59Z\t%s\tdefault branch\n' "$dsha" >> "$cand"
else
  echo "::error::ci-gate-sweep: could not read the default branch head of $REPO (${GATE_API_ERR:-no detail}); that head was NOT evaluated"
  printf '%s\tdefault branch\terror\tdefault branch head unreadable\n' '-' >> "$rows"
  errors=$((errors + 1))
fi

# open pull requests, every page
rc=0; gate_paginate "repos/$REPO/pulls?state=open&per_page=100" '.[]' "$WORK/pulls.json" || rc=$?
((rc == 75)) && discovery_outage 'listing the open pull requests'
if ((rc == 0)) \
  && jq -r '.[] | [.updated_at, .head.sha, "PR #\(.number)"] | @tsv' "$WORK/pulls.json" > "$WORK/pulls.tsv" 2> "$WORK/pulls.err"; then
  while IFS=$'\t' read -r upd sha src; do
    if [[ $sha =~ ^[0-9a-f]{40}$ && -n $upd ]]; then
      printf '%s\t%s\t%s\n' "$upd" "$sha" "$src" >> "$cand"
    else
      echo "::error::ci-gate-sweep: $src has an unusable head SHA or date; it was NOT evaluated"
      printf '%s\t%s\terror\tunusable head SHA\n' '-' "$src" >> "$rows"
      errors=$((errors + 1))
    fi
  done < "$WORK/pulls.tsv"
else
  echo "::error::ci-gate-sweep: could not list the open pull requests of $REPO ($GATE_API_ERR); they were NOT evaluated"
  printf '%s\tpull requests\terror\tlisting failed\n' '-' >> "$rows"
  errors=$((errors + 1))
fi

# 2. most recently updated first, one line per SHA, then the cap
sort -s -r -t "$TAB" -k1,1 "$cand" | awk -F'\t' '!seen[$2]++' > "$WORK/distinct.tsv"
total=$(grep -c . "$WORK/distinct.tsv" || true)
head -n "$MAX" "$WORK/distinct.tsv" > "$WORK/todo.tsv"
if (( total > MAX )); then
  skipped=$((total - MAX))
  echo "::warning::ci-gate-sweep: $total distinct head SHAs in $REPO exceed the cap of $MAX; $skipped (the least recently updated) were NOT evaluated by this sweep"
  printf '%s\t%s\tskipped\t%s over the cap of %s, not evaluated\n' '-' 'over the cap' "$skipped" "$MAX" >> "$rows"
fi
echo "ci-gate-sweep: $REPO: evaluating $(grep -c . "$WORK/todo.tsv" || true) of $total distinct head SHAs"

# 3. one publisher run per SHA; a failure never stops the others
n=0; unavail_at=0; pend_ok=1
while IFS=$'\t' read -r _ sha src; do
  n=$((n + 1))
  dir="$WORK/sha-$n"; mkdir -p "$dir"
  echo "::group::$CONTEXT for $sha ($src)"
  rc=0
  : > "$dir/gh-output"   # a private GITHUB_OUTPUT: the publisher's unavailable=true flag is read below
  env HEAD_SHA="$sha" WORK="$dir/work" GITHUB_STEP_SUMMARY="$dir/summary.md" GITHUB_OUTPUT="$dir/gh-output" \
    SERVER_URL="$SERVER_URL" RUN_ID="$RUN_ID" WF_REPO="$WF_REPO" WF_SHA="$WF_SHA" \
    bash "$PUBLISH" > "$dir/out.txt" 2>&1 || rc=$?
  cat "$dir/out.txt"
  echo "::endgroup::"
  line=$(grep -F -- "$CONTEXT = " "$dir/out.txt" | tail -n 1)
  state=''; desc=''
  if [[ $line =~ ^"$CONTEXT = "([a-z]+):\ (.*)$ ]]; then state=${BASH_REMATCH[1]}; desc=${BASH_REMATCH[2]}; fi
  if (( rc == 75 )) || grep -qx 'unavailable=true' "$dir/gh-output"; then
    # the API was unavailable. rc 75: the publisher wrote pending (never failure). rc 1 with the flag: it could
    # not even write that pending. Either way going on would only meet the outage again for every other head,
    # so stop, keep the sweep red, and say loudly how many heads this sweep did not evaluate.
    state=unavailable
    if (( rc == 75 )); then pend_ok=1; desc='GitHub API rate-limited or unavailable; pending written, sweep stopped'
    else pend_ok=0; desc='GitHub API rate-limited or unavailable; the pending write FAILED (no status written), sweep stopped'; fi
    errors=$((errors + 1)); unavail_at=$n
    printf '%s\t%s\t%s\t%s\n' "$sha" "$src" "$state" "$desc" >> "$rows"
    break
  fi
  if (( rc != 0 )); then
    # the publisher exits 1 for a failure verdict and for any error; only a printed failure is a verdict
    [[ $state == failure ]] || { state=error; desc=$(grep -h '^::error::' "$dir/out.txt" | tail -n 1 | cut -c1-140); }
    errors=$((errors + 1))
  elif [[ -z $state ]]; then
    state=error; desc='no verdict line in the publisher output'; errors=$((errors + 1))
  fi
  printf '%s\t%s\t%s\t%s\n' "$sha" "$src" "$state" "$desc" >> "$rows"
done < "$WORK/todo.tsv"
if (( unavail_at > 0 )); then
  left=$(( $(grep -c . "$WORK/todo.tsv" || true) - unavail_at ))
  echo "::error::ci-gate-sweep: the GitHub API was rate-limited or unavailable; the sweep stopped at head $unavail_at and $left further head(s) were NOT evaluated. $( ((pend_ok)) && echo 'The pending status was written for that head.' || echo 'The pending write for that head FAILED: no status was written there.') No failure status was posted for this."
  printf '%s\t%s\tskipped\t%s further head(s) not evaluated (API unavailable)\n' '-' 'API unavailable' "$left" >> "$rows"
fi

# 4. the table, and the exit code
write_table "$(grep -c . "$WORK/todo.tsv" || true) of $total distinct head SHAs evaluated (cap $MAX). Profile \`$REPO\` at \`${WF_REPO:-?}@${WF_SHA:-?}\`."
if (( errors > 0 )); then
  echo "::error::ci-gate-sweep: $errors head(s) ended in failure or error; see the table in the step summary"
  exit 1
fi
exit 0
