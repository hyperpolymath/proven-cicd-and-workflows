#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven-bench-run.sh: measure one [bench.NAME] target, classify it against the
# mean of the last 10 main runs (Six Sigma, TESTING-TAXONOMY Part IV), record it.
# Env: BENCH_NAME BENCH_COMMAND BENCH_METRIC LOWER_IS_BETTER BASELINING
#      GH_TOKEN GITHUB_REPOSITORY RUNNER_TEMP PR_LABELS (JSON array, may be null)
# Metric "seconds" times the command; any other metric reads the last stdout line as a number.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
name=${BENCH_NAME:?} tmp=${RUNNER_TEMP:-/tmp}
out="$tmp/bench-$name.json"
if [[ $BENCH_METRIC == seconds ]]; then
  s=$(date +%s.%N); bash -o pipefail -c "$BENCH_COMMAND" || { echo "::error::bench $name: command failed"; exit 1; }
  e=$(date +%s.%N); value=$(awk -v s="$s" -v e="$e" 'BEGIN{printf "%.6f", e-s}') \
    || { echo "::error::bench $name: could not compute elapsed seconds"; exit 1; }
else
  res=$(bash -o pipefail -c "$BENCH_COMMAND") || { echo "::error::bench $name: command failed"; exit 1; }
  value=$(tail -n1 <<<"$res")
  [[ $value =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || { echo "::error::bench $name: last output line is not a number: $value"; exit 1; }
fi
# History: artifacts proven-bench-NAME produced by runs on the default branch.
hist=""
if [[ -n ${GH_TOKEN:-} ]]; then
  list=$(gh api "repos/$GITHUB_REPOSITORY/actions/artifacts?name=proven-bench-$name&per_page=30" \
    --jq '[.artifacts[]|select(.expired==false and .workflow_run.head_branch=="main")]|.[0:10]|.[]|.id' 2>/dev/null || true)
  for id in $list; do
    d=$(mktemp -d)
    if gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$id/zip" > "$d/a.zip" 2>/dev/null && unzip -qo "$d/a.zip" -d "$d"; then
      v=$(jq -r '.value // empty' "$d"/*.json 2>/dev/null | head -n1); [[ -n $v ]] && hist+="${hist:+,}$v"
    fi
  done
fi
# Approval must survive the merge: on a push to main, read the labels of the PR that produced the commit.
if [[ ${GITHUB_EVENT_NAME:-} == push && -n ${GH_TOKEN:-} ]]; then
  PR_LABELS=$(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" \
    --jq '[.[]|select(.merged_at!=null)|.labels[].name]' 2>/dev/null || echo null)
elif [[ ${GITHUB_EVENT_NAME:-} == merge_group && -n ${GH_TOKEN:-} ]]; then
  # A queued PR is not merged yet and the event has no pull_request labels; the PR number is in the
  # merge-group ref (refs/heads/gh-readonly-queue/BASE/pr-N-SHA).
  pr=$(sed -n 's#.*/pr-\([0-9][0-9]*\)-.*#\1#p' <<<"${GITHUB_REF:-}")
  PR_LABELS=null
  if [[ -n $pr ]]; then
    PR_LABELS=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$pr" --jq '[.labels[].name]' 2>/dev/null || echo null)
  fi
fi
flags=(); [[ ${LOWER_IS_BETTER:-true} == false ]] && flags+=(--higher-is-better)
[[ ${BASELINING:-false} == true ]] && flags+=(--baselining)
gate=${PROVEN_GATE:-$(bash "$here/proven-gate-bin.sh")}
verdict=$("$gate" bench-gate "$value" --history "$hist" ${flags[@]+"${flags[@]}"}); rc=$?
echo "$verdict"
if (( rc > 3 )) || { (( rc != 0 )) && [[ -z $verdict ]]; }; then
  echo "::error::bench $name: the gate itself failed (exit $rc); no verdict"; exit 1
fi
printf '{"name":"%s","value":%s,"metric":"%s"}\n' "$name" "$value" "$BENCH_METRIC" > "$out"
{ echo "### bench $name"; echo '```'; echo "$verdict"; echo '```'; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
case $rc in
  0) exit 0 ;;
  3) if jq -e 'index("bench-approved")' <<<"${PR_LABELS:-null}" >/dev/null 2>&1; then echo "::warning::bench $name Acceptable: approved by label bench-approved"; exit 0; fi
     echo "::error::bench $name is Acceptable (20 to 50% worse): a reviewer must apply the bench-approved label"; exit 1 ;;
  *) echo "::error::bench $name blocked ($(jq -r .class <<<"$verdict" 2>/dev/null))"; exit 1 ;;
esac
