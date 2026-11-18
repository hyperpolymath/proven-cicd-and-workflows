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

echo "== a run path may carry an @<ref> suffix (GitHub reports .github/workflows/build.yml@main) =="
reset; expect "bare run path (control)" success 0
mut_wr 'map(if .id == 11 then .path += "@main" else . end)'
expect "ci-build.yml@main satisfies the ci-build.yml entry" success 0
mut_wr 'map(if .id == 11 then .path += "@refs/heads/x" else . end)'
expect "ci-build.yml@refs/heads/x satisfies the ci-build.yml entry" success 0
mut_wr 'map(if .id == 11 then .path = ".github/workflows/ci-build2.yml@main" else . end)'
expect "ci-build2.yml@main does not satisfy ci-build.yml" failure 1 "never reported: ci-build.yml:Build"
mut_wr 'map(if .id == 11 then .path = ".github/workflows/other.yml@main" else . end)'
expect "other.yml@main does not satisfy ci-build.yml" failure 1 "never reported: ci-build.yml:Build"
mut_wr 'map(if .id == 11 then .path = ".github/workflows/ci-build@main.yml" else . end)'
expect "an @ inside the file stem is not a ref suffix" failure 1 "never reported: ci-build.yml:Build"
mut_wr 'map(if .id == 11 then .path = null else . end)'
expect "a run with no path never satisfies an entry" failure 1 "never reported: ci-build.yml:Build"
mut_wr 'map(if .id == 11 then .path += "@main" else . end)'
mut_jb 'map(if .name == "Build" then .conclusion = "failure" else . end)'
expect "a failed job of a ref-suffixed run path is still a failure" failure 1 "Build (failure)"
PROFILE="$WORK/two.json"
reset; mut_jb '. + [j(2001;"Build";21;"completed";"success")]'
mut_wr 'map(if .id == 11 then .path += "@main" else . end) | . + [r(21;"Other build";6;"pull_request";"completed";"2026-11-17T10:00:09Z") | .path += "@refs/heads/x"]'
expect "two producers, both paths ref-suffixed" success 0
mut_wr 'map(if .id == 11 then .path += "@main" else . end) | . + [r(21;"Other build";6;"pull_request";"completed";"2026-11-17T10:00:09Z") | .path = ".github/workflows/third.yml@main"]'
expect "two producers, the second's path is another file with a ref suffix" failure 1 "never reported: other-build.yml:Build"
PROFILE="$FX/profile.json"

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

echo "== publisher: fake gh, settle guard, status writes =="
PUBLISH="$ROOT/scripts/ci-gate-publish.sh"
SUITE_DIR="$WORK/suite"; FAKEGH="$WORK/stub"
mkdir -p "$SUITE_DIR/scripts" "$SUITE_DIR/profiles/ci-gate/example" "$FAKEGH/bin"
cp "$ROOT"/scripts/ci-gate-verdict.sh "$ROOT"/scripts/validate-ci-gate-profile.sh "$PUBLISH" "$SUITE_DIR/scripts/"
cp "$ROOT"/profiles/ci-gate/validate.jq "$ROOT"/profiles/ci-gate/select-runs.jq "$SUITE_DIR/profiles/ci-gate/"
cp "$FX/profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"
cat > "$FAKEGH/bin/gh" <<'FAKEGH_EOF'
#!/usr/bin/env bash
# Fake gh: canned runs (the Nth runs call returns runs.N.json, else the highest-numbered file),
# canned jobs, a POST log (state, description, sha), and injected failures (fail.N = the Nth runs
# call errors; failjobs). A directory by/<sha>/ holds the same files for ONE commit (the sweep
# reads many); the jobs call is answered from the commit named by the latest runs call.
# Listings for the sweep: pulls.json (open PRs), default_branch, default_sha, failpulls, faildefault.
D=${FAKEGH_DIR:?}
if [[ ${CLOCK_API_COST:-0} != 0 ]]; then
  echo "$(( $(cat "$D/clock") + CLOCK_API_COST ))" > "$D/clock"
fi
if [[ " $* " == *" -X POST "* ]]; then
  state=''; desc=''; psha=''; ctx=''
  for a in "$@"; do case $a in state=*) state=${a#state=} ;; description=*) desc=${a#description=} ;; context=*) ctx=${a#context=} ;; repos/*/statuses/*) psha=${a##*/} ;; esac; done
  [[ ! -f $D/failpost ]] || { echo "gh: HTTP 500 (post)" >&2; exit 1; }
  # the real statuses API refuses a description holding a 4-byte UTF-8 character (above U+FFFF)
  if printf '%s' "$desc" | LC_ALL=C grep -qP '[\xF0-\xF7]'; then echo "gh: HTTP 422 Description doesn't accept 4-byte Unicode" >&2; exit 1; fi
  # a newer evaluator's write that lands just before this one (deterministic pause control)
  if [[ -f $D/prepost ]]; then
    cat "$D/prepost" >> "$D/posts.log"
    awk -F'\t' -v s="$psha" -v c="$ctx" '{print s "\t" c "\t" $1 "\t" $2}' "$D/prepost" >> "$D/status.log"; rm -f "$D/prepost"
  fi
  printf '%s\t%s\t%s\n' "$state" "$desc" "$psha" >> "$D/posts.log"
  printf '%s\t%s\t%s\t%s\n' "$psha" "$ctx" "$state" "$desc" >> "$D/status.log"; exit 0
fi
args="$*"
jqarg='' ; prev=''
for a in "$@"; do [[ $prev == --jq ]] && jqarg=$a; prev=$a; done
case $args in
  *"/commits/"*"/status?per_page=100"*)
    # the combined status: the latest status per context of one commit, from status.log
    [[ ! -f $D/failstatus ]] || { echo "gh: HTTP 500 (status)" >&2; exit 1; }
    [[ ! -f $D/badstatus ]] || { echo "not json"; exit 0; }
    echo "$args" >> "$D/status.reads"
    sha=${args#*/commits/}; sha=${sha%%/*}
    jq -R -s -c --arg sha "$sha" 'split("\n") | map(select(length > 0) | split("\t") | select(.[0] == $sha)) | reduce .[] as $r ({}; .[$r[1]] = {context: $r[1], state: $r[2], description: $r[3]}) | .[]' "$D/status.log" 2>/dev/null || true ;;
  *"actions/runs?head_sha"*)
    sha=${args#*head_sha=}; sha=${sha%%&*}; echo "$sha" > "$D/cursha"
    R=$D; [[ ! -d $D/by/$sha ]] || R=$D/by/$sha
    n=$(( $(cat "$R/runs.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$R/runs.count"
    [[ ! -f $R/fail.$n ]] || { echo "gh: HTTP 500" >&2; exit 1; }
    f=$R/runs.$n.json; [[ -f $f ]] || f=$(ls "$R"/runs.*.json | sort -V | tail -1)
    jq -c '.[]' "$f" ;;
  *"/jobs?filter=latest"*)
    R=$D; [[ ! -d $D/by/$(cat "$D/cursha" 2>/dev/null) ]] || R=$D/by/$(cat "$D/cursha")
    [[ ! -f $R/failjobs ]] || { echo "gh: HTTP 500 (jobs)" >&2; exit 1; }
    id=${args#*actions/runs/}; id=${id%%/*}
    jq -c --argjson id "$id" '.[] | select(.run.id == $id) | del(.run)' "$R/jobs.json" ;;
  *"/pulls?state=open"*)
    [[ ! -f $D/failpulls ]] || { echo "gh: HTTP 500 (pulls)" >&2; exit 1; }
    jq -r "$jqarg" "$D/pulls.json" ;;
  *"--jq .default_branch"*)
    [[ ! -f $D/faildefault ]] || { echo "gh: HTTP 500 (repo)" >&2; exit 1; }
    cat "$D/default_branch" ;;
  *"/branches/"*)
    [[ ! -f $D/faildefault ]] || { echo "gh: HTTP 500 (branch)" >&2; exit 1; }
    cat "$D/default_sha" ;;
  *) echo "fake gh: unexpected call: $args" >&2; exit 1 ;;
