#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-sweep.sh — re-evaluate the CI/gate status of every open pull request head and of the
# default branch head, by running the guarded publisher (scripts/ci-gate-publish.sh) once per
# distinct head SHA. It is the body of the `schedule` and `workflow_dispatch` events of the
# reusable; the `workflow_run` event runs the publisher directly on one SHA. It talks to GitHub
# only through `gh` on PATH, so a stub can drive it (tests/ci-gate.sh).
#
# Environment (values arrive through env:, never interpolated into a script):
#   REPO CONTEXT TIMEOUT_MINUTES GATE_NAME SUITE   as for the publisher
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
#  3. Runs the publisher for each SHA, with no early in_progress pending. It passes the publisher
#     GUARD_PRS: EVERY open pull request headed by that SHA (from the listing above, forks included;
#     several pull requests can share one head), with GUARD_NO_LOOKUP=1 ONLY when the listing completed
#     (every page, every row usable); otherwise the publisher also runs its own commit lookup,
#     so the publisher runs the tamper guard for exactly those, with no lookup of its own; the default
#     branch head (unless a pull request shares it) gets none. A failure on one SHA
#     does not stop the others, except "rate limited, no verdict": the rest would meet the same
#     limit, so they are listed as not evaluated and the next sweep takes them.
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
TAB=$'\t'
errors=0
rows="$WORK/rows.tsv"; : > "$rows"        # sha<TAB>source<TAB>state<TAB>description
cand="$WORK/candidates.tsv"; : > "$cand"  # updated_at<TAB>sha<TAB>source
guardprs="$WORK/guard-prs.tsv"; : > "$guardprs"  # sha<TAB>number of each open pull request (forks included)

# 1. the default branch head, first: it sorts above every pull request
branch=$(gh api "repos/$REPO" --jq .default_branch 2> /dev/null) || branch=''
if [[ $branch =~ ^[A-Za-z0-9._/-]+$ ]]; then
  dsha=$(gh api "repos/$REPO/branches/$branch" --jq .commit.sha 2> /dev/null) || dsha=''
else
  dsha=''
fi
if [[ $dsha =~ ^[0-9a-f]{40}$ ]]; then
  printf '9999-12-31T23:59:59Z\t%s\tdefault branch\n' "$dsha" >> "$cand"
else
  echo "::error::ci-gate-sweep: could not read the default branch head of $REPO; that head was NOT evaluated"
  printf '%s\tdefault branch\terror\tdefault branch head unreadable\n' '-' >> "$rows"
  errors=$((errors + 1))
fi

# open pull requests, every page. listing_complete=1 only when every page was read and every row was
# usable: only then may the publisher skip its own commit lookup (GUARD_NO_LOOKUP=1). The tamper guard is
# skipped only on POSITIVE evidence that no pull request shares a SHA, never because a listing failed.
listing_complete=0
if gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" \
  --jq '.[] | [.updated_at, .head.sha, "PR #\(.number)", .number] | @tsv' > "$WORK/pulls.tsv" 2> "$WORK/pulls.err"; then
  listing_complete=1
  while IFS=$'\t' read -r upd sha src num; do
    if [[ $sha =~ ^[0-9a-f]{40}$ && -n $upd ]]; then
      printf '%s\t%s\t%s\n' "$upd" "$sha" "$src" >> "$cand"
      # tamper guard: every open pull request into REPO, fork or not (docs/CI-GATE.adoc, "Tamper guard")
      if [[ $num =~ ^[1-9][0-9]{0,9}$ ]]; then
        printf '%s\t%s\n' "$sha" "$num" >> "$guardprs"
      else
        echo "::warning::ci-gate-sweep: $src has no usable number; the publisher looks the pull requests up itself"
        listing_complete=0
      fi
    else
      echo "::error::ci-gate-sweep: $src has an unusable head SHA or date; it was NOT evaluated"
      listing_complete=0   # its head is unknown, so it may share a SHA that is evaluated
      printf '%s\t%s\terror\tunusable head SHA\n' '-' "$src" >> "$rows"
      errors=$((errors + 1))
    fi
  done < "$WORK/pulls.tsv"
else
  echo "::error::ci-gate-sweep: could not list the open pull requests of $REPO; they were NOT evaluated"
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
n=0
while IFS=$'\t' read -r _ sha src; do
  n=$((n + 1))
  dir="$WORK/sha-$n"; mkdir -p "$dir"
  echo "::group::$CONTEXT for $sha ($src)"
  rc=0
  prs=$(awk -F'\t' -v s="$sha" '$1 == s { print $2 }' "$guardprs" | sort -un | paste -sd' ' -)
  # an incomplete listing: the publisher also runs its own commit lookup (fail closed)
  nolookup=0; ((listing_complete == 1)) && nolookup=1
  env -u GITHUB_OUTPUT -u GUARD_EVENT_PRS -u GUARD_HEAD_REPO -u GUARD_HEAD_BRANCH GUARD_NO_LOOKUP="$nolookup" GUARD_PRS="$prs" HEAD_SHA="$sha" WORK="$dir/work" GITHUB_STEP_SUMMARY="$dir/summary.md" \
    SERVER_URL="$SERVER_URL" RUN_ID="$RUN_ID" WF_REPO="$WF_REPO" WF_SHA="$WF_SHA" \
    bash "$PUBLISH" > "$dir/out.txt" 2>&1 || rc=$?
  cat "$dir/out.txt"
  echo "::endgroup::"
  line=$(grep -F -- "$CONTEXT = " "$dir/out.txt" | tail -n 1)
  state=''; desc=''
  if [[ $line =~ ^"$CONTEXT = "([a-z]+):\ (.*)$ ]]; then state=${BASH_REMATCH[1]}; desc=${BASH_REMATCH[2]}; fi
  if (( rc != 0 )); then
    # the publisher exits 1 for a failure verdict and for any error; only a printed failure is a verdict
    [[ $state == failure ]] || { state=error; desc=$(grep -h '^::error::' "$dir/out.txt" | tail -n 1 | cut -c1-140); }
    errors=$((errors + 1))
  elif [[ -z $state ]]; then
    state=error; desc='no verdict line in the publisher output'; errors=$((errors + 1))
  fi
  printf '%s\t%s\t%s\t%s\n' "$sha" "$src" "$state" "$desc" >> "$rows"
  if grep -qF 'rate limited, no verdict' "$dir/out.txt"; then
    left=$(($(grep -c . "$WORK/todo.tsv") - n))
    if ((left > 0)); then
      echo "::warning::ci-gate-sweep: rate limited; the $left remaining head SHA(s) were NOT evaluated by this sweep"
      printf '%s\t%s\tskipped\t%s not evaluated: rate limited\n' '-' 'rate limited' "$left" >> "$rows"
    fi
    break
  fi
done < "$WORK/todo.tsv"

# 4. the table, and the exit code
{
  echo "### $CONTEXT sweep of $REPO"
  echo
  echo "$(grep -c . "$WORK/todo.tsv" || true) of $total distinct head SHAs evaluated (cap $MAX). Profile \`$REPO\` at \`${WF_REPO:-?}@${WF_SHA:-?}\`."
  echo
  echo '| Commit | Source | State | Description |'
  echo '|---|---|---|---|'
  while IFS=$'\t' read -r sha src state desc; do
    desc=${desc//|/\\|}
    printf '| `%s` | %s | %s | %s |\n' "${sha:0:12}" "$src" "$state" "$desc"
  done < "$rows"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
if (( errors > 0 )); then
  echo "::error::ci-gate-sweep: $errors head(s) ended in failure or error; see the table in the step summary"
  exit 1
fi
exit 0
