#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Offline controls for the interim CI/gate: the pure verdict, the profile validator, the
# shipped profiles, and static guards on the reusable workflow and the caller template.
#
# A gate that only ever goes green proves nothing, so every negative asserts the EXACT
# state and exit code, and the positive control (all present and successful) is what
# makes them meaningful. The headline negative: a required check that NEVER REPORTED,
# with nothing else running, must be a failure, not a pass and not a pending.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$ROOT/tests/fixtures/ci-gate"
VERDICT="$ROOT/scripts/ci-gate-verdict.sh"
VALIDATE="$ROOT/scripts/validate-ci-gate-profile.sh"
WORKFLOW="$ROOT/.github/workflows/ci-gate.yml"
TEMPLATE="$ROOT/templates/ci-gate-caller.yml"
PASS=0; FAIL=0
dlen() { printf "%s" "$1" | jq -Rr length; }
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CR="$WORK/cr.json"; WR="$WORK/wr.json"; PROFILE="$FX/profile.json"
T0=$(date -u -d '2026-11-17T10:00:00Z' +%s)   # the oldest workflow run in the fixtures
NOW=$((T0 + 30 * 60))                          # 30 min later: inside the 180 min timeout
cp "$FX/check-runs.json" "$CR"; cp "$FX/workflow-runs.json" "$WR"

verdict() { # [extra args...]; fills RC, STATE, DESC from the files $CR / $WR / $PROFILE
  OUT=$(bash "$VERDICT" --profile "$PROFILE" --repository example/repo --check-runs "$CR" \
        --workflow-runs "$WR" --gate-name 'CI gate' --context 'CI/gate' --now "$NOW" \
        --timeout-minutes 180 "$@" 2>/dev/null)
  RC=$?
  STATE=$(sed -n 's/^state=//p' <<<"$OUT"); DESC=$(sed -n 's/^description=//p' <<<"$OUT")
}
expect() { # <label> <state> <exit> [description-substring]
  verdict
  if [ "$STATE" = "$2" ] && [ "$RC" -eq "$3" ]; then ok "$1: state=$2 exit=$3"
  else bad "$1: got state='$STATE' exit=$RC, expected state=$2 exit=$3 ($DESC)"; fi
  if [ -n "${4:-}" ]; then
    case "$DESC" in *"$4"*) ok "$1: description names '$4'" ;; *) bad "$1: description '$DESC' lacks '$4'" ;; esac
  fi
  n=$(dlen "$DESC"); [ "$n" -le 140 ] && ok "$1: description <= 140 chars ($n)" || bad "$1: description is $n chars"
}
mut_cr() { jq "$1" "$FX/check-runs.json" > "$CR"; }   # mutate the check runs
mut_wr() { jq "$1" "$FX/workflow-runs.json" > "$WR"; }
reset() { cp "$FX/check-runs.json" "$CR"; cp "$FX/workflow-runs.json" "$WR"; }

echo "== positive control =="
reset; expect "all present and successful" success 0 "all 3 required checks passed"
verdict --summary "$WORK/summary.md"
{ [ -s "$WORK/summary.md" ] && grep -q '^| Build |' "$WORK/summary.md"; } && ok "summary file lists each required check" || bad "summary file missing or empty"
reset; mut_cr '[.[] | select(.name != "Advisory scan")]'
expect "an unrequired check absent is irrelevant" success 0
reset; mut_cr '. + [{id:2001,name:"Advisory scan",status:"completed",conclusion:"failure",app:{slug:"github-actions"},check_suite:{id:13}}]'
expect "an unrequired check failing is irrelevant" success 0

echo "== headline negative: a required check never reported =="
reset; mut_cr '[.[] | select(.name != "Lint")]'
mut_wr '[.[] | select(.name != "CI gate")]'
expect "Lint missing, nothing else active" failure 1 "never reported: Lint"
reset; mut_cr '[.[] | select(.name != "Lint")]'
expect "Lint missing, only the gate's own run active" failure 1 "never reported: Lint"
reset; mut_cr '[]'; mut_wr '[]'
expect "no runs at all" failure 1 "never reported"