esac
FAKEGH_EOF
chmod +x "$FAKEGH/bin/gh"
SHA=$(printf 'a%.0s' $(seq 40))
snap() { # <n> <jq filter over the fixture runs> -> runs.n.json
  jq -c "$2" "$FX/workflow-runs.json" > "$FAKEGH/runs.$1.json"
}
pubreset() { rm -rf "$FAKEGH/by" "$FAKEGH/cursha" "$FAKEGH/pulls.json" "$FAKEGH/default_branch" "$FAKEGH/default_sha" "$FAKEGH/failpulls" "$FAKEGH/faildefault"; rm -f "$FAKEGH"/runs.*.json "$FAKEGH/prepost" "$FAKEGH"/fail.* "$FAKEGH"/failjobs "$FAKEGH"/failpost "$FAKEGH/posts.log" "$FAKEGH/runs.count" "$FAKEGH/status.log" "$FAKEGH/status.reads" "$FAKEGH/failstatus" "$FAKEGH/badstatus" "$WORK/gho"; cp "$FX/jobs.json" "$FAKEGH/jobs.json"; }
publish() { # [VAR=value ...] -> RC, NPOSTS, POSTS (state<TAB>description lines), CALLS (runs fetches)
  : > "$FAKEGH/posts.log"; rm -f "$FAKEGH/runs.count"; rm -rf "$WORK/pw"
  echo 0 > "$FAKEGH/clock"; : > "$FAKEGH/sleeps"
  PUBOUT=$(env PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" REPO=example/repo HEAD_SHA="$SHA" CONTEXT=CI/gate \
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

pubreset; snap 1 "$DONE"; publish
chk "everything passed: one POST" "$NPOSTS" 1
chk "everything passed: success" "$(post_n 1 | cut -f1)" success
chk "everything passed: exit 0" "$RC" 0
chk "everything passed: three run fetches (snapshot, guard, post-write verify)" "$CALLS" 3
[ -s "$WORK/gho" ] && grep -q '^published=true$' "$WORK/gho" && ok "published=true written" || bad "published=true not written"

pubreset; snap 1 "$RERUN"; publish
chk "a run is active: pending, one POST" "$(post_n 1 | cut -f1)/$NPOSTS" "pending/1"
chk "pending is a normal wait: exit 0" "$RC" 0
chk "the publisher writes no 're-run started' of its own (that is the workflow's first step)" "$(post_n 1 | cut -f2 | grep -c 're-run started')" 0

echo "-- the runs change between evaluation and publish --"
pubreset; snap 1 "$RERUN"; snap 2 "$DONE"; snap 3 "$DONE"
publish
chk "fingerprint moved: one POST, not the stale pending" "$NPOSTS" 1
chk "fingerprint moved: the POST reflects the new data (success)" "$(post_n 1 | cut -f1)" success
chk "fingerprint moved: re-evaluated (5 run fetches)" "$CALLS" 5
pubreset; snap 1 "$DONE"; snap 2 "$RERUN"; snap 3 "$RERUN"
publish
chk "success evaluated, run started before the POST: no stale success" "$(post_n 1 | cut -f1)" pending
chk "success evaluated, run started before the POST: one POST" "$NPOSTS" 1
echo "-- an early-snapshot evaluator that finishes after the settle --"
pubreset; snap 1 "$RERUN"; snap 2 "$DONE"
publish
chk "early evaluator: its only POST is success, not the stale pending" "$(post_n 1 | cut -f1)/$NPOSTS" "success/1"
echo "-- a stale write is corrected by the post-write verification --"
pubreset; snap 1 "$DONE"; snap 2 "$DONE"; snap 3 "$RERUN"; snap 4 "$RERUN"; snap 5 "$RERUN"; snap 6 "$RERUN"
printf 'pending\twaiting for 1 workflow runs: CI quality\n' > "$FAKEGH/prepost"
publish
chk "a newer pending lands just before the evaluator's POST: the log is pending, success, pending" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)" "pending,success,pending"
chk "the final POST is not the stale success" "$(post_n 3 | cut -f1)" pending
chk "the evaluator itself wrote two statuses (success, then the corrected pending)" "$(sed -n '2,3p' "$FAKEGH/posts.log" | cut -f1 | paste -sd, -)" "success,pending"
chk "verification costs one more fetch per write (3 + 3 fetches)" "$CALLS" 6
chk "settled after the correction: exit 0" "$RC" 0
echo "-- the post-write verification is bounded at 5 rounds --"
pubreset; for i in $(seq 1 3 16); do snap "$i" "map(.updated_at = \"g$i\")"; snap $((i+1)) "map(.updated_at = \"g$i\")"; snap $((i+2)) "map(.updated_at = \"v$i\")"; done
publish
chk "guard passes but the verify always moves: one success POST (the 4 repeats are skipped as unchanged), then one pending" "$NPOSTS" 2
chk "the 4 repeated identical success writes were skipped, not posted" "$(grep -c 'write skipped' <<<"$PUBOUT")" 4
chk "the last write is pending 'runs still changing'" "$(post_n 2 | cut -f1,2)" "$(printf 'pending\truns still changing')"
chk "no write after round 5 other than that pending; still 5 rounds, 15 fetches" "$CALLS" 15
chk "bounded: exit 0 (pending), never success last" "$RC" 0
echo "-- the runs never stabilise --"
pubreset; for i in $(seq 1 14); do snap "$i" "map(.updated_at = \"t$i\")"; done
publish
chk "never stable: one POST" "$NPOSTS" 1
chk "never stable: pending" "$(post_n 1 | cut -f1)" pending
chk "never stable: 'runs still changing'" "$(post_n 1 | cut -f2)" "runs still changing"
chk "never stable: 5 rounds, two fetches each" "$CALLS" 10
chk "never stable: never success, exit 0" "$RC" 0
echo "-- a late evaluator cannot leave a stale failure either --"
pubreset; snap 1 "$DONE"; snap 2 "map(if .id == 11 then .status = \"in_progress\" else . end)"
jq 'map(if .name == "Test" then .conclusion = "failure" else . end)' "$FX/jobs.json" > "$FAKEGH/jobs.json"
snap 3 "$DONE"
publish
chk "stale failure not written when the runs moved; re-evaluated: failure on settled data" "$(post_n 1 | cut -f1)" failure
chk "failure verdict: exit 1" "$RC" 1
chk "failure verdict: names the job" "$(post_n 1 | cut -f2 | grep -c 'Test (failure)')" 1
echo "-- errors fail closed --"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/fail.1"; publish
chk "gh error on the first runs fetch: a failure POST" "$(post_n 1 | cut -f1)" failure
chk "gh error: exit 1, one POST" "$RC/$NPOSTS" "1/1"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/fail.2"; publish
chk "gh error on the guard fetch: a failure POST" "$(post_n 1 | cut -f1)" failure
pubreset; snap 1 "$DONE"; touch "$FAKEGH/fail.3"; publish
chk "gh error on the post-write fetch: success was written, then a failure POST" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$RC" "success,failure/1"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/failjobs"; publish
chk "gh error reading jobs: a failure POST" "$(post_n 1 | cut -f1)" failure
pubreset; snap 1 "$DONE"; touch "$FAKEGH/failpost"; publish
chk "the status POST itself fails: exit 1, no published=true" "$RC/$([ -s "$WORK/gho" ] && echo 1 || echo 0)" "1/0"
pubreset; snap 1 "$DONE"; rm -f "$SUITE_DIR/profiles/ci-gate/example/repo.json"; publish
chk "no profile: a failure POST, exit 1" "$(post_n 1 | cut -f1)/$RC" "failure/1"
cp "$FX/profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"
pubreset; snap 1 "$DONE"; publish HEAD_SHA=abc
chk "a head SHA that is not 40 hex: exit 1, no POST" "$RC/$NPOSTS" "1/0"
pubreset

echo "== pull_request wait loop: WAIT_SECONDS, POLL_SECONDS =="
NOQ='map(select(.name != "CI quality"))'   # CI quality produces the required jobs Lint and Test
cat > "$FAKEGH/bin/clock" <<'CLOCK'
#!/usr/bin/env bash
cat "$FAKEGH_DIR/clock"
CLOCK
cat > "$FAKEGH/bin/poll-sleep" <<'SLEEP'
#!/usr/bin/env bash
echo "$1" >> "$FAKEGH_DIR/sleeps"
echo "$(( $(cat "$FAKEGH_DIR/clock") + $1 ))" > "$FAKEGH_DIR/clock"
SLEEP
chmod +x "$FAKEGH/bin/clock" "$FAKEGH/bin/poll-sleep"
WAITENV=(WAIT_SECONDS=30 POLL_SECONDS=10 CI_GATE_CLOCK="$FAKEGH/bin/clock" CI_GATE_SLEEP="$FAKEGH/bin/poll-sleep")
echo "-- required checks that have not reported yet are waited for, never failed early --"
pubreset; snap 1 "$NOQ"; snap 2 "$NOQ"; snap 3 "$DONE"; publish "${WAITENV[@]}"
chk "late reporter: exactly one POST" "$NPOSTS" 1
chk "late reporter: the only status written is success (no early 'never reported' failure)" "$(post_n 1 | cut -f1)" success
chk "late reporter: exit 0" "$RC" 0
chk "late reporter: two waits were logged" "$(grep -c '^wait: ' <<<"$PUBOUT")" 2
chk "late reporter: waits do not use the settle rounds (2 waiting fetches + 3 for the settle)" "$CALLS" 5
pubreset; snap 1 "$RERUN"; snap 2 "$DONE"; publish "${WAITENV[@]}"
chk "an active run is waited for, then success is the only POST" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/success/0"
chk "an active run is waited for: the pending verdict was logged as a wait, not written" "$(grep -c '^wait: pending' <<<"$PUBOUT")" 1
echo "-- negative controls: a required check that never reports, a run that never ends --"
pubreset; snap 1 "$NOQ"; publish "${WAITENV[@]}"
chk "never reports: one POST only, after the wait is used up" "$NPOSTS" 1
chk "never reports: failure" "$(post_n 1 | cut -f1)" failure
chk "never reports: names what never reported (Lint and Test)" "$(post_n 1 | cut -f2 | grep -c 'never reported: ci-quality.yml:Lint, ci-quality.yml:Test')" 1
chk "never reports: three polls, 30 s used" "$(grep -c '^wait: ' <<<"$PUBOUT")" 3
chk "never reports: exit 1 (red job)" "$RC" 1
pubreset; snap 1 "$RERUN"; publish "${WAITENV[@]}"
chk "never ends: failure, one POST" "$(post_n 1 | cut -f1)/$NPOSTS" "failure/1"
chk "never ends: says it gave up and names the run" "$(post_n 1 | cut -f2 | grep -c 'gave up after 0 min: waiting for 1 workflow runs: CI quality')" 1
chk "never ends: exit 1" "$RC" 1
pubreset; snap 1 "$RERUN"; publish "${WAITENV[@]}" WAIT_SECONDS=120
chk "wait of 2 min is reported as 2 min" "$(post_n 1 | cut -f2 | grep -c 'gave up after 2 min')" 1
echo "-- a real failure is written at once, never waited out --"
pubreset; snap 1 "$DONE"; jq 'map(if .name == "Test" then .conclusion = "failure" else . end)' "$FX/jobs.json" > "$FAKEGH/jobs.json"
publish "${WAITENV[@]}"
chk "failed job: failure, one POST" "$(post_n 1 | cut -f1)/$NPOSTS" "failure/1"
chk "failed job: no wait" "$(grep -c '^wait: ' <<<"$PUBOUT")" 0
chk "failed job: exit 1" "$RC" 1
echo "-- without WAIT_SECONDS (workflow_run, sweep) nothing changes --"
pubreset; snap 1 "$NOQ"; publish
chk "no wait: never reported is an immediate failure, one POST" "$(post_n 1 | cut -f1)/$NPOSTS" "failure/1"
chk "no wait: no polling" "$(grep -c '^wait: ' <<<"$PUBOUT")" 0
pubreset; snap 1 "$RERUN"; publish
chk "no wait: pending is written as pending, exit 0" "$(post_n 1 | cut -f1)/$RC" "pending/0"
echo "-- elapsed deadline and reruns during bootstrap --"
pubreset; snap 1 "$NOQ"; publish "${WAITENV[@]}" WAIT_SECONDS=25
chk "final sleep is capped at the remaining budget" "$(paste -sd, "$FAKEGH/sleeps")/$RC" "10,10,5/1"
pubreset; snap 1 "$NOQ"; publish "${WAITENV[@]}" CLOCK_API_COST=4
chk "API time counts towards the deadline" "$(paste -sd, "$FAKEGH/sleeps")/$RC" "10/1"
pubreset; snap 1 "$DONE"; publish "${WAITENV[@]}"
chk "bootstrap settled success remains immediate" "$NPOSTS/$(post_n 1 | cut -f1)/$RC/$(wc -l < "$FAKEGH/sleeps")" "1/success/0/0"
pubreset; snap 1 "$DONE"; snap 2 "$DONE"; snap 3 "$RERUN"; snap 4 "$RERUN"; snap 5 "$DONE"
publish "${WAITENV[@]}"
chk "rerun invalidates our success before polling, then settles" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$RC" "success,pending,success/0"
pubreset; snap 1 "$DONE"; snap 2 "$DONE"; snap 3 "$RERUN"; publish "${WAITENV[@]}"
chk "rerun that never ends clears success and fails by the deadline" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$RC" "success,pending,failure/1"
pubreset; for i in $(seq 1 40); do snap "$i" "map(.updated_at = \"t$i\")"; done
publish "${WAITENV[@]}"
chk "PR keeps settling beyond five rounds until its deadline, then fails" "$(post_n 1 | cut -f1)/$RC/$CALLS/$(paste -sd, "$FAKEGH/sleeps")" "failure/1/30/10,10,10"
pubreset; for i in $(seq 1 10); do snap "$i" "map(.updated_at = \"t$i\")"; done
snap 11 "$DONE"; publish "${WAITENV[@]}"
chk "PR can settle successfully after five moving rounds" "$(post_n 1 | cut -f1)/$RC/$CALLS" "success/0/13"

echo "-- bad wait settings fail closed --"
pubreset; snap 1 "$DONE"; publish WAIT_SECONDS=abc
chk "WAIT_SECONDS=abc: refused, no POST, exit 1" "$NPOSTS/$RC" "0/1"
pubreset; snap 1 "$DONE"; publish WAIT_SECONDS=30 POLL_SECONDS=0
chk "POLL_SECONDS=0: refused, no POST, exit 1" "$NPOSTS/$RC" "0/1"
echo "-- the wait keys on the verdict script's descriptions: pin them --"
grep -q '"never reported: "' "$VERDICT" && grep -q '"never completed: "' "$VERDICT" && ok "the verdict still words 'never reported: ' and 'never completed: ' (the wait depends on both prefixes)" || bad "the verdict wording changed; the pull_request wait would stop waiting"

echo "== context guard: the workflow's own regex, and a context with spaces =="
CTX_RE_LINES=$(grep -E "^[[:space:]]*ctx_re='" "$WORKFLOW" | sed 's/^[[:space:]]*//')
chk "ci-gate.yml has two ctx_re guards (validation step and failure fallback)" "$(grep -c . <<<"$CTX_RE_LINES")" 2
chk "both ctx_re guards are byte-identical" "$(sort -u <<<"$CTX_RE_LINES" | grep -c .)" 1
CTX_FRAG='${#CONTEXT} -le 128 && $CONTEXT =~ $ctx_re'
chk "both guards apply the 128-character cap and the regex" "$(grep -cF -- "$CTX_FRAG" "$WORKFLOW")" 2
ctx_ok() { CONTEXT="$1" bash -c "$(head -1 <<<"$CTX_RE_LINES")"$'\n'"[[ $CTX_FRAG ]]" 2> /dev/null; }
ctx_re_only() { CONTEXT="$1" bash -c "$(head -1 <<<"$CTX_RE_LINES")"$'\n''[[ $CONTEXT =~ $ctx_re ]]' 2> /dev/null; }
rep() { local o='' i; for ((i = 0; i < $2; i++)); do o+=$1; done; printf '%s' "$o"; }
for c in 'CI/gate' 'CI / gate' 'CI /gate' 'a' 'estate-gate' 'ci.gate_v2' "$(rep a 128)" "$(rep 'a ' 63)a"; do
  ctx_ok "$c" && ok "context guard accepts '${c:0:40}' (${#c} chars)" || bad "context guard rejects '${c:0:40}' (${#c} chars)"
done
for c in ' CI/gate' 'CI/gate ' 'CI  /gate' $'CI\t/gate' $'CI/\tgate' $'CI/gate\n' $'CI\n/gate' '' ' ' '/gate' 'CI;gate' 'CI/gate$(x)' "$(rep a 129)" "$(rep 'a ' 64)a" "$(rep 'a ' 127)a"; do
  ctx_ok "$c" && bad "context guard accepts $(printf '%q' "${c:0:40}") (${#c} chars)" || ok "context guard rejects $(printf '%q' "${c:0:40}") (${#c} chars)"
done
ctx_re_only "$(rep 'a ' 127)a" && ok "control: the regex alone admits 255 characters, so the length cap is what bounds the context" || bad "control: the regex alone is already bounded; re-check the cap"
CALLER="$ROOT/.github/workflows/ci-gate-caller.yml"
CALLER_CTX=$(sed -n 's/^[[:space:]]*context:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$CALLER" | sort -u)
chk "the dogfood caller has two context lines (gate and gate-pr), identical" "$(sed -n 's/^[[:space:]]*context:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$CALLER" | grep -c .)" 2
chk "the dogfood caller sets exactly one with.context" "$(grep -c . <<<"$CALLER_CTX")" 1
chk "the dogfood caller's context is CI / gate" "$CALLER_CTX" "CI / gate"
ctx_ok "$CALLER_CTX" && ok "the dogfood caller's context passes the workflow's own guard" || bad "the dogfood caller's context fails the workflow's guard"
TEMPLATE_CTX=$(sed -n 's/^[[:space:]]*context:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$TEMPLATE" | sort -u)
ctx_ok "$TEMPLATE_CTX" && ok "the template's context ('$TEMPLATE_CTX') passes the workflow's own guard" || bad "the template's context fails the workflow's guard"

echo "-- CONTEXT='CI / gate' end to end through the publisher --"
pubreset; snap 1 "$DONE"; publish CONTEXT='CI / gate'
chk "a spaced context reaches evaluation: success POSTed" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/success/0"
chk "the success status carries the context exactly 'CI / gate'" "$(cut -f2 "$FAKEGH/status.log" | sort -u)" "CI / gate"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/failjobs"; publish CONTEXT='CI / gate'
chk "a failure case posts one failure status" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/failure/1"
chk "the failure status carries the context exactly 'CI / gate'" "$(cut -f2 "$FAKEGH/status.log")" "CI / gate"
pubreset; snap 1 "$DONE"; jq 'map(if .name == "Test" then .conclusion = "failure" else . end)' "$FX/jobs.json" > "$FAKEGH/jobs.json"; publish CONTEXT='CI / gate'
chk "a failing verdict is posted under 'CI / gate' too" "$(post_n 1 | cut -f1)/$(cut -f2 "$FAKEGH/status.log")" "failure/CI / gate"

echo "-- the 1000-statuses-per-SHA-and-context cap: a write that repeats the standing status is skipped --"
pubreset; snap 1 "$DONE"; publish
chk "first evaluation: one POST (success)" "$NPOSTS/$(post_n 1 | cut -f1)" "1/success"
chk "the current status was read through the combined-status endpoint, per_page=100" "$(grep -c "commits/$SHA/status?per_page=100" "$FAKEGH/status.reads")" 1
rm -f "$WORK/gho"; publish
chk "unchanged verdict: no second POST" "$NPOSTS" 0
chk "unchanged verdict: still exit 0, treated as published (published=true)" "$RC/$(grep -c '^published=true$' "$WORK/gho" 2> /dev/null || true)" "0/1"
chk "unchanged verdict: the skip is logged" "$(grep -c 'write skipped' <<<"$PUBOUT")" 1
chk "unchanged verdict: the verdict line is still printed" "$(grep -c '^CI/gate = success: all 3 required checks passed$' <<<"$PUBOUT")" 1
snap 1 "$RERUN"; publish
chk "changed state (success -> pending): a POST" "$NPOSTS/$(post_n 1 | cut -f1)" "1/pending"
publish
chk "and that pending, repeated: no POST" "$NPOSTS" 0
pubreset; snap 1 "$DONE"; printf '%s\tCI/gate\tsuccess\tall 2 required checks passed\n' "$SHA" > "$FAKEGH/status.log"; publish
chk "same state, changed description: a POST" "$NPOSTS/$(post_n 1 | cut -f2)" "1/all 3 required checks passed"
pubreset; snap 1 "$DONE"; printf '%s\tother/ctx\tsuccess\tall 3 required checks passed\n' "$SHA" > "$FAKEGH/status.log"; publish
chk "a different context with the same state and description: a POST" "$NPOSTS/$(post_n 1 | cut -f1)" "1/success"
pubreset; snap 1 "$DONE"; printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tCI/gate\tsuccess\tall 3 required checks passed\n' > "$FAKEGH/status.log"; publish
chk "the same status on another commit: a POST" "$NPOSTS" 1
pubreset; snap 1 "$DONE"; publish; touch "$FAKEGH/failstatus"; publish
chk "the status read fails: POST anyway" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/success/0"
rm -f "$FAKEGH/failstatus"; touch "$FAKEGH/badstatus"; publish
chk "the status read is malformed (not JSON): POST anyway" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/success/0"
rm -f "$FAKEGH/badstatus"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/failjobs"; publish
chk "die(): the first failure is POSTed" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/failure/1"
rm -f "$WORK/gho"; publish
chk "die(): the identical failure repeated is skipped, same exit code 1" "$NPOSTS/$RC" "0/1"
chk "die(): the skip still counts as published (published=true)" "$(grep -c '^published=true$' "$WORK/gho")" 1
chk "die(): the skip is logged" "$(grep -c 'write skipped' <<<"$PUBOUT")" 1
touch "$FAKEGH/failstatus"; publish
chk "die() with a failing status read: POSTs" "$NPOSTS" 1
pubreset
echo "-- the comparison is on the clipped description --"
pubreset; reset; jq -n '[range(0;60) | {id:(5000+.),name:("A long required check name number \(.)"),status:"completed",conclusion:"failure",run:{id:11,name:"CI build",status:"completed"}}]' > "$FAKEGH/jobs.json"
cp "$WORK/long.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"; snap 1 "$DONE"; publish
chk "a failure whose description is clipped to 140 characters: one POST" "$NPOSTS/$(dlen "$(post_n 1 | cut -f2)")" "1/140"
publish
chk "the same clipped failure again: skipped" "$NPOSTS" 0
cp "$FX/profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"
pubreset

echo "-- a workflow run record above 128 KiB (one argv string) passes through the publisher --"
pubreset; snap 1 'map(. + {pad: ("x" * 200000)})'
[ "$(jq -c '.[0]' "$FAKEGH/runs.1.json" | wc -c)" -gt 200000 ] && ok "control: the run records are over 200 KB each" || bad "control: the run records are not large"
publish
chk "200 KB run records: evaluated, one success POST, exit 0" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/success/0"
chk "200 KB run records: no 'Argument list too long'" "$(grep -c 'too long' <<<"$PUBOUT")" 0
pubreset

echo "-- the workflow's first step marks a started run pending before any suite file is read --"
step_line() { grep -n -- "- name: $1" "$WORKFLOW" | head -1 | cut -d: -f1; }
L_REFUSE=$(step_line 'Refuse anything'); L_PEND=$(step_line 'Mark a started or re-run'); L_READ=$(step_line 'Read the profile')
{ [ -n "$L_REFUSE" ] && [ -n "$L_PEND" ] && [ -n "$L_READ" ] && [ "$L_REFUSE" -lt "$L_PEND" ] && [ "$L_PEND" -lt "$L_READ" ]; } \
  && ok "step order: input validation, then the early pending, then the profile fetch" || bad "step order is wrong ($L_REFUSE, $L_PEND, $L_READ)"
EARLY=$(sed -n "${L_PEND},$((L_READ - 1))p" "$WORKFLOW")
grep -q 'EVENT_ACTION' <<<"$EARLY" && grep -q 'in_progress' <<<"$EARLY" && grep -q 'state=pending' <<<"$EARLY" && grep -q 're-run started' <<<"$EARLY" \
  && ok "the early step posts pending 're-run started' for an in_progress action" || bad "the early step lacks the in_progress pending"
! grep -qE '\$suite|fetch |scripts/' <<<"$EARLY" && ok "the early step reads no suite file" || bad "the early step touches the suite"
! grep -q '\${{' <(awk '/^        run: \|/{f=1;next} f' <<<"$EARLY") && ok "the early step has no \${{ }} inside its run: script" || bad "the early step interpolates into run:"

echo "== a status description never carries a 4-byte UTF-8 character (the statuses API rejects it) =="
# GitHub's statuses API answers HTTP 422 "Description doesn't accept 4-byte Unicode" for any codepoint
# above U+FFFF, and consumer job and workflow names carry emoji. Both write sites strip them BEFORE the
# cut to 140 characters: clip() in the publisher (post(), so die() too) and the early-pending step.
# The expressions are extracted from the code under test, never retyped here.
RED=$'\xf0\x9f\x94\xb4'; YEL=$'\xf0\x9f\x9f\xa1'
four_byte() { printf '%s' "$1" | LC_ALL=C grep -qP '[\xF0-\xF7]'; }   # any UTF-8 lead byte >= 0xF0
CLIP_DEF=$(grep -m1 '^clip()' "$PUBLISH")
[ -n "$CLIP_DEF" ] && ok "found clip() in scripts/ci-gate-publish.sh" || bad "clip() not found"
clip_of() { bash -c "$CLIP_DEF"$'\n''clip "$1"' _ "$1"; }
EARLY_EXPR=$(grep -m1 'desc=\$(jq' <<<"$EARLY")
[ -n "$EARLY_EXPR" ] && ok "found the early-pending description expression in the workflow" || bad "early-pending expression not found"
early_of() { RUN_NAME="$1" bash -c "$EARLY_EXPR"$'\n''printf %s "$desc"'; }
OLD_EXPR='"re-run started: " + $n | if length > 140 then .[0:139] + "…" else . end'   # the expression before the fix
NAME_RG="${RED} GATE: Invisible Character Detection / ${YEL} CHECK: Groove Protocol Compliance"
NEAR=$(printf 'a%.0s' $(seq 1 137))${RED}${YEL}${RED}tail   # emoji straddling the 140 boundary (clip)
NEAR2=$(printf 'a%.0s' $(seq 1 121))${RED}${YEL}${RED}tail  # the same for the early step, whose fixed prefix is 16 characters
LONG=$(printf 'n%.0s' $(seq 1 120))${RED}$(printf 'm%.0s' $(seq 1 40))   # 160 characters, emoji inside the first 140
for pair in "clip():$(clip_of "$NAME_RG")" "early:$(early_of "$NAME_RG")"; do
  w=${pair%%:*}; v=${pair#*:}
  four_byte "$v" && bad "$w: a name with 🔴 and 🟡 still has a 4-byte character: $v" || ok "$w: a name with 🔴 and 🟡 comes out with no 4-byte character"
  [ "$(dlen "$v")" -le 140 ] && ok "$w: that description is at most 140 characters" || bad "$w: that description is $(dlen "$v") characters"
  case "$v" in *GATE:*Invisible*CHECK:*Groove*) ok "$w: the BMP text of the name is kept" ;; *) bad "$w: the text was damaged: $v" ;; esac
done
for nm in "$NEAR" "$NEAR2" "$LONG"; do
  for w in clip early; do
    if [ $w = clip ]; then v=$(clip_of "$nm"); else v=$(early_of "$nm"); fi
    four_byte "$v" && bad "$w: a long name (${#nm} chars) with emoji near the boundary still has a 4-byte character" || ok "$w: a long name (${#nm} chars) with emoji near the boundary has no 4-byte character"
    [ "$(dlen "$v")" -le 140 ] && ok "$w: the long name's description is at most 140 characters ($(dlen "$v"))" || bad "$w: the long name's description is $(dlen "$v") characters"
    # cut with an ellipsis whenever the text left after stripping is over 140 (not clip with NEAR2: 125 left)
    [ "$w$nm" = "clip$NEAR2" ] || { case "$v" in *…) ok "$w: the long name is cut with an ellipsis" ;; *) bad "$w: the long name has no ellipsis" ;; esac; }
  done
