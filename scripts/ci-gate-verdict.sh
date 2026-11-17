#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-verdict.sh — the pure verdict of the interim CI/gate. No network, no clock
# (the caller passes `now`), no writes except an optional summary file.
#
# Usage:
#   ci-gate-verdict.sh --profile F --repository OWNER/REPO --check-runs F --workflow-runs F \
#     --gate-name NAME --context CTX --now EPOCH --timeout-minutes N [--summary FILE]
#
#   --profile        profiles/ci-gate/<owner>/<repo>.json (validated here, fail closed)
#   --check-runs     JSON ARRAY of every check run for the head SHA (all pages concatenated)
#   --workflow-runs  JSON ARRAY of every workflow run for the head SHA (all pages)
#   --gate-name      the gate's own workflow name; its runs are ignored when deciding "active"
#   --context        the commit-status context the gate publishes (may not be in the list)
#   --summary FILE   write a longer markdown account (the step summary) there
#
# Output (stdout, two lines):   state=<success|pending|failure>   description=<=140 chars>
# Exit code:  0 success · 3 pending · 1 failure (and EVERY error: bad usage, unreadable or
# invalid input, jq failure). There is no code for "cannot tell"; cannot tell is failure.
#
# Rules (A3 law: no pass on absence):
#  1. Only check runs from app.slug == "github-actions" count. Other apps (SonarCloud,
#     CodeRabbit, ...) neither satisfy nor fail a required name, so another app cannot
#     spoof a required check by reusing its name.
#  2. For each required name, group its runs by check_suite.id and keep the latest (max id)
#     of each suite: a rerun supersedes the older attempt. EVERY such latest run counts,
#     because one name can be produced by several workflows.
#  3. Any such run completed with a conclusion other than "success" (failure, cancelled,
#     timed_out, skipped, neutral, action_required, stale, startup_failure, null, ...)
#     => failure. skipped and neutral are not passes.
#  4. Else every name has >=1 run and all are completed/success => success.
#  5. Else (a name is missing or still running): if some workflow run for the SHA other
#     than the gate's own is still queued/in_progress/waiting/requested/pending AND the
#     oldest workflow run for the SHA is younger than the timeout => pending; otherwise
#     failure ("never reported" or "timed out").
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)

fail() { # <description> — print a failure verdict and stop
  local d=$1
  ((${#d} > 140)) && d="${d:0:139}…"
  printf 'state=failure\ndescription=%s\n' "$d"
  exit 1
}

profile='' repository='' checks='' wruns='' gate='' context='' now='' timeout='' summary=''
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail 'ci-gate: usage error (option without a value)'
  case $1 in
    --profile) profile=$2 ;; --repository) repository=$2 ;; --check-runs) checks=$2 ;;
    --workflow-runs) wruns=$2 ;; --gate-name) gate=$2 ;; --context) context=$2 ;;
    --now) now=$2 ;; --timeout-minutes) timeout=$2 ;; --summary) summary=$2 ;;
    *) fail 'ci-gate: usage error (unknown option)' ;;
  esac
  shift 2
done
command -v jq >/dev/null || fail 'ci-gate: jq is unavailable'
for v in profile repository checks wruns gate context now timeout; do
  [[ -n ${!v} ]] || fail "ci-gate: usage error (missing --$v)"
done
[[ $now =~ ^[0-9]+$ && $timeout =~ ^[1-9][0-9]*$ ]] || fail 'ci-gate: usage error (now/timeout must be integers)'
[[ -f $profile && -f $checks && -f $wruns ]] || fail 'ci-gate: an input file is missing'
bash "$ROOT/scripts/validate-ci-gate-profile.sh" "$profile" "$repository" "$context" >/dev/null 2>&1 \
  || fail 'ci-gate: profile missing, malformed, for another repository, or names the gate itself'
jq -e 'type == "array"' "$checks" >/dev/null 2>&1 || fail 'ci-gate: check runs are not a JSON array'
jq -e 'type == "array"' "$wruns" >/dev/null 2>&1 || fail 'ci-gate: workflow runs are not a JSON array'

result=$(jq -n --slurpfile profile "$profile" --slurpfile cr "$checks" --slurpfile wr "$wruns" \
  --arg gate "$gate" --argjson now "$now" --argjson timeout "$timeout" '
  def active: ["queued", "in_progress", "waiting", "requested", "pending"];
  def names($a): $a | join(", ");
  $profile[0].checks as $req |
  [$cr[0][] | select((.app.slug // "") == "github-actions")] as $gh |
  [$wr[0][] | select(.name != $gate)] as $others |
  ($req | map(. as $n | {
     name: $n,
     latest: ([$gh[] | select(.name == $n)] | group_by(.check_suite.id) | map(max_by(.id)))
   } | . + {
     bad: [.latest[] | select(.status == "completed" and .conclusion != "success") | (.conclusion // "no conclusion")],
     open: [.latest[] | select(.status != "completed")]
   })) as $rows |
  ($rows | map(select(.bad | length > 0))) as $failed |
  ($rows | map(select(.latest | length == 0)) | map(.name)) as $missing |
  ($rows | map(select((.open | length > 0) and (.bad | length == 0))) | map(.name)) as $running |
  ([$others[] | select(.status as $s | active | index($s))] | length) as $active |
  (if ($others | length) > 0 then (($others | map(.created_at | fromdateiso8601) | min) as $oldest | (($now - $oldest) / 60 | floor)) else null end) as $age |
  ($missing + $running) as $waiting |
  (if ($failed | length) > 0 then
     {state: "failure", description: ("failed: " + ($failed | map(.name + " (" + (.bad | unique | join("/")) + ")") | join(", ")))}
   elif ($waiting | length) == 0 then
     {state: "success", description: ("all " + ($req | length | tostring) + " required checks passed")}
   elif $active > 0 and $age != null and $age < $timeout then
     {state: "pending", description: ("waiting for: " + names($waiting))}
   elif $active > 0 then
     {state: "failure", description: ("timed out after " + ($timeout | tostring) + " min: " + names($waiting))}
   else
     {state: "failure", description: ("never reported: " + names($waiting))}
   end) as $v |
  ($v | .description |= (if length > 140 then .[0:139] + "…" else . end)) + {summary: (
    "## " + $v.state + "\n\n" + $v.description + "\n\n| required check | latest run(s) |\n|---|---|\n" +
    ($rows | map("| " + .name + " | " +
      (if (.latest | length) == 0 then "never reported"
       else (.latest | map((.status) + "/" + (.conclusion // "-")) | join(", ")) end) + " |") | join("\n")) +
    "\n\nOther workflow runs active for this commit: " + ($active | tostring) +
    (if $age != null then "; oldest run is " + ($age | tostring) + " min old (timeout " + ($timeout | tostring) + ")." else "." end) +
    "\n\nOnly check runs from the github-actions app are counted; skipped and neutral are not passes.\n")}
' 2>/dev/null) || fail 'ci-gate: verdict evaluation failed on malformed check or workflow run data'

state=$(jq -r .state <<<"$result") || fail 'ci-gate: verdict evaluation failed'
desc=$(jq -r .description <<<"$result") || fail 'ci-gate: verdict evaluation failed'
[[ -z $summary ]] || jq -r .summary <<<"$result" > "$summary" || fail 'ci-gate: cannot write the summary'
printf 'state=%s\ndescription=%s\n' "$state" "$desc"
case $state in success) exit 0 ;; pending) exit 3 ;; *) exit 1 ;; esac
