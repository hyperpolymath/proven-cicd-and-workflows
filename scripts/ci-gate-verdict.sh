#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-verdict.sh — the pure verdict of the interim CI/gate. No network, no clock
# (the caller passes `now`), no writes except an optional summary file.
#
# Usage:
#   ci-gate-verdict.sh --profile F --repository OWNER/REPO --jobs F --workflow-runs F \
#     --gate-name NAME --context CTX --now EPOCH --timeout-minutes N [--summary FILE]
#
#   --profile        profiles/ci-gate/<owner>/<repo>.json (validated here, fail closed)
#   --jobs           JSON ARRAY of the jobs (filter=latest) of the kept workflow runs of the
#                    head SHA; each job carries `.run = {id, name, status}` of its run
#   --workflow-runs  JSON ARRAY of every workflow run of the head SHA (all pages); the kept
#                    runs are chosen here by profiles/ci-gate/select-runs.jq
#   --gate-name      the gate's own workflow name; its runs are ignored
#   --context        the commit-status context the gate publishes (may not be in the list)
#   --summary FILE   write a longer markdown account (the step summary) there
#
# Output (stdout, two lines):   state=<success|pending|failure>   description=<=140 chars>
# Exit code:  0 success · 3 pending · 1 failure (and EVERY error: bad usage, unreadable or
# invalid input, jq failure). There is no code for "cannot tell"; cannot tell is failure.
#
# Rules (A3 law: no pass on absence). Only GitHub Actions jobs are read; third-party checks
# (SonarCloud, CodeRabbit, ...) are out of scope. Kept runs: the gate's own runs dropped,
# the newest run per (workflow_id, event). A profile entry is an identity {job, workflow}: it
# is satisfied only if a kept run with that workflow `path` exists (an `@<ref>` suffix after the
# .yml/.yaml file name of a run path is ignored) and EVERY job of that exact
# name in those runs is completed/success; never one picked by max id. Two producers of one
# display name are two entries, both required. A missing run or job is reported as
# `<workflow file>:<job>`.
#  a. A required-name job completed with any conclusion but success (failure, cancelled,
#     timed_out, skipped, neutral, action_required, stale, null, ...) => failure at once.
#  b. Else if ANY workflow run of the commit but the gate's own (kept or superseded, so a
#     rerun of an older run counts) is still queued/in_progress/waiting/requested/pending
#     => pending (even if every name already has a passing job: a later producer of the same
#     name may still fail), and failure once the oldest kept or active run is older than the
#     timeout. Job verdicts still come only from the kept runs' latest-attempt jobs.
#  c. Else nothing is active: a required name with no job => failure ("never reported");
#     a required name with a job that never completed => failure; otherwise success.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)

fail() { # <description> — print a failure verdict and stop
  local d=$1
  ((${#d} > 140)) && d="${d:0:139}…"
  printf 'state=failure\ndescription=%s\n' "$d"
  exit 1
}

profile='' repository='' jobs='' wruns='' gate='' context='' now='' timeout='' summary=''
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail 'ci-gate: usage error (option without a value)'
  case $1 in
    --profile) profile=$2 ;; --repository) repository=$2 ;; --jobs) jobs=$2 ;;
    --workflow-runs) wruns=$2 ;; --gate-name) gate=$2 ;; --context) context=$2 ;;
    --now) now=$2 ;; --timeout-minutes) timeout=$2 ;; --summary) summary=$2 ;;
    *) fail 'ci-gate: usage error (unknown option)' ;;
  esac
  shift 2
done
command -v jq >/dev/null || fail 'ci-gate: jq is unavailable'
for v in profile repository jobs wruns gate context now timeout; do
  [[ -n ${!v} ]] || fail "ci-gate: usage error (missing --$v)"
done
[[ $now =~ ^[0-9]+$ && $timeout =~ ^[1-9][0-9]*$ ]] || fail 'ci-gate: usage error (now/timeout must be integers)'
[[ -f $profile && -f $jobs && -f $wruns ]] || fail 'ci-gate: an input file is missing'
bash "$ROOT/scripts/validate-ci-gate-profile.sh" "$profile" "$repository" "$context" >/dev/null 2>&1 \
  || fail 'ci-gate: profile missing, malformed, for another repository, or names the gate itself'
jq -e 'type == "array"' "$jobs" >/dev/null 2>&1 || fail 'ci-gate: jobs are not a JSON array'
jq -e 'type == "array"' "$wruns" >/dev/null 2>&1 || fail 'ci-gate: workflow runs are not a JSON array'