echo "== missing while another workflow is still running =="
reset; mut_cr '[.[] | select(.name != "Lint")]'
mut_wr '. + [{id:15,name:"Slow proofs",status:"in_progress",conclusion:null,created_at:"2026-11-17T10:00:10Z"}]'
expect "missing, other workflow in progress, inside timeout" pending 3 "waiting for: Lint"
for s in queued waiting requested pending; do
  mut_wr ". + [{id:15,name:\"Slow\",status:\"$s\",conclusion:null,created_at:\"2026-11-17T10:00:10Z\"}]"
  expect "missing, other workflow $s, inside timeout" pending 3
done
mut_wr '. + [{id:15,name:"Slow proofs",status:"in_progress",conclusion:null,created_at:"2026-11-17T10:00:10Z"}]'
NOW_SAVED=$NOW; NOW=$((T0 + 181 * 60))
expect "missing, other workflow in progress, older than the timeout" failure 1 "timed out after 180 min: Lint"
NOW=$((T0 + 179 * 60)); expect "one minute inside the timeout" pending 3
NOW=$((T0 + 180 * 60)); expect "exactly at the timeout" failure 1 "timed out"
NOW=$NOW_SAVED
reset; mut_cr 'map(if .name == "Test" then .status = "in_progress" | .conclusion = null else . end)'
mut_wr '. + [{id:15,name:"CI quality 2",status:"in_progress",conclusion:null,created_at:"2026-11-17T10:00:10Z"}]'
expect "required check still running, workflow active" pending 3 "waiting for: Test"
mut_wr '[.[] | select(.name != "CI gate")]'
expect "required check 'in progress' but no workflow run is active" failure 1 "never reported: Test"

echo "== a required check that did not succeed =="
for c in failure cancelled skipped neutral timed_out action_required stale startup_failure; do
  reset; mut_cr "map(if .name == \"Test\" then .conclusion = \"$c\" else . end)"
  expect "Test concluded $c" failure 1 "Test ($c)"
done
reset; mut_cr 'map(if .name == "Test" then .conclusion = null else . end)'
expect "completed with no conclusion" failure 1 "Test"
reset; mut_cr 'map(if .name == "Test" then .conclusion = "failure" else . end)'
mut_wr '. + [{id:15,name:"Slow",status:"in_progress",conclusion:null,created_at:"2026-11-17T10:00:10Z"}]'
expect "a failure is final even while other workflows run" failure 1 "Test (failure)"

echo "== one name produced by several workflows =="
reset; mut_cr '. + [{id:2001,name:"Build",status:"completed",conclusion:"success",app:{slug:"github-actions"},check_suite:{id:21}}]'
expect "duplicated name, both suites passed" success 0
mut_cr '. + [{id:2001,name:"Build",status:"completed",conclusion:"failure",app:{slug:"github-actions"},check_suite:{id:21}}]'
expect "duplicated name, one suite passed and one failed" failure 1 "Build (failure)"
mut_cr '. + [{id:2001,name:"Build",status:"completed",conclusion:"skipped",app:{slug:"github-actions"},check_suite:{id:21}}]'
expect "duplicated name, one suite skipped" failure 1 "Build (skipped)"

echo "== reruns =="
reset; mut_cr 'map(if .name == "Test" then .id = 3002 else . end) | . + [{id:3001,name:"Test",status:"completed",conclusion:"failure",app:{slug:"github-actions"},check_suite:{id:12}}]'
expect "older failed run plus newer success in one suite" success 0
reset; mut_cr 'map(if .name == "Test" then .id = 3001 else . end) | . + [{id:3002,name:"Test",status:"completed",conclusion:"failure",app:{slug:"github-actions"},check_suite:{id:12}}]'
expect "older success plus newer failure in one suite" failure 1 "Test (failure)"