done
# negative control: the expression from before the fix keeps the emoji, so the detector above can fail
OLDV=$(jq -rn --arg n "$NAME_RG" "$OLD_EXPR")
four_byte "$OLDV" && ok "negative control: the old expression keeps the emoji (the 4-byte detector fires)" || bad "negative control: the old expression dropped the emoji, so the tests above prove nothing"
# the two write sites use the same character class
[ "$(grep -c 'gsub("\[\\\\x{10000}-\\\\x{10FFFF}\]"; "")' <<<"$CLIP_DEF"$'\n'"$EARLY_EXPR")" = 2 ] && ok "both write sites strip the same range U+10000 to U+10FFFF" || bad "the two sites do not share the same strip expression"
# end to end: the real publisher with a fake gh that rejects a 4-byte description like the real API
pubreset; reset
jq -n --arg a "${RED} GATE: Invisible Character Detection" --arg b "${YEL} CHECK: Groove Protocol Compliance" \
  '[{id:7001,name:$a,status:"completed",conclusion:"failure",run:{id:11,name:"CI build",status:"completed"}},{id:7002,name:$b,status:"completed",conclusion:"success",run:{id:11,name:"CI build",status:"completed"}}]' > "$FAKEGH/jobs.json"
jq -n --arg a "${RED} GATE: Invisible Character Detection" --arg b "${YEL} CHECK: Groove Protocol Compliance" \
  '{checks:([{job:$a,workflow:".github/workflows/ci-build.yml"},{job:$b,workflow:".github/workflows/ci-build.yml"}] | sort_by([.workflow,.job])),repository:"example/repo",schema_version:2}' > "$SUITE_DIR/profiles/ci-gate/example/repo.json"