keptf=$(mktemp) || fail 'ci-gate: cannot create a temporary file'
trap 'rm -f "$keptf"' EXIT
# A file, not an argument: real workflow runs are large and would overflow the argument list.
jq --arg gate "$gate" -f "$ROOT/profiles/ci-gate/select-runs.jq" "$wruns" > "$keptf" 2>/dev/null \
  || fail 'ci-gate: workflow runs are malformed'

result=$(jq -n --slurpfile profile "$profile" --slurpfile jb "$jobs" --slurpfile keptw "$keptf" --slurpfile wr "$wruns" --arg gate "$gate" \
  --argjson now "$now" --argjson timeout "$timeout" '
  def active: ["queued", "in_progress", "waiting", "requested", "pending"];
  def names($a): $a | join(", ");
  $profile[0].checks as $req |
  $keptw[0] as $kept |
  # An entry is {job, workflow}: its jobs are those named `job` in the kept runs whose path is `workflow`.
  # GitHub may report a run path as `.github/workflows/build.yml@main`: a `@<ref>` after the .yml/.yaml
  # file name is stripped from the RUN side only (profile entries are validated to carry none).
  ($req | map(. as $e |
     ([$kept[] | select(((.path // "") | sub("(?<f>\\.ya?ml)@.*$"; "\(.f)")) == $e.workflow) | .id]) as $ids |
     {name: (($e.workflow | sub("^.*/"; "")) + ":" + $e.job),
      jobs: [$jb[0][] | select(.name == $e.job and (.run.id as $r | $ids | index($r) != null))]} | . + {
     bad: [.jobs[] | select(.status == "completed" and .conclusion != "success") | (.conclusion // "no conclusion")],
     open: [.jobs[] | select(.status != "completed")]
   })) as $rows |
  ($rows | map(select(.bad | length > 0))) as $failed |
  ($rows | map(select(.jobs | length == 0)) | map(.name)) as $missing |
  ($rows | map(select(.open | length > 0)) | map(.name)) as $unfinished |
  [$wr[0][] | select(.name != $gate) | select(.status as $s | active | index($s))] as $running |
  ($running | map(.name) | unique) as $runningNames |
  (($kept + $running) as $clock | if ($clock | length) > 0 then (($clock | map(.created_at | fromdateiso8601) | min) as $oldest | (($now - $oldest) / 60 | floor)) else null end) as $age |
  (if ($failed | length) > 0 then
     {state: "failure", description: ("failed: " + ($failed | map(.name + " (" + (.bad | unique | join("/")) + ")") | join(", ")))}
   elif ($running | length) > 0 and $age != null and $age < $timeout then
     {state: "pending", description: ("waiting for " + ($running | length | tostring) + " workflow runs: " + names($runningNames))}
   elif ($running | length) > 0 then
     {state: "failure", description: ("timed out after " + ($timeout | tostring) + " min: " + names($runningNames))}
   elif ($missing | length) > 0 then
     {state: "failure", description: ("never reported: " + names($missing))}
   elif ($unfinished | length) > 0 then
     {state: "failure", description: ("never completed: " + names($unfinished))}
   else
     {state: "success", description: ("all " + ($req | length | tostring) + " required checks passed")}
   end) as $v |
  ($v | .description |= (if length > 140 then .[0:139] + "…" else . end)) + {summary: (
    "## " + $v.state + "\n\n" + $v.description + "\n\n| required check | jobs (workflow run: status/conclusion) |\n|---|---|\n" +
    ($rows | map("| " + .name + " | " +
      (if (.jobs | length) == 0 then "never reported"
       else (.jobs | map((.run.name // "?") + ": " + (.status) + "/" + (.conclusion // "-")) | join(", ")) end) + " |") | join("\n")) +
    "\n\nWorkflow runs read: " + ($kept | length | tostring) + ", still active: " + ($running | length | tostring) +
    (if $age != null then "; oldest is " + ($age | tostring) + " min old (timeout " + ($timeout | tostring) + ")." else "." end) +
    "\n\nOnly GitHub Actions jobs of the latest attempt are counted; every job of a required identity (workflow file and job name) must succeed; skipped and neutral are not passes. Third-party checks are out of scope.\n")}
' 2>/dev/null) || fail 'ci-gate: verdict evaluation failed on malformed job or workflow run data'

state=$(jq -r .state <<<"$result") || fail 'ci-gate: verdict evaluation failed'
desc=$(jq -r .description <<<"$result") || fail 'ci-gate: verdict evaluation failed'
[[ -z $summary ]] || jq -r .summary <<<"$result" > "$summary" || fail 'ci-gate: cannot write the summary'
printf 'state=%s\ndescription=%s\n' "$state" "$desc"
case $state in success) exit 0 ;; pending) exit 3 ;; *) exit 1 ;; esac