echo "== other apps cannot satisfy or fail a required name =="
reset; mut_cr 'map(if .name == "Lint" then .app.slug = "sonarqubecloud" else . end)'
mut_wr '[.[] | select(.name != "CI gate")]'
expect "same name, success, from another app; Actions one missing" failure 1 "never reported: Lint"
mut_cr 'map(if .name == "Lint" then .app.slug = "sonarqubecloud" else . end) + [{id:2001,name:"Lint",status:"completed",conclusion:"failure",app:{slug:"coderabbitai"},check_suite:{id:99}}]'
expect "another app's failing check with the same name" failure 1 "never reported: Lint"
reset; mut_cr '. + [{id:2001,name:"Lint",status:"completed",conclusion:"failure",app:{slug:"coderabbitai"},check_suite:{id:99}}]'
expect "another app's failure does not fail an Actions success" success 0
reset; mut_cr 'map(del(.app))'
mut_wr '[.[] | select(.name != "CI gate")]'
expect "check runs with no app at all count for nothing" failure 1 "never reported"

echo "== malformed inputs fail closed =="
reset; echo '{"check_runs":[]}' > "$CR"
expect "check runs not an array" failure 1
reset; echo 'not json' > "$WR"
expect "workflow runs not JSON" failure 1
reset; mut_cr '[.[] | {name, status}]'
expect "check runs with no ids or suites (names present, runs unusable)" failure 1
reset; rm -f "$CR"; expect "missing check-runs file" failure 1; cp "$FX/check-runs.json" "$CR"
OUT=$(bash "$VERDICT" --profile "$PROFILE" 2>/dev/null); RC=$?
{ [ $RC -eq 1 ] && grep -q '^state=failure$' <<<"$OUT"; } && ok "missing options: state=failure exit=1" || bad "missing options: rc=$RC"
OUT=$(bash "$VERDICT" --bogus x 2>/dev/null); RC=$?
{ [ $RC -eq 1 ] && grep -q '^state=failure$' <<<"$OUT"; } && ok "unknown option: state=failure exit=1" || bad "unknown option: rc=$RC"
reset; printf '{"checks":[],"repository":"example/repo","schema_version":1}\n' > "$WORK/empty.json"
PROFILE="$WORK/empty.json"; expect "empty profile list never passes" failure 1
printf '{"checks":["Build","CI/gate"],"repository":"example/repo","schema_version":1}\n' > "$WORK/self.json"
PROFILE="$WORK/self.json"; expect "profile naming the gate's own context" failure 1
printf '{"checks":["Build"],"repository":"other/repo","schema_version":1}\n' > "$WORK/other.json"
PROFILE="$WORK/other.json"; expect "profile for another repository" failure 1
PROFILE="$WORK/does-not-exist.json"; expect "missing profile" failure 1
PROFILE="$FX/profile.json"

echo "== description length =="
reset; jq -n '[range(0;60) | {id:(5000+.),name:("A long required check name number \(.)"),status:"completed",conclusion:"failure",app:{slug:"github-actions"},check_suite:{id:(70+.)}}]' > "$CR"
jq -n '{checks:[range(0;60) | "A long required check name number \(.)"],repository:"example/repo",schema_version:1}' > "$WORK/long.json"
PROFILE="$WORK/long.json"; verdict
n=$(dlen "$DESC")
{ [ "$STATE" = failure ] && [ "$n" -eq 140 ] && [[ $DESC == *… ]]; } \
  && ok "long failure description is cut to $n chars with an ellipsis" || bad "long description: $n chars '$DESC'"
PROFILE="$FX/profile.json"