snap 1 "$DONE"; publish
chk "emoji job names: the publisher posts exactly once (the fake API refuses 4-byte text)" "$NPOSTS" 1
chk "emoji job names: the verdict is the real failure, not an API-error failure" "$(post_n 1 | cut -f1)/$(post_n 1 | cut -f2 | grep -c 'could not publish')" "failure/0"
four_byte "$(post_n 1 | cut -f2)" && bad "emoji job names: the posted description has a 4-byte character" || ok "emoji job names: the posted description has no 4-byte character"
case "$(post_n 1 | cut -f2)" in 'failed: ci-build.yml: GATE: Invisible Character Detection'*) ok "emoji job names: the description still names the failing check" ;; *) bad "emoji job names: description is '$(post_n 1 | cut -f2)'" ;; esac
cp "$FX/profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"
pubreset

echo "== sweep: schedule and workflow_dispatch re-evaluate every open pull request head and the default branch head =="
cp "$ROOT/scripts/ci-gate-sweep.sh" "$SUITE_DIR/scripts/"
sha_n() { printf '%040x' "$1"; }
sweep_sha() { # <n> <runs jq filter> [jobs jq filter] -> by/<sha n>/ holds the runs and jobs of that one commit
  local s; s=$(sha_n "$1"); mkdir -p "$FAKEGH/by/$s"
  jq -c "$2" "$FX/workflow-runs.json" > "$FAKEGH/by/$s/runs.1.json"
  jq -c "${3:-.}" "$FX/jobs.json" > "$FAKEGH/by/$s/jobs.json"
}
set_pulls() { # "<number> <updated_at> <sha n>" ... -> the open pull requests
  local t num upd idx
  for t in "$@"; do read -r num upd idx <<<"$t"; printf '%s %s %s\n' "$num" "$upd" "$(sha_n "$idx")"; done \
    | jq -R -s 'split("\n") | map(select(length > 0) | split(" ") | {number: (.[0] | tonumber), updated_at: .[1], head: {sha: .[2]}})' > "$FAKEGH/pulls.json"
}
set_default() { echo main > "$FAKEGH/default_branch"; sha_n "$1" > "$FAKEGH/default_sha"; }
seed() { printf '%s\t%s\t%s\n' "$1" "$3" "$(sha_n "$2")" >> "$FAKEGH/posts.log"; printf '%s\tCI/gate\t%s\t%s\n' "$(sha_n "$2")" "$1" "$3" >> "$FAKEGH/status.log"; }   # a status already on the commit
sweep() { # [VAR=value ...] -> RC, SOUT; the posts are in posts.log, the summary table in $WORK/gss
  : > "$WORK/gss"; rm -rf "$WORK/sw"
  SOUT=$(env PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" REPO=example/repo CONTEXT=CI/gate \
    TIMEOUT_MINUTES=180 GATE_NAME='CI gate' SUITE="$SUITE_DIR" WORK="$WORK/sw" CI_GATE_NOW="$NOW" \
    GITHUB_STEP_SUMMARY="$WORK/gss" "$@" bash "$SUITE_DIR/scripts/ci-gate-sweep.sh" 2>&1)
  RC=$?
}
last_for() { grep -P "\t$(sha_n "$1")$" "$FAKEGH/posts.log" | tail -1 | cut -f1; }
count_for() { grep -cP "\t$(sha_n "$1")$" "$FAKEGH/posts.log" || true; }
TESTFAIL='map(if .name == "Test" then .conclusion = "failure" else . end)'
T1=2026-11-17T10:00:00Z

pubreset; set_pulls "1 $T1 1"; set_default 2
sweep_sha 1 "$DONE" "$TESTFAIL"; sweep_sha 2 "$DONE"
seed success 1 'all 3 required checks passed'
sweep
chk "a stale success on a SHA whose latest runs show a failed required job: corrected to failure" "$(last_for 1)" failure
chk "that correction is a new write after the stale success (success, then failure)" "$(grep -P "\t$(sha_n 1)$" "$FAKEGH/posts.log" | cut -f1 | paste -sd, -)" "success,failure"
chk "the default branch head, all green, is success" "$(last_for 2)" success
chk "a failed SHA makes the sweep exit non-zero" "$RC" 1
grep -q 'Test (failure)' "$FAKEGH/posts.log" && ok "the failure names the job" || bad "the failure does not name the job"
grep -qF "| \`$(sha_n 1 | cut -c1-12)\` | PR #1 | failure |" "$WORK/gss" && ok "the step summary table has the failed row" || bad "no failed row in the summary table"
grep -qF "| default branch | success |" "$WORK/gss" && ok "the step summary table has the default branch row" || bad "no default branch row in the summary table"

pubreset; set_pulls "1 $T1 3"; set_default 4
sweep_sha 3 "$DONE"; sweep_sha 4 "$DONE"
seed pending 3 'waiting for 1 workflow runs: CI quality'
sweep
chk "a stuck pending on a settled all-green SHA is corrected to success" "$(grep -P "\t$(sha_n 3)$" "$FAKEGH/posts.log" | cut -f1 | paste -sd, -)" "pending,success"
chk "settled and green everywhere: exit 0" "$RC" 0

pubreset; set_pulls "1 $T1 5" "2 2026-11-17T10:01:00Z 6" "3 2026-11-17T10:02:00Z 7" "4 2026-11-17T10:03:00Z 5"; set_default 7
for i in 5 6 7; do sweep_sha "$i" "$DONE"; done
sweep
chk "two pull requests plus the default branch: three evaluations (a head shared by two PRs, or by a PR and the default branch, once)" "$(cut -f3 "$FAKEGH/posts.log" | sort -u | grep -c .)/$(grep -c . "$FAKEGH/posts.log")" "3/3"
chk "each of the three SHAs was written once" "$(count_for 5)$(count_for 6)$(count_for 7)" 111
chk "three evaluations, all green: exit 0" "$RC" 0
[ "$(grep -c '^| `' "$WORK/gss")" = 3 ] && ok "the step summary table has three rows" || bad "the step summary table does not have three rows"
chk "a sweep writes no 're-run started' pending" "$(grep -c 're-run started' "$FAKEGH/posts.log" || true)" 0

echo "-- more SHAs than the cap: the most recently updated are evaluated, the rest are named in a warning --"
pubreset; set_default 8
set_pulls "1 2026-11-17T10:05:00Z 9" "2 2026-11-17T10:03:00Z 10" "3 2026-11-17T10:01:00Z 11"
for i in 8 9 10 11; do sweep_sha "$i" "$DONE"; done
sweep CI_GATE_SWEEP_MAX=2
chk "over the cap of 2: the default branch head and the newest pull request are evaluated" "$(count_for 8)$(count_for 9)" 11
chk "over the cap: the older pull requests are not evaluated" "$(count_for 10)$(count_for 11)" 00
grep -qE '^::warning::.*4 distinct head SHAs.*exceed the cap of 2; 2 .*NOT evaluated' <<<"$SOUT" && ok "the over-cap warning names the count skipped" || bad "no over-cap warning: $SOUT"
grep -q 'over the cap' "$WORK/gss" && ok "the step summary table names the skipped SHAs" || bad "the summary does not mention the skip"
chk "skipped heads are a loud warning, not a failure: exit 0" "$RC" 0
pubreset; set_default 8
set_pulls "1 2026-11-17T10:05:00Z 9"
for i in 8 9; do sweep_sha "$i" "$DONE"; done
sweep CI_GATE_SWEEP_MAX=2
grep -q '::warning::' <<<"$SOUT" && bad "a warning without an excess" || ok "at the cap exactly: no warning"
grep -qE 'CI_GATE_SWEEP_MAX:-100' "$ROOT/scripts/ci-gate-sweep.sh" && ok "the default cap is 100" || bad "the default cap is not 100"
pubreset; set_default 1
for i in $(seq 1 101); do printf '%s 2026-11-17T%02d:%02d:00Z %s\n' "$i" $((10 + i / 60)) $((i % 60)) "$((i + 1))"; done > "$WORK/many.txt"
mapfile -t MANY < "$WORK/many.txt"; set_pulls "${MANY[@]}"
snap 1 "$DONE"
sweep
chk "101 pull requests plus the default branch (102 SHAs): 100 are evaluated at the default cap" "$(cut -f3 "$FAKEGH/posts.log" | sort -u | grep -c .)" 100
grep -qE '^::warning::.*102 distinct head SHAs.*exceed the cap of 100; 2 .*NOT evaluated' <<<"$SOUT" && ok "the default-cap warning names 2 skipped" || bad "no default-cap warning"
chk "the oldest two pull requests are the ones skipped" "$(count_for 2)$(count_for 3)" 00

echo "-- one SHA's error does not stop the others; the sweep still exits non-zero --"
pubreset; set_pulls "1 2026-11-17T10:03:00Z 12" "2 2026-11-17T10:02:00Z 13" "3 2026-11-17T10:01:00Z 15"; set_default 14
for i in 12 13 14 15; do sweep_sha "$i" "$DONE"; done
touch "$FAKEGH/by/$(sha_n 13)/fail.1"
sweep
chk "the SHA whose runs could not be read gets a failure status" "$(last_for 13)" failure
chk "the SHAs before and after it are still evaluated (12, 14, 15 success)" "$(last_for 12) $(last_for 14) $(last_for 15)" "success success success"
chk "one SHA's API error: the sweep exits non-zero" "$RC" 1
grep -qF "| \`$(sha_n 13 | cut -c1-12)\` | PR #2 | error |" "$WORK/gss" && ok "the table marks it as an error" || bad "the table does not mark the error"
pubreset; set_pulls "1 $T1 12"; set_default 14
for i in 12 14; do sweep_sha "$i" "$DONE"; done
touch "$FAKEGH/failpulls"
sweep
chk "the pull request listing fails: the default branch head is still evaluated" "$(last_for 14)" success
chk "the pull request listing fails: exit non-zero and a loud error" "$RC/$(grep -c '^::error::ci-gate-sweep: could not list the open pull requests' <<<"$SOUT")" "1/1"
pubreset; set_pulls "1 $T1 12"; set_default 14
for i in 12 14; do sweep_sha "$i" "$DONE"; done
touch "$FAKEGH/faildefault"
sweep
chk "the default branch head is unreadable: the pull request is still evaluated" "$(last_for 12)" success
chk "the default branch head is unreadable: exit non-zero and a loud error" "$RC/$(grep -c '^::error::ci-gate-sweep: could not read the default branch head' <<<"$SOUT")" "1/1"
pubreset; set_pulls; set_default 14; sweep_sha 14 "$DONE"
sweep
chk "no open pull requests: only the default branch head, exit 0" "$(count_for 14)/$RC" "1/0"
pubreset; set_pulls "1 $T1 12"; set_default 14
sweep_sha 12 "$DONE" "$TESTFAIL"; sweep_sha 14 "$DONE" "$TESTFAIL"
sweep
chk "every SHA failing: both failure statuses are written, exit 1" "$(last_for 12) $(last_for 14)/$RC" "failure failure/1"
pubreset

echo "-- a sweep every 15 minutes must not re-post an unchanged status (1000-status cap), with a spaced context --"
pubreset; set_pulls "1 $T1 12"; set_default 13
sweep_sha 12 "$DONE"; sweep_sha 13 "$DONE"
sweep CONTEXT='CI / gate'
chk "first sweep, context 'CI / gate': two SHAs, two success POSTs" "$(grep -c . "$FAKEGH/posts.log")/$(cut -f1 "$FAKEGH/posts.log" | sort -u)/$RC" "2/success/0"
chk "first sweep: every status is under the context 'CI / gate'" "$(cut -f2 "$FAKEGH/status.log" | sort -u)" "CI / gate"
: > "$FAKEGH/posts.log"
sweep CONTEXT='CI / gate'
chk "second sweep, nothing changed: no POST at all" "$(grep -c . "$FAKEGH/posts.log" || true)" 0
chk "second sweep: both writes skipped and logged" "$(grep -c 'write skipped' <<<"$SOUT")" 2
chk "second sweep: both SHAs still reported success, exit 0" "$(grep -c '| success | all 3 required checks passed |' "$WORK/gss")/$RC" "2/0"
sweep_sha 12 "$DONE" "$TESTFAIL"; : > "$FAKEGH/posts.log"
sweep CONTEXT='CI / gate'
chk "third sweep, one head now failing: exactly that one is written" "$(cut -f1,3 "$FAKEGH/posts.log" | tr '\t' ' ')/$RC" "failure $(sha_n 12)/1"
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
w "$(p '{"job":"A","workflow":".github/workflows/a.yaml@refs/heads/x"}')"; v_bad "$WORK/p.json" example/repo "a .yaml workflow path with a ref suffix"
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
  jq -e '.checks | all(.[]; .job != "CI/gate" and .job != "CI / gate" and .job != "estate-gate")' "$f" >/dev/null \
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
  [ "$repo" = hyperpolymath/proven-cicd-and-workflows ] && continue   # the suite has no Empty-linter workflow
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
grep -q "event_name" "$WORKFLOW" && grep -q "workflow_run" "$WORKFLOW" && ok "ci-gate.yml checks the event" || bad "ci-gate.yml does not check the event"
REFUSE=$(sed -n "/- name: Refuse anything/,/- name: Mark a started/p" "$WORKFLOW")
grep -qE "workflow_run \| pull_request \| schedule \| workflow_dispatch\) ;;" <<<"$REFUSE" && grep -q "\*) echo .*exit 1 ;;" <<<"$REFUSE" \
  && ok "the refusal admits exactly workflow_run, pull_request, schedule and workflow_dispatch and fails on any other event" || bad "the event refusal is not workflow_run | schedule | workflow_dispatch only"
grep -qE "^      pull-requests: read" "$WORKFLOW" && ok "ci-gate.yml asks for pull-requests: read (the sweep lists open pull requests)" || bad "ci-gate.yml does not ask for pull-requests: read"
grep -q "fetch scripts/ci-gate-sweep.sh" "$WORKFLOW" && grep -q "scripts/ci-gate-sweep.sh" <(sed -n "/- name: Evaluate the commit/,/- name: Publish a failure/p" "$WORKFLOW") \
  && ok "ci-gate.yml fetches the sweep script and runs it for events other than workflow_run" || bad "ci-gate.yml does not fetch or run the sweep script"
grep -q "fetch scripts/ci-gate-publish.sh" "$WORKFLOW" && ok "ci-gate.yml fetches the publisher from the suite" || bad "ci-gate.yml does not fetch ci-gate-publish.sh"
! grep -qE '^[[:space:]]*gh api -X POST' <(sed -n '/- name: Evaluate the commit/,/- name: Publish a failure/p' "$WORKFLOW") && ok "the evaluate step publishes only through the script" || bad "the evaluate step posts a status itself"
grep -qE '^  gate:' "$WORKFLOW" && ok "job id is gate" || bad "job id is not gate"
grep -qE 'default: *"?CI/gate"?' "$WORKFLOW" && ok "context input defaults to CI/gate" || bad "context default is not CI/gate"
grep -qE 'default: *180' "$WORKFLOW" && ok "timeout_minutes defaults to 180" || bad "timeout_minutes default is not 180"
# Template: workflow_run main path; pull_request only as the permanent gate-pr job (pr_start_ok).
tpl_code() { grep -vE '^[[:space:]]*#' "$1"; }
# A pull_request trigger is allowed ONLY together with a same-repo-only gate-pr job
# and a main job that does not also run on pull_request. pr_start_ok <code-lines-fn> <file>
pr_start_ok() {
  local code=$1 file=$2
  "$code" "$file" | grep -qE '^  pull_request:' || return 1
  "$code" "$file" | grep -qE "^    if: github.event_name != 'pull_request' && \(github.event_name != 'workflow_run' \|\| github.event.workflow_run.name != 'CI gate'\)" || return 1
  "$code" "$file" | grep -qE "^    if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository$" || return 1
  "$code" "$file" | grep -qE '^  gate-pr:' || return 1
  grep -q 'permanent\|The pull_request start' "$file" || return 1
  ! "$code" "$file" | grep -qE 'pull_request_target|actions/checkout|github\.actor|actor\.login' || return 1
}
pr_start_ok tpl_code "$TEMPLATE" && ok "template: pull_request appears only as the gate-pr job (same-repo gate-pr job, main job excludes pull_request, no actor test)" || bad "template: the gate-pr shape is wrong"
tpl_code "$FX/bad-template.yml" | grep -q 'pull_request' && ok "control: the template check sees a pull_request trigger" || bad "control: the template check missed pull_request"
tpl_code "$TEMPLATE" | grep -qE '^[[:space:]]*concurrency:' && bad "template has a concurrency block" || ok "template has no concurrency block"
tpl_code "$FX/bad-template.yml" | grep -qE '^[[:space:]]*concurrency:' && ok "control: the concurrency check sees a planted block" || bad "control: no concurrency block in bad-template.yml"
tpl_code "$TEMPLATE" | grep -qE '^  workflow_run:' && ok "template triggers on workflow_run" || bad "template does not trigger on workflow_run"
tpl_code "$TEMPLATE" | grep -qE '^    types: \[[^]]*\bcompleted\b[^]]*\]' && tpl_code "$TEMPLATE" | grep -qE '^    types: \[[^]]*\bin_progress\b[^]]*\]' \
  && ok "template triggers on workflow_run types completed and in_progress" || bad "template types lack completed or in_progress"
tpl_code "$TEMPLATE" | grep -qE 'uses: hyperpolymath/proven-cicd-and-workflows/\.github/workflows/ci-gate\.yml@__CICD_SUITE_SHA__' \
  && ok "template calls the reusable at the __CICD_SUITE_SHA__ placeholder" || bad "template does not call the reusable at the placeholder"
tpl_code "$TEMPLATE" | grep -qE '^  schedule:' && tpl_code "$TEMPLATE" | grep -qE '^    - cron: ' && ok "template has the schedule trigger" || bad "template has no schedule trigger"
tpl_code "$TEMPLATE" | grep -qE '^  workflow_dispatch:' && ok "template has the workflow_dispatch trigger" || bad "template has no workflow_dispatch trigger"
tpl_code "$TEMPLATE" | grep -qE '^  pull-requests: read' && ok "template grants pull-requests: read" || bad "template does not grant pull-requests: read"
tpl_code "$TEMPLATE" | grep -qE "^    if: github.event_name != 'pull_request' && \(github.event_name != 'workflow_run' \|\| github.event.workflow_run.name != 'CI gate'\)" && ok "template excludes the gate's own workflow_run events and pull_request from the main job" || bad "template main job if: is wrong"
tpl_code "$TEMPLATE" | grep -qE '^  gate:' && ok "template job id is gate" || bad "template job id is not gate"
tpl_code "$TEMPLATE" | grep -qE 'context: *"CI/gate"' && ok "template publishes CI/gate" || bad "template does not publish CI/gate"

echo "== the suite gates itself (dogfood) =="
SELF="$ROOT/.github/workflows/ci-gate-caller.yml"
SELFPROFILE="$ROOT/profiles/ci-gate/hyperpolymath/proven-cicd-and-workflows.json"
[ -f "$SELF" ] && ok "the suite's own caller exists" || bad "the suite's own caller is missing"
self_code() { grep -vE '^[[:space:]]*#' "$SELF"; }
self_code | grep -qE '^name: CI gate$' && ok "its workflow name is CI gate (the gate's own runs are excluded by this name)" || bad "its workflow name is not CI gate"
self_code | grep -qE '^    uses: \./\.github/workflows/ci-gate\.yml$' && ok "it calls the local reusable, so the gate runs at the suite's own default-branch commit" || bad "it does not call ./.github/workflows/ci-gate.yml"
self_code | grep -qE 'context: *"CI / gate"' && ok "it publishes the context the suite's main ruleset requires (CI / gate)" || bad "it does not publish CI / gate"
self_code | grep -qE '^  gate:' && ok "its job id is gate" || bad "its job id is not gate"
pr_start_ok self_code "$SELF" && ok "the suite's caller: pull_request appears only as the gate-pr job" || bad "the suite's caller: the gate-pr shape is wrong"
self_code | grep -qE '^[[:space:]]*concurrency:' && bad "the suite's caller has a concurrency block" || ok "the suite's caller has no concurrency block"
self_code | grep -qE '^    types: \[[^]]*\bcompleted\b[^]]*\]' && self_code | grep -qE '^    types: \[[^]]*\bin_progress\b[^]]*\]' && self_code | grep -qE '^  schedule:' && self_code | grep -qE '^  workflow_dispatch:' \
  && ok "it has workflow_run (completed, in_progress), schedule and workflow_dispatch" || bad "its triggers are not the caller shape"
self_code | grep -qE '^  pull-requests: read' && self_code | grep -qE '^  statuses: write' && self_code | grep -qE '^  actions: read' && self_code | grep -qE '^  contents: read' \
  && ok "it grants statuses: write, actions: read, contents: read, pull-requests: read" || bad "its permissions are not the caller shape"
! grep -qE '^[[:space:]]*secrets:' "$SELF" && ok "the suite's caller has no secrets: line" || bad "the suite's caller has a secrets: line"
[ "$(jq -r .repository "$SELFPROFILE")" = hyperpolymath/proven-cicd-and-workflows ] && ok "the suite's profile names the suite" || bad "the suite's profile names another repository"
bash "$VALIDATE" "$SELFPROFILE" hyperpolymath/proven-cicd-and-workflows "CI / gate" >/dev/null 2>&1 && ok "the suite's profile validates with the caller's context CI / gate forbidden" || bad "the suite's profile does not validate"
w "$(p "$(e A a.yml),$(e 'CI / gate' b.yml)")"
bash "$VALIDATE" "$WORK/p.json" example/repo "CI / gate" >/dev/null 2>&1 && bad "accepted a job named CI / gate" || ok "rejected a job named CI / gate when that is the caller's context"
jq -e '[.checks[].workflow] | all(.[]; . != ".github/workflows/ci-gate.yml" and . != ".github/workflows/ci-gate-caller.yml")' "$SELFPROFILE" >/dev/null \
  && ok "the suite's profile requires neither the reusable nor the caller (the gate cannot wait for itself)" || bad "the suite's profile requires the gate's own workflow"
for wf in $(jq -r '.checks[].workflow' "$SELFPROFILE" | sort -u); do
  [ -f "$ROOT/$wf" ] && ok "the suite's profile names an existing workflow $wf" || bad "the suite's profile names a missing workflow $wf"
done

echo
printf 'ci-gate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
