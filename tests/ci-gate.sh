#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Offline controls for the interim CI/gate: the pure verdict, the profile validator, the
# shipped profiles, and static guards on the reusable workflow and the caller template.
#
# A gate that only ever goes green proves nothing, so every negative asserts the EXACT
# state and exit code, and the positive control (all present and successful) is what
# makes them meaningful. The headline negative: a required name with NO JOB,
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
JB="$WORK/jobs.json"; WR="$WORK/wr.json"; PROFILE="$FX/profile.json"
T0=$(date -u -d '2026-11-17T10:00:00Z' +%s)   # the oldest workflow run in the fixtures
NOW=$((T0 + 30 * 60))                          # 30 min later: inside the 180 min timeout
cp "$FX/jobs.json" "$JB"; cp "$FX/workflow-runs.json" "$WR"

verdict() { # [extra args...]; fills RC, STATE, DESC from the files $JB / $WR / $PROFILE
  OUT=$(bash "$VERDICT" --profile "$PROFILE" --repository example/repo --jobs "$JB" \
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
mut_wr() { jq "$1" "$FX/workflow-runs.json" > "$WR"; }
# jq prelude for building jobs and runs inline: j(id;name;run id;run name;status;conclusion),
# r(id;name;workflow_id;event;status;created_at)
DEFS='def j($id;$n;$r;$s;$c): {id:$id,name:$n,status:$s,conclusion:$c,run:{id:$r,name:("run "+($r|tostring)),status:"completed"}};
def r($id;$n;$w;$e;$s;$t): {id:$id,name:$n,workflow_id:$w,event:$e,run_attempt:1,status:$s,conclusion:null,created_at:$t,path:(".github/workflows/" + ($n | ascii_downcase | gsub(" "; "-")) + ".yml")};'
mut_jb() { jq "$DEFS $1" "$FX/jobs.json" > "$JB"; }   # mutate the jobs
mut_wr() { jq "$DEFS $1" "$FX/workflow-runs.json" > "$WR"; }
reset() { cp "$FX/jobs.json" "$JB"; cp "$FX/workflow-runs.json" "$WR"; }
SLOW='. + [r(15;"Slow proofs";5;"pull_request";"in_progress";"2026-11-17T10:00:10Z")]'

echo "== positive control (the gate's own run is in progress and is ignored) =="
reset; expect "all present and successful" success 0 "all 3 required checks passed"
verdict --summary "$WORK/summary.md"
{ [ -s "$WORK/summary.md" ] && grep -q '^| ci-build.yml:Build |' "$WORK/summary.md"; } && ok "summary file lists each required check" || bad "summary file missing or empty"
reset; mut_jb '[.[] | select(.name != "Advisory scan")]'
expect "an unrequired job absent is irrelevant" success 0
reset; mut_jb '. + [j(2001;"Advisory scan";13;"completed";"failure")]'
expect "an unrequired job failing is irrelevant" success 0
reset; mut_wr '[.[] | select(.name != "CI gate")]'
expect "no gate run at all" success 0
reset; mut_wr 'map(if .name == "CI gate" then .status = "queued" else . end)'
expect "the gate's own run is ignored while queued" success 0

echo "== headline negative: a required name with no job and nothing active =="
reset; mut_jb '[.[] | select(.name != "Lint")]'
expect "Lint has no job, nothing else active" failure 1 "never reported: ci-quality.yml:Lint"
mut_wr '[.[] | select(.name != "CI gate")]'
expect "Lint has no job, no gate run either" failure 1 "never reported: ci-quality.yml:Lint"
reset; mut_jb '[]'; mut_wr '[]'
expect "no jobs and no runs at all" failure 1 "never reported"

echo "== something still active: pending, then timeout =="
reset; mut_wr "$SLOW"
expect "all required success but an unrelated run is active" pending 3 "waiting for 1 workflow runs: Slow proofs"
for s in queued waiting requested pending; do
  mut_wr ". + [r(15;\"Slow\";5;\"pull_request\";\"$s\";\"2026-11-17T10:00:10Z\")]"
  expect "all required success, unrelated run $s" pending 3
done
mut_wr "$SLOW"
NOW_SAVED=$NOW; NOW=$((T0 + 181 * 60))
expect "all required success, unrelated run active past the timeout" failure 1 "timed out after 180 min: Slow proofs"
NOW=$((T0 + 179 * 60)); expect "one minute inside the timeout" pending 3
NOW=$((T0 + 180 * 60)); expect "exactly at the timeout" failure 1 "timed out"
NOW=$NOW_SAVED
reset; mut_jb '[.[] | select(.name != "Lint")]'; mut_wr "$SLOW"
expect "Lint has no job yet, another run is active" pending 3 "waiting for 1 workflow runs"
reset; mut_jb 'map(if .name == "Test" then .status = "in_progress" | .conclusion = null else . end)'
mut_wr 'map(if .id == 12 then .status = "in_progress" else . end)'
expect "required job in progress, its run active" pending 3 "waiting for 1 workflow runs: CI quality"
mut_wr '.'
expect "required job in progress but no run is active" failure 1 "never completed: ci-quality.yml:Test"
reset; mut_wr '. + [r(15;"Slow";5;"pull_request";"completed";"2026-11-17T10:00:10Z")]'
expect "an unrelated run that completed is not waited for" success 0

echo "-- a rerun after a full pass: the in_progress event must replace success with pending --"
reset; expect "before the rerun: everything passed" success 0
mut_jb 'map(if .name == "Test" then .status = "in_progress" | .conclusion = null else . end)'
mut_wr 'map(if .id == 12 then .status = "in_progress" | .run_attempt = 2 else . end)'
expect "same Test job, run 12 in_progress again (attempt 2)" pending 3 "waiting for 1 workflow runs: CI quality"
mut_jb 'map(select(.name != "Test" and .name != "Lint"))'
expect "rerun just started, its jobs not listed yet" pending 3 "waiting for 1 workflow runs: CI quality"

echo "== a required job that did not succeed is failure at once =="
for c in failure cancelled skipped neutral timed_out action_required stale startup_failure; do
  reset; mut_jb "map(if .name == \"Test\" then .conclusion = \"$c\" else . end)"
  expect "Test concluded $c" failure 1 "Test ($c)"
done
reset; mut_jb 'map(if .name == "Test" then .conclusion = null else . end)'
expect "completed with no conclusion" failure 1 "Test"
reset; mut_jb 'map(if .name == "Test" then .conclusion = "failure" else . end)'; mut_wr "$SLOW"
expect "a failure is final even while other workflows run" failure 1 "Test (failure)"

echo "== one name, several producers: every job of that name is required =="
jq -c '.checks += [{job:"Build",workflow:".github/workflows/other-build.yml"}] | .checks |= sort_by([.workflow,.job])' "$FX/profile.json" > "$WORK/two.json"
PROFILE="$WORK/two.json"
reset; expect "second producer's workflow never ran, first succeeded, nothing active" failure 1 "never reported: other-build.yml:Build"
mut_wr '. + [r(21;"Other build";6;"pull_request";"completed";"2026-11-17T10:00:09Z")]'
expect "second producer ran but has no job of that name, nothing active" failure 1 "never reported: other-build.yml:Build"
mut_wr 'map(select(.name != "CI gate")) | . + [r(21;"Other build";6;"pull_request";"queued";"2026-11-17T10:00:09Z")]'
expect "second producer queued, no job yet" pending 3 "waiting for 1 workflow runs: Other build"
reset; mut_jb '. + [j(2001;"Build";22;"completed";"success")]'
mut_wr '. + [r(22;"Third build";7;"pull_request";"completed";"2026-11-17T10:00:09Z")]'
expect "same display name from a different workflow does not satisfy the second producer" failure 1 "never reported: other-build.yml:Build"
reset; mut_jb '. + [j(2001;"Build";21;"completed";"success")]'
mut_wr '. + [r(21;"Other build";6;"pull_request";"completed";"2026-11-17T10:00:09Z")]'
expect "two producers of Build, both success" success 0
mut_jb '. + [j(2001;"Build";21;"completed";"failure")]'
expect "two producers of Build, one failed" failure 1 "Build (failure)"
mut_jb '. + [j(2001;"Build";21;"completed";"skipped")]'
expect "two producers of Build, one skipped" failure 1 "Build (skipped)"
mut_jb '. + [{id:2001,name:"Build",status:"queued",conclusion:null,run:{id:21,name:"Other build",status:"queued"}}]'
mut_wr '. + [r(21;"Other build";6;"pull_request";"queued";"2026-11-17T10:00:09Z")]'
expect "two producers of Build, one success and one still queued" pending 3 "waiting for 1 workflow runs: Other build"
PROFILE="$FX/profile.json"
reset; mut_jb '. + [j(2001;"Build";11;"completed";"failure")]'
expect "two same-named jobs in ONE run, one failure and one success" failure 1 "Build (failure)"
reset; mut_jb '. + [j(2001;"Build";11;"completed";"success")]'
expect "two same-named jobs in ONE run, both success" success 0

echo "== which runs are read =="
reset; mut_jb '. + [j(2001;"Test";9;"completed";"failure")]'
mut_wr '. + [r(9;"CI quality";2;"pull_request";"completed";"2026-11-17T09:59:00Z")]'
expect "a failed job of an older run of the same workflow and event is superseded" success 0
reset; mut_wr '. + [r(9;"CI quality";2;"pull_request";"in_progress";"2026-11-17T09:59:00Z")]'
expect "an older superseded run of the same workflow and event is rerun (in_progress)" pending 3 "CI quality"
mut_wr '. + [r(9;"CI quality";2;"pull_request";"completed";"2026-11-17T09:59:00Z")]'
expect "that superseded run completes again: back to success" success 0
mut_jb '. + [j(2001;"Test";9;"completed";"failure")]'
expect "its jobs are still not read (superseded): success" success 0
reset; mut_wr '. + [r(19;"CI quality";2;"pull_request";"in_progress";"2026-11-17T10:10:00Z")]'
expect "a newer run of the same workflow and event is active" pending 3 "CI quality"
reset; mut_wr '. + [r(9;"CI quality";2;"push";"in_progress";"2026-11-17T09:59:00Z")]'
expect "same workflow, other event, active" pending 3
reset; mut_jb '. + [j(2001;"Test";99;"completed";"failure")]'
expect "a job tagged with a run that was not kept is not counted" success 0
echo "-- a second attempt: filter=latest returns only the second attempt's jobs --"
reset; mut_wr 'map(if .id == 12 then .run_attempt = 2 else . end)'
expect "run on its 2nd attempt, latest jobs succeed" success 0
mut_jb 'map(if .name == "Lint" then .conclusion = "failure" else . end)'
expect "run on its 2nd attempt, a latest job failed" failure 1 "Lint (failure)"

echo "== large real-world inputs =="
reset; mut_wr 'map(. + {pad: ("x" * 200000)})'
expect "workflow runs whose members exceed one argv string (200 KB each)" success 0

echo "== malformed inputs fail closed =="
reset; echo '{"jobs":[]}' > "$JB"
expect "jobs not an array" failure 1
reset; echo 'not json' > "$WR"
expect "workflow runs not JSON" failure 1
reset; mut_wr '[.[] | {name, status}]'
expect "workflow runs with no ids (unusable)" failure 1
reset; mut_wr 'map(.created_at = "yesterday")'
expect "workflow runs with an unparseable date" failure 1
reset; mut_jb '[.[] | {name, status}]'
expect "jobs with no run tag and no conclusion" failure 1
reset; rm -f "$JB"; expect "missing jobs file" failure 1; cp "$FX/jobs.json" "$JB"
OUT=$(bash "$VERDICT" --profile "$PROFILE" 2>/dev/null); RC=$?
{ [ $RC -eq 1 ] && grep -q '^state=failure$' <<<"$OUT"; } && ok "missing options: state=failure exit=1" || bad "missing options: rc=$RC"
OUT=$(bash "$VERDICT" --bogus x 2>/dev/null); RC=$?
{ [ $RC -eq 1 ] && grep -q '^state=failure$' <<<"$OUT"; } && ok "unknown option: state=failure exit=1" || bad "unknown option: rc=$RC"
reset; printf '{"checks":[],"repository":"example/repo","schema_version":2}\n' > "$WORK/empty.json"
PROFILE="$WORK/empty.json"; expect "empty profile list never passes" failure 1
printf '{"checks":[{"job":"Build","workflow":".github/workflows/ci-build.yml"},{"job":"CI/gate","workflow":".github/workflows/x.yml"}],"repository":"example/repo","schema_version":2}\n' > "$WORK/self.json"
PROFILE="$WORK/self.json"; expect "profile naming the gate's own context" failure 1
printf '{"checks":[{"job":"Build","workflow":".github/workflows/ci-build.yml"}],"repository":"other/repo","schema_version":2}\n' > "$WORK/other.json"
PROFILE="$WORK/other.json"; expect "profile for another repository" failure 1
PROFILE="$WORK/does-not-exist.json"; expect "missing profile" failure 1
PROFILE="$FX/profile.json"

echo "== description length =="
reset; jq -n '[range(0;60) | {id:(5000+.),name:("A long required check name number \(.)"),status:"completed",conclusion:"failure",run:{id:11,name:"CI build",status:"completed"}}]' > "$JB"
jq -n '{checks:[range(0;60) | {job:"A long required check name number \(.)",workflow:".github/workflows/ci-build.yml"}] | sort_by([.workflow,.job]),repository:"example/repo",schema_version:2}' > "$WORK/long.json"
PROFILE="$WORK/long.json"; verdict
n=$(dlen "$DESC")
{ [ "$STATE" = failure ] && [ "$n" -eq 140 ] && [[ $DESC == *… ]]; } \
  && ok "long failure description is cut to $n chars with an ellipsis" || bad "long description: $n chars '$DESC'"
PROFILE="$FX/profile.json"

echo "== publisher: stub gh, settle guard, status writes =="
PUBLISH="$ROOT/scripts/ci-gate-publish.sh"
SUITE_DIR="$WORK/suite"; FAKEGH="$WORK/stub"
mkdir -p "$SUITE_DIR/scripts" "$SUITE_DIR/profiles/ci-gate/example" "$FAKEGH/bin"
cp "$ROOT"/scripts/ci-gate-verdict.sh "$ROOT"/scripts/validate-ci-gate-profile.sh "$PUBLISH" "$SUITE_DIR/scripts/"
cp "$ROOT"/profiles/ci-gate/validate.jq "$ROOT"/profiles/ci-gate/select-runs.jq "$SUITE_DIR/profiles/ci-gate/"
cp "$FX/profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"
cat > "$FAKEGH/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub gh: canned runs (the Nth runs call returns runs.N.json, else the highest-numbered file),
# canned jobs, a POST log, and injected failures (fail.N = the Nth runs call errors; failjobs).
D=${STUB_DIR:?}
if [[ " $* " == *" -X POST "* ]]; then
  state=''; desc=''
  for a in "$@"; do case $a in state=*) state=${a#state=} ;; description=*) desc=${a#description=} ;; esac; done
  [[ ! -f $D/failpost ]] || { echo "gh: HTTP 500 (post)" >&2; exit 1; }
  printf '%s\t%s\n' "$state" "$desc" >> "$D/posts.log"; exit 0
fi
args="$*"
case $args in
  *"actions/runs?head_sha"*)
    n=$(( $(cat "$D/runs.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/runs.count"
    [[ ! -f $D/fail.$n ]] || { echo "gh: HTTP 500" >&2; exit 1; }
    f=$D/runs.$n.json; [[ -f $f ]] || f=$(ls "$D"/runs.*.json | sort -V | tail -1)
    jq -c '.[]' "$f" ;;
  *"/jobs?filter=latest"*)
    [[ ! -f $D/failjobs ]] || { echo "gh: HTTP 500 (jobs)" >&2; exit 1; }
    id=${args#*actions/runs/}; id=${id%%/*}
    jq -c --argjson id "$id" '.[] | select(.run.id == $id) | del(.run)' "$D/jobs.json" ;;
  *) echo "stub gh: unexpected call: $args" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$FAKEGH/bin/gh"
SHA=$(printf 'a%.0s' $(seq 40))
snap() { # <n> <jq filter over the fixture runs> -> runs.n.json
  jq -c "$2" "$FX/workflow-runs.json" > "$FAKEGH/runs.$1.json"
}
pubreset() { rm -f "$FAKEGH"/runs.*.json "$FAKEGH"/fail.* "$FAKEGH"/failjobs "$FAKEGH"/failpost "$FAKEGH/posts.log" "$FAKEGH/runs.count" "$WORK/gho"; cp "$FX/jobs.json" "$FAKEGH/jobs.json"; }
publish() { # [VAR=value ...] -> RC, NPOSTS, POSTS (state<TAB>description lines), CALLS (runs fetches)
  : > "$FAKEGH/posts.log"; rm -f "$FAKEGH/runs.count"; rm -rf "$WORK/pw"
  PUBOUT=$(env PATH="$FAKEGH/bin:$PATH" STUB_DIR="$FAKEGH" REPO=example/repo HEAD_SHA="$SHA" CONTEXT=CI/gate \
    TIMEOUT_MINUTES=180 GATE_NAME='CI gate' SUITE="$SUITE_DIR" WORK="$WORK/pw" CI_GATE_NOW="$NOW" \
    GITHUB_OUTPUT="$WORK/gho" GITHUB_STEP_SUMMARY="$WORK/gss" "$@" bash "$SUITE_DIR/scripts/ci-gate-publish.sh" 2>&1)
  RC=$?
  NPOSTS=$(grep -c . "$FAKEGH/posts.log"); POSTS=$(cat "$FAKEGH/posts.log"); CALLS=$(cat "$FAKEGH/runs.count" 2>/dev/null || echo 0)
}
post_n() { sed -n "${1}p" "$FAKEGH/posts.log"; }
chk() { # <label> <actual> <expected>
  [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', expected '$3'"
}
RERUN='map(if .id == 12 then .status = "in_progress" | .run_attempt = 2 else . end)'
DONE='.'

pubreset; snap 1 "$DONE"; publish EVENT_ACTION=completed
chk "completed event, everything passed: one POST" "$NPOSTS" 1
chk "completed event, everything passed: success" "$(post_n 1 | cut -f1)" success
chk "completed event: exit 0" "$RC" 0
chk "completed event: two run fetches (snapshot and guard)" "$CALLS" 2
grep -q '^published=true$' "$WORK/gho" && ok "completed event: published=true written" || bad "published=true not written"

pubreset; snap 1 "$RERUN"; publish EVENT_ACTION=in_progress RUN_NAME='CI quality'
chk "existing success, then an in_progress event: the FIRST POST is pending" "$(post_n 1 | cut -f1)" pending
chk "the first POST names the re-run" "$(post_n 1 | cut -f2)" "re-run started: CI quality"
chk "the final POST is pending too (the run is still active)" "$(post_n 2 | cut -f1)" pending
chk "in_progress event: two POSTs" "$NPOSTS" 2
chk "pending is a normal wait: exit 0" "$RC" 0

pubreset; snap 1 "$DONE"; publish EVENT_ACTION=in_progress RUN_NAME='CI quality'
chk "in_progress event on settled data: first POST pending" "$(post_n 1 | cut -f1)" pending
chk "in_progress event on settled data: final POST success" "$(post_n 2 | cut -f1)" success

echo "-- the runs change between evaluation and publish --"
pubreset; snap 1 "$RERUN"; snap 2 "$DONE"; snap 3 "$DONE"
publish EVENT_ACTION=completed
chk "fingerprint moved: one POST, not the stale pending" "$NPOSTS" 1
chk "fingerprint moved: the POST reflects the new data (success)" "$(post_n 1 | cut -f1)" success
chk "fingerprint moved: re-evaluated (4 run fetches)" "$CALLS" 4
pubreset; snap 1 "$DONE"; snap 2 "$RERUN"; snap 3 "$RERUN"
publish EVENT_ACTION=completed
chk "success evaluated, run started before the POST: no stale success" "$(post_n 1 | cut -f1)" pending
chk "success evaluated, run started before the POST: one POST" "$NPOSTS" 1
echo "-- an early-snapshot evaluator that finishes after the settle --"
pubreset; snap 1 "$RERUN"; snap 2 "$DONE"
publish EVENT_ACTION=in_progress RUN_NAME='CI quality'
chk "early evaluator: first POST pending (re-run started)" "$(post_n 1 | cut -f1)" pending
chk "early evaluator: its final POST is success, not the stale pending" "$(post_n 2 | cut -f1)" success
chk "early evaluator: exactly two POSTs" "$NPOSTS" 2
echo "-- the runs never stabilise --"
pubreset; for i in $(seq 1 14); do snap "$i" "map(.updated_at = \"t$i\")"; done
publish EVENT_ACTION=completed
chk "never stable: one POST" "$NPOSTS" 1
chk "never stable: pending" "$(post_n 1 | cut -f1)" pending
chk "never stable: 'runs still changing'" "$(post_n 1 | cut -f2)" "runs still changing"
chk "never stable: 5 rounds, two fetches each" "$CALLS" 10
chk "never stable: never success, exit 0" "$RC" 0
echo "-- a late evaluator cannot leave a stale failure either --"
pubreset; snap 1 "$DONE"; snap 2 "map(if .id == 11 then .status = \"in_progress\" else . end)"
jq 'map(if .name == "Test" then .conclusion = "failure" else . end)' "$FX/jobs.json" > "$FAKEGH/jobs.json"
snap 3 "$DONE"
publish EVENT_ACTION=completed
chk "stale failure not written when the runs moved; re-evaluated: failure on settled data" "$(post_n 1 | cut -f1)" failure
chk "failure verdict: exit 1" "$RC" 1
chk "failure verdict: names the job" "$(post_n 1 | cut -f2 | grep -c 'Test (failure)')" 1
echo "-- errors fail closed --"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/fail.1"; publish EVENT_ACTION=completed
chk "gh error on the first runs fetch: a failure POST" "$(post_n 1 | cut -f1)" failure
chk "gh error: exit 1, one POST" "$RC/$NPOSTS" "1/1"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/fail.2"; publish EVENT_ACTION=completed
chk "gh error on the guard fetch: a failure POST" "$(post_n 1 | cut -f1)" failure
pubreset; snap 1 "$DONE"; touch "$FAKEGH/failjobs"; publish EVENT_ACTION=completed
chk "gh error reading jobs: a failure POST" "$(post_n 1 | cut -f1)" failure
pubreset; snap 1 "$DONE"; touch "$FAKEGH/failpost"; publish EVENT_ACTION=completed
chk "the status POST itself fails: exit 1, no published=true" "$RC/$([ -s "$WORK/gho" ] && echo 1 || echo 0)" "1/0"
pubreset; snap 1 "$DONE"; rm -f "$SUITE_DIR/profiles/ci-gate/example/repo.json"; publish EVENT_ACTION=completed
chk "no profile: a failure POST, exit 1" "$(post_n 1 | cut -f1)/$RC" "failure/1"
cp "$FX/profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"
pubreset; snap 1 "$DONE"; publish EVENT_ACTION=completed HEAD_SHA=abc
chk "a head SHA that is not 40 hex: exit 1, no POST" "$RC/$NPOSTS" "1/0"
pubreset; snap 1 "$RERUN"; publish EVENT_ACTION=in_progress RUN_NAME="$(printf 'x%.0s' $(seq 200))"
chk "the re-run description is clipped to 140 characters" "$(dlen "$(post_n 1 | cut -f2)")" 140
pubreset

echo "== profile validator =="
v_ok()  { bash "$VALIDATE" "$1" "${2:-example/repo}" >/dev/null 2>&1 && ok "accepted $3" || bad "rejected $3"; }
v_bad() { bash "$VALIDATE" "$1" "${2:-example/repo}" >/dev/null 2>&1 && bad "accepted $3" || ok "rejected $3"; }
v_ok "$FX/profile.json" example/repo "a well-formed profile"
w() { printf '%s\n' "$1" > "$WORK/p.json"; }
# e JOB WORKFLOW-FILE -> one entry; the whole profile is  {"checks":[...],"repository":...,"schema_version":2}
e() { printf '{"job":"%s","workflow":".github/workflows/%s"}' "$1" "$2"; }
p() { printf '{"checks":[%s],"repository":"%s","schema_version":%s}' "$1" "${2:-example/repo}" "${3:-2}"; }
A=$(e A a.yml); B=$(e B b.yml)
w "$(p "$A,$B")"; v_ok "$WORK/p.json" example/repo "two entries"
w "$(p "$(e A a.yml),$(e A b.yml)")"; v_ok "$WORK/p.json" example/repo "one display name from two workflows (two producers)"
w "$(p "$(e A a.yaml)")"; v_ok "$WORK/p.json" example/repo "a .yaml workflow file"
w "$(p "$A" example/repo 1)"; v_bad "$WORK/p.json" example/repo "schema_version 1 (no silent fallback)"
w '{"checks":["A","B"],"repository":"example/repo","schema_version":1}'; v_bad "$WORK/p.json" example/repo "the old v1 shape (bare names)"
w '{"checks":["A","B"],"repository":"example/repo","schema_version":2}'; v_bad "$WORK/p.json" example/repo "schema_version 2 with bare-name entries"
w "$(p "$A" example/repo 3)"; v_bad "$WORK/p.json" example/repo "schema_version 3"
w 'not json'; v_bad "$WORK/p.json" example/repo "malformed JSON"
w '[]'; v_bad "$WORK/p.json" example/repo "a top-level array"
w "$(p "$A")$(p "$A")"; v_bad "$WORK/p.json" example/repo "two documents"
w "$(p "$A")"; v_bad "$WORK/p.json" other/repo "a profile for the wrong repository"
w "$(p "")"; v_bad "$WORK/p.json" example/repo "an empty list"
w "$(p "$(e A a.yml),$(e CI/gate b.yml)")"; v_bad "$WORK/p.json" example/repo "a list containing CI/gate"
w "$(p "$(e A a.yml),$(e estate-gate b.yml)")"; v_bad "$WORK/p.json" example/repo "a list containing estate-gate"
w "$(p "$(e A a.yml),$(e my/context b.yml)")"
bash "$VALIDATE" "$WORK/p.json" example/repo my/context >/dev/null 2>&1 && bad "accepted the caller's own context" || ok "rejected the context the caller publishes"
w "$(p "$A,$A")"; v_bad "$WORK/p.json" example/repo "a duplicate (job, workflow) pair"
w "$(p "$B,$A")"; v_bad "$WORK/p.json" example/repo "entries not sorted"
w "$(p "$(e A a.yml),$(e '' b.yml)")"; v_bad "$WORK/p.json" example/repo "an empty job name"
w "$(p "$(e A a.yml),$(e ' B' b.yml)")"; v_bad "$WORK/p.json" example/repo "a job name with leading space"
w "$(p "$(e A a.yml),$(e 'B ' b.yml)")"; v_bad "$WORK/p.json" example/repo "a job name with trailing space"
w "$(p '{"job":1,"workflow":".github/workflows/a.yml"}')"; v_bad "$WORK/p.json" example/repo "a non-string job"
w "$(p '{"job":"A\u0007","workflow":".github/workflows/a.yml"}')"; v_bad "$WORK/p.json" example/repo "a control character in a job name"
w "$(p '{"job":"A","workflow":"a.yml"}')"; v_bad "$WORK/p.json" example/repo "a workflow path outside .github/workflows"
w "$(p '{"job":"A","workflow":"/.github/workflows/a.yml"}')"; v_bad "$WORK/p.json" example/repo "an absolute workflow path"
w "$(p '{"job":"A","workflow":".github/workflows/../a.yml"}')"; v_bad "$WORK/p.json" example/repo "'..' in the workflow path"
w "$(p '{"job":"A","workflow":".github/workflows/../../etc/x.yml"}')"; v_bad "$WORK/p.json" example/repo "a traversal workflow path"
w "$(p '{"job":"A","workflow":".github/workflows/sub/a.yml"}')"; v_bad "$WORK/p.json" example/repo "a nested workflow path"
w "$(p '{"job":"A","workflow":".github/workflows/a.txt"}')"; v_bad "$WORK/p.json" example/repo "a workflow path that is not yml/yaml"
w "$(p '{"job":"A","workflow":".github/workflows/a.yml@main"}')"; v_bad "$WORK/p.json" example/repo "a workflow path with a ref suffix"
w "$(p '{"job":"A","workflow":5}')"; v_bad "$WORK/p.json" example/repo "a non-string workflow"
w "$(p '{"job":"A"}')"; v_bad "$WORK/p.json" example/repo "an entry with a missing member (workflow)"
w "$(p '{"workflow":".github/workflows/a.yml"}')"; v_bad "$WORK/p.json" example/repo "an entry with a missing member (job)"
w "$(p '{"job":"A","workflow":".github/workflows/a.yml","extra":1}')"; v_bad "$WORK/p.json" example/repo "an entry with an extra member"
w "$(p '{"job":"A","job":"B","workflow":".github/workflows/a.yml"}')"; v_bad "$WORK/p.json" example/repo "an entry with a duplicate member"
w '{"checks":[{"job":"A","workflow":".github/workflows/a.yml"}],"repository":"example/repo"}'; v_bad "$WORK/p.json" example/repo "a missing top-level member"
w "$(p "$A" | sed 's/}$/,"extra":1}/')"; v_bad "$WORK/p.json" example/repo "an unknown top-level member"
w "$(p "$A" | sed 's/^{/{"checks":[],/')"; v_bad "$WORK/p.json" example/repo "a duplicate checks member"
w "$(p "$A" | sed 's/}$/,"schema_version":2}/')"; v_bad "$WORK/p.json" example/repo "a duplicate schema_version member"
w "$(p "$A" | sed 's/}$/,"repository":"other\/repo"}/')"; v_bad "$WORK/p.json" example/repo "a duplicate repository member"
v_bad "$WORK/absent.json" example/repo "an absent file"

echo "== shipped profiles =="
shopt -s nullglob
n=0
for f in "$ROOT"/profiles/ci-gate/*/*.json; do
  repo="$(basename "$(dirname "$f")")/$(basename "$f" .json)"
  v_ok "$f" "$repo" "shipped profile $repo"
  # I-JSON / JCS: sorted keys, compact, one line. (Strings here are plain ASCII/BMP text.)
  [ "$(jq -cS . "$f")" = "$(cat "$f")" ] && ok "$repo: JCS-serialised (sorted, compact)" || bad "$repo: not in JCS form"
  jq -e '.checks | all(.[]; .job != "CI/gate" and .job != "estate-gate")' "$f" >/dev/null \
    && ok "$repo: no gate context in the list" || bad "$repo: lists a gate context"
  n=$((n+1))
done
[ "$n" -ge 3 ] && ok "$n shipped profiles found" || bad "expected at least 3 shipped profiles, found $n"
for repo in resource-algebra; do
  p="$ROOT/profiles/ci-gate/hyperpolymath/$repo.json"
  for need in 'Core proofs and expected rejections' 'Rocq recheck leg' 'Lean recheck leg' 'estate-rules' 'Estate Governance Policy'; do
    jq -e --arg n "$need" '.checks | any(.[]; .job == $n)' "$p" >/dev/null && ok "$repo requires '$need'" || bad "$repo does not require '$need'"
  done
done

for spec in "resource-algebra:Proofs verdict:proofs.yml" "mathesis:Proven suite verdict:proven-tests.yml"; do
  IFS=: read -r repo need wf <<<"$spec"
  jq -e --arg n "$need" --arg w ".github/workflows/$wf" '.checks | any(.[]; .job == $n and .workflow == $w)' "$ROOT/profiles/ci-gate/hyperpolymath/$repo.json" >/dev/null && ok "$repo requires the renamed aggregator '$need' from $wf" || bad "$repo does not require '$need' from $wf"
done
for f in "$ROOT"/profiles/ci-gate/*/*.json; do
  repo="$(basename "$(dirname "$f")")/$(basename "$f" .json)"
  jq -e '[.checks[] | select(.job == "🔴 GATE: Empty-linter (invisible characters)") | .workflow] | sort == [".github/workflows/dogfood-gate.yml", ".github/workflows/empty-linter.yml"]' "$f" >/dev/null && ok "$repo: both Empty-linter producers are required" || bad "$repo: Empty-linter producers are not both listed"
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
grep -q "fetch scripts/ci-gate-publish.sh" "$WORKFLOW" && ok "ci-gate.yml fetches the publisher from the suite" || bad "ci-gate.yml does not fetch ci-gate-publish.sh"
! grep -qE '^[[:space:]]*gh api -X POST' <(sed -n '/- name: Evaluate the commit/,/- name: Publish a failure/p' "$WORKFLOW") && ok "the evaluate step publishes only through the script" || bad "the evaluate step posts a status itself"
grep -qE '^  gate:' "$WORKFLOW" && ok "job id is gate" || bad "job id is not gate"
grep -qE 'default: *"?CI/gate"?' "$WORKFLOW" && ok "context input defaults to CI/gate" || bad "context default is not CI/gate"
grep -qE 'default: *180' "$WORKFLOW" && ok "timeout_minutes defaults to 180" || bad "timeout_minutes default is not 180"
# Template: workflow_run only, never pull_request (a PR must not be able to run or edit the gate).
tpl_code() { grep -vE '^[[:space:]]*#' "$1"; }
tpl_code "$TEMPLATE" | grep -q 'pull_request' && bad "template mentions pull_request outside comments" || ok "template has no pull_request trigger"
tpl_code "$FX/bad-template.yml" | grep -q 'pull_request' && ok "control: the template check sees a pull_request trigger" || bad "control: the template check missed pull_request"
tpl_code "$TEMPLATE" | grep -qE '^[[:space:]]*concurrency:' && bad "template has a concurrency block" || ok "template has no concurrency block"
tpl_code "$FX/bad-template.yml" | grep -qE '^[[:space:]]*concurrency:' && ok "control: the concurrency check sees a planted block" || bad "control: no concurrency block in bad-template.yml"
tpl_code "$TEMPLATE" | grep -qE '^  workflow_run:' && ok "template triggers on workflow_run" || bad "template does not trigger on workflow_run"
tpl_code "$TEMPLATE" | grep -qE '^    types: \[[^]]*\bcompleted\b[^]]*\]' && tpl_code "$TEMPLATE" | grep -qE '^    types: \[[^]]*\bin_progress\b[^]]*\]' \
  && ok "template triggers on workflow_run types completed and in_progress" || bad "template types lack completed or in_progress"
tpl_code "$TEMPLATE" | grep -qE 'uses: hyperpolymath/proven-cicd-and-workflows/\.github/workflows/ci-gate\.yml@__CICD_SUITE_SHA__' \
  && ok "template calls the reusable at the __CICD_SUITE_SHA__ placeholder" || bad "template does not call the reusable at the placeholder"
tpl_code "$TEMPLATE" | grep -qE '^  gate:' && ok "template job id is gate" || bad "template job id is not gate"
tpl_code "$TEMPLATE" | grep -qE 'context: *"CI/gate"' && ok "template publishes CI/gate" || bad "template does not publish CI/gate"

echo
printf 'ci-gate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