echo "== profile validator =="
v_ok()  { bash "$VALIDATE" "$1" "${2:-example/repo}" >/dev/null 2>&1 && ok "accepted $3" || bad "rejected $3"; }
v_bad() { bash "$VALIDATE" "$1" "${2:-example/repo}" >/dev/null 2>&1 && bad "accepted $3" || ok "rejected $3"; }
v_ok "$FX/profile.json" example/repo "a well-formed profile"
w() { printf '%s\n' "$1" > "$WORK/p.json"; }
w '{"checks":["A","B"],"repository":"example/repo","schema_version":1}'; v_ok "$WORK/p.json" example/repo "two checks"
w 'not json'; v_bad "$WORK/p.json" example/repo "malformed JSON"
w '[]'; v_bad "$WORK/p.json" example/repo "a top-level array"
w '{"checks":["A"],"repository":"example/repo","schema_version":1}{"checks":["A"],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "two documents"
w '{"checks":["A"],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" other/repo "a profile for the wrong repository"
w '{"checks":[],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "an empty list"
w '{"checks":["A","CI/gate"],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "a list containing CI/gate"
w '{"checks":["A","estate-gate"],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "a list containing estate-gate"
w '{"checks":["A","my/context"],"repository":"example/repo","schema_version":1}'
bash "$VALIDATE" "$WORK/p.json" example/repo my/context >/dev/null 2>&1 && bad "accepted the caller's own context" || ok "rejected the context the caller publishes"
w '{"checks":["A","A"],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "duplicate check names"
w '{"checks":["A",""],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "an empty check name"
w '{"checks":["A"," B"],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "a check name with leading space"
w '{"checks":["A",1],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "a non-string check"
w '{"checks":["A\u0007"],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "a control character in a check name"
w '{"checks":["A"],"repository":"example/repo","schema_version":2}'; v_bad "$WORK/p.json" example/repo "schema_version 2"
w '{"checks":["A"],"repository":"example/repo"}'; v_bad "$WORK/p.json" example/repo "a missing member"
w '{"checks":["A"],"repository":"example/repo","schema_version":1,"extra":1}'; v_bad "$WORK/p.json" example/repo "an unknown member"
w '{"checks":["A"],"checks":["B"],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "a duplicate checks member"
w '{"checks":["A"],"repository":"example/repo","schema_version":1,"schema_version":1}'; v_bad "$WORK/p.json" example/repo "a duplicate schema_version member"
w '{"checks":["A"],"repository":"example/repo","repository":"other/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "a duplicate member spelled with an escape"
v_bad "$WORK/absent.json" example/repo "an absent file"

echo "== shipped profiles =="
shopt -s nullglob
n=0
for f in "$ROOT"/profiles/ci-gate/*/*.json; do
  repo="$(basename "$(dirname "$f")")/$(basename "$f" .json)"
  v_ok "$f" "$repo" "shipped profile $repo"
  # I-JSON / JCS: sorted keys, compact, one line. (Strings here are plain ASCII/BMP text.)
  [ "$(jq -cS . "$f")" = "$(cat "$f")" ] && ok "$repo: JCS-serialised (sorted, compact)" || bad "$repo: not in JCS form"
  jq -e '.checks | all(.[]; . != "CI/gate" and . != "estate-gate")' "$f" >/dev/null \
    && ok "$repo: no gate context in the list" || bad "$repo: lists a gate context"
  n=$((n+1))
done
[ "$n" -ge 3 ] && ok "$n shipped profiles found" || bad "expected at least 3 shipped profiles, found $n"
for repo in resource-algebra; do
  p="$ROOT/profiles/ci-gate/hyperpolymath/$repo.json"
  for need in 'Core proofs and expected rejections' 'Rocq recheck leg' 'Lean recheck leg' 'estate-rules' 'Estate Governance Policy'; do
    jq -e --arg n "$need" '.checks | index($n) != null' "$p" >/dev/null && ok "$repo requires '$need'" || bad "$repo does not require '$need'"
  done
done

echo "== static guards =="
[ -f "$WORKFLOW" ] && ok "ci-gate.yml exists" || bad "ci-gate.yml is missing"
[ -f "$TEMPLATE" ] && ok "ci-gate-caller.yml exists" || bad "ci-gate-caller.yml is missing"
# No ${{ }} expression inside any run: script (script-injection guard). Values arrive via env:.
run_expressions() { # <file> -> prints offending lines (inline run: values and block scalars)
  awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    {
      line = $0
      if (inblock) {
        if (line ~ /^[[:space:]]*$/ || ind(line) > keycol) { if (line ~ /\$\{\{/) print NR ": " line; next }
        inblock = 0
      }
      if (line ~ /^[[:space:]]*(- )?run:/) {
        keycol = ind(line) + (line ~ /^[[:space:]]*- / ? 2 : 0)
        rest = line; sub(/^[[:space:]]*(- )?run:[[:space:]]*/, "", rest)
        if (rest ~ /^[|>]/) { inblock = 1 } else if (rest ~ /\$\{\{/) { print NR ": " line }
      }
    }
  ' "$1"
}
[ -z "$(run_expressions "$WORKFLOW")" ] && ok "ci-gate.yml has no \${{ }} inside a run: script" || { bad "ci-gate.yml interpolates into a run: script"; run_expressions "$WORKFLOW"; }
[ -n "$(run_expressions "$FX/bad-run-script.yml")" ] && ok "control: the static check sees an expression in a run: script" || bad "control: the static check missed a planted expression"
grep -qE '^[[:space:]]+run:' "$WORKFLOW" && ok "ci-gate.yml has run: steps (the check had something to scan)" || bad "ci-gate.yml has no run: steps"
grep -qE '^  workflow_call:' "$WORKFLOW" && ! grep -qE '^  (push|pull_request|pull_request_target|workflow_run|schedule):' "$WORKFLOW" \
  && ok "ci-gate.yml is workflow_call only" || bad "ci-gate.yml has triggers other than workflow_call"
! grep -qE '^[[:space:]]*(- )?uses:' "$WORKFLOW" && ok "ci-gate.yml uses no actions (nothing from the consumer or PR is checked out or run)" || bad "ci-gate.yml has a uses: line"
! grep -qE '^[[:space:]]*secrets:' "$WORKFLOW" "$TEMPLATE" && ok "no secrets: line in the reusable or the template" || bad "a secrets: line is present"
grep -q "event_name" "$WORKFLOW" && grep -q "workflow_run" "$WORKFLOW" && ok "ci-gate.yml refuses events other than workflow_run" || bad "ci-gate.yml does not check the event"
grep -qE '^  gate:' "$WORKFLOW" && ok "job id is gate" || bad "job id is not gate"
grep -qE 'default: *"?CI/gate"?' "$WORKFLOW" && ok "context input defaults to CI/gate" || bad "context default is not CI/gate"
grep -qE 'default: *180' "$WORKFLOW" && ok "timeout_minutes defaults to 180" || bad "timeout_minutes default is not 180"
# Template: workflow_run only, never pull_request (a PR must not be able to run or edit the gate).
tpl_code() { grep -vE '^[[:space:]]*#' "$1"; }
tpl_code "$TEMPLATE" | grep -q 'pull_request' && bad "template mentions pull_request outside comments" || ok "template has no pull_request trigger"
tpl_code "$FX/bad-template.yml" | grep -q 'pull_request' && ok "control: the template check sees a pull_request trigger" || bad "control: the template check missed pull_request"
tpl_code "$TEMPLATE" | grep -qE '^  workflow_run:' && ok "template triggers on workflow_run" || bad "template does not trigger on workflow_run"
tpl_code "$TEMPLATE" | grep -qE 'uses: hyperpolymath/proven-cicd-and-workflows/\.github/workflows/ci-gate\.yml@__CICD_SUITE_SHA__' \
  && ok "template calls the reusable at the __CICD_SUITE_SHA__ placeholder" || bad "template does not call the reusable at the placeholder"
tpl_code "$TEMPLATE" | grep -qE '^  gate:' && ok "template job id is gate" || bad "template job id is not gate"
tpl_code "$TEMPLATE" | grep -qE 'context: *"CI/gate"' && ok "template publishes CI/gate" || bad "template does not publish CI/gate"

echo
printf 'ci-gate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
