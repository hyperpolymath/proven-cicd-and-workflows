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

echo "== the REST layer is the text of the workflow's own step =="
# Every read and every status goes through scripts/ci-gate-api.sh, written byte for byte by the "Write the
# REST layer" step. The tests extract that heredoc from ci-gate.yml and source it, so they drive the shipped
# text, not a copy, and fail when the two texts differ.
awk '/<<.CI_GATE_STATUS_EOF.$/{f=1;next} /^ *CI_GATE_STATUS_EOF$/{f=0} f' "$WORKFLOW" | sed 's/^          //' > "$WORK/status-lib.sh"
export CI_GATE_STATUS_LIB="$WORK/status-lib.sh"
grep -q '^post_status()' "$CI_GATE_STATUS_LIB" && bash -n "$CI_GATE_STATUS_LIB" \
  && ok "extracted the REST layer from ci-gate.yml (it parses and defines post_status)" || bad "could not extract the REST layer"
cmp -s "$CI_GATE_STATUS_LIB" "$ROOT/scripts/ci-gate-api.sh" \
  && ok "the workflow step's text is scripts/ci-gate-api.sh byte for byte" \
  || bad "the workflow step and scripts/ci-gate-api.sh differ (copy the file into the step, indented 10 spaces)"

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
# `gh api -i` (the REST layer, scripts/ci-gate-api.sh): re-invoke this stub without -i to get the items,
# then answer like GitHub: status line, Etag, Link rel="next" for more pages, X-RateLimit-*, a blank
# line, the page body. If-None-Match equal to the Etag answers 304 (gh exits 1). The file `limits`
# injects rate limits, one line per request until empty: primary | secondary | retry429 | perm403
# (by/<sha>/limits: the same, for the run-list reads of that commit only).
# Every -i request is logged to requests.log as "<code> <method> <path>".
if [[ " $* " == *" -i "* ]]; then
  a=() inm='' method=GET path='' prev=''
  for x in "$@"; do
    if [[ $prev == -H && $x == If-None-Match:* ]]; then inm=${x#If-None-Match: }; unset 'a[${#a[@]}-1]'; prev=''; continue; fi
    if [[ $prev == -X ]]; then method=$x; [[ $x == GET ]] && unset 'a[${#a[@]}-1]' || a+=("$x"); prev=''; continue; fi
    [[ $x == -i ]] && { prev=$x; continue; }
    [[ $x == repos/* ]] && path=$x
    a+=("$x"); prev=$x
  done
  log() { echo "$1 $method $path" >> "$D/requests.log"; }
  lf=$D/limits   # by/<sha>/limits applies to the run-list reads of that one commit (the sweep reads many)
  [[ $path =~ head_sha=([0-9a-f]{40}) && -s $D/by/${BASH_REMATCH[1]}/limits ]] && lf=$D/by/${BASH_REMATCH[1]}/limits
  if [[ -s $lf ]]; then
    kind=$(head -n 1 "$lf"); sed -i 1d "$lf"
    case $kind in
      primary)  log 403; printf 'HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: %s\r\n\r\n{"message":"API rate limit exceeded for installation ID 1."}\n' "$(( $(cat "$D/clock" 2>/dev/null || echo 0) + ${LIMIT_RESET_IN:-30} ))"; echo "gh: API rate limit exceeded for installation ID 1. (HTTP 403)" >&2; exit 1 ;;
      secondary) log 403; printf 'HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Remaining: 4000\r\n\r\n{"message":"You have exceeded a secondary rate limit."}\n'; echo "gh: You have exceeded a secondary rate limit. (HTTP 403)" >&2; exit 1 ;;
      retry429) log 429; printf 'HTTP/2.0 429 Too Many Requests\r\nRetry-After: 7\r\n\r\n{"message":"slow down"}\n'; echo "gh: HTTP 429" >&2; exit 1 ;;
      perm403)  log 403; printf 'HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Remaining: 4000\r\n\r\n{"message":"Resource not accessible by integration"}\n'; echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1 ;;
    esac
  fi
  if [[ $method == POST ]]; then
    out=$("$0" api -X POST "${a[@]:1}" 2> "$D/inner.err"); rc=$?; err=$(cat "$D/inner.err")
    if ((rc == 0)); then log 201; printf 'HTTP/2.0 201 Created\r\n\r\n{}\n'; exit 0; fi
    if [[ $out == HTTP/* ]]; then   # an injected rate limit (the `ratelimit` file): relay GitHub's answer as it is
      log "$(awk 'NR == 1 { print $2 }' <<< "$out")"; printf '%s\n' "$out"; echo "$err" >&2; exit 1
    fi
    code=500; [[ $err == *"HTTP 422"* ]] && code=422
    log "$code"; printf 'HTTP/2.0 %s Error\r\n\r\n{"message":"%s"}\n' "$code" "${err//\"/}"; echo "$err" >&2; exit 1
  fi
  page=1; [[ $path =~ [\&?]page=([0-9]+) ]] && page=${BASH_REMATCH[1]}
  base=${path%&page=*}; per=100; [[ $base =~ per_page=([0-9]+) ]] && per=${BASH_REMATCH[1]}
  case $base in
    *"actions/runs?head_sha"*) key=workflow_runs ;;
    *"/jobs?filter=latest"*)   key=jobs ;;
    *"/status?per_page"*)      key=statuses ;;
    *) key='' ;;
  esac
  items=$("$0" api --paginate "$base" --jq ".${key:-x}[]" 2> "$D/inner.err"); rc=$?
  if ((rc != 0)) || [[ -z $key ]]; then log 500; printf 'HTTP/2.0 500 Internal Server Error\r\n\r\n{}\n'; cat "$D/inner.err" >&2; exit 1; fi
  if ! arr=$(jq -sc '.' <<< "$items" 2>/dev/null); then
    log 200; printf 'HTTP/2.0 200 OK\r\n\r\n%s\n' "$items"; exit 0   # malformed data passes through
  fi
  n=$(jq length <<< "$arr")
  body=$(jq -c --arg k "$key" --argjson o $(( (page - 1) * per )) --argjson p "$per" '{($k): .[$o:$o + $p], total_count: length}' <<< "$arr")
  etag="\"$(printf '%s' "$body" | sha1sum | cut -c1-40)\""
  more=''; (( page * per < n )) && more="Link: <https://api.github.com/$base&page=$((page + 1))>; rel=\"next\""$'\r\n'
  if [[ -n $inm && $inm == "$etag" ]]; then log 304; printf 'HTTP/2.0 304 Not Modified\r\nEtag: %s\r\n%s\r\n' "$etag" "$more"; echo "gh: HTTP 304" >&2; exit 1; fi
  log 200; printf 'HTTP/2.0 200 OK\r\nEtag: %s\r\n%sX-Ratelimit-Remaining: 4999\r\n\r\n%s\n' "$etag" "$more" "$body"; exit 0
fi
if [[ ${CLOCK_API_COST:-0} != 0 ]]; then
  echo "$(( $(cat "$D/clock") + CLOCK_API_COST ))" > "$D/clock"
fi
if [[ " $* " == *" -X POST "* ]]; then
  state=''; desc=''; psha=''; ctx=''
  for a in "$@"; do case $a in state=*) state=${a#state=} ;; description=*) desc=${a#description=} ;; context=*) ctx=${a#context=} ;; repos/*/statuses/*) psha=${a##*/} ;; esac; done
  echo "$state" >> "$D/attempts.log"
  # ratelimit: each line answers one POST as GitHub does under a rate limit, "<code reason>|<header>|...",
  # with the headers on stdout (gh -i prints them for an error too) and gh's error line on stderr.
  if [[ -s $D/ratelimit ]]; then
    IFS='|' read -r -a h < "$D/ratelimit"; sed -i 1d "$D/ratelimit"
    printf 'HTTP/2.0 %s\r\n' "${h[0]}"; for x in "${h[@]:1}"; do printf '%s\r\n' "$x"; done
    printf '\r\n{"message":"%s"}\n' "${RL_MESSAGE:-API rate limit exceeded for installation ID 1.}"
    echo "gh: ${RL_MESSAGE:-API rate limit exceeded for installation ID 1.} (HTTP ${h[0]%% *})" >&2; exit 1
  fi
  [[ ! -f $D/failpost ]] || { echo "gh: HTTP 500 (post)" >&2; exit 1; }
  # GitHub's statuses API refuses a description with a character outside the BMP (an emoji is one):
  # HTTP 422, "Description doesn't accept 4-byte Unicode".
  if [[ $(printf '%s' "$desc" | jq -Rr '[explode[] | select(. > 65535)] | length') != 0 ]]; then
    echo "gh: Validation failed: Description doesn't accept 4-byte Unicode (HTTP 422)" >&2; exit 1
  fi
  # a newer evaluator's write that lands just before this one (deterministic pause control)
  if [[ -f $D/prepost ]]; then
    cat "$D/prepost" >> "$D/posts.log"
    awk -F'\t' -v s="$psha" -v c="$ctx" '{print s "\t" c "\t" $1 "\t" $2}' "$D/prepost" >> "$D/status.log"; rm -f "$D/prepost"
  fi
  printf '%s\t%s\t%s\n' "$state" "$desc" "$psha" >> "$D/posts.log"
  printf '%s\t%s\t%s\t%s\n' "$psha" "$ctx" "$state" "$desc" >> "$D/status.log"
  printf 'HTTP/2.0 201 Created\r\n\r\n{}\n'; exit 0
fi
args="$*"
jqarg='' ; prev=''
for a in "$@"; do [[ $prev == --jq ]] && jqarg=$a; prev=$a; done
case $args in
  *"api rate_limit"*) [[ -z ${QUOTA_FAIL:-} ]] || { echo "gh: HTTP 500 (rate)" >&2; exit 1; }; printf '%s\t%s\n' "${QUOTA_REMAINING:-500000}" "${QUOTA_RESET:-3600}" ;;
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
    echo "$id" >> "$D/jobs.calls"
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
pubreset() { rm -rf "$FAKEGH/by" "$FAKEGH/cursha" "$FAKEGH/pulls.json" "$FAKEGH/default_branch" "$FAKEGH/default_sha" "$FAKEGH/failpulls" "$FAKEGH/faildefault"; rm -f "$FAKEGH"/runs.*.json "$FAKEGH/prepost" "$FAKEGH"/fail.* "$FAKEGH"/failjobs "$FAKEGH"/failpost "$FAKEGH/posts.log" "$FAKEGH/runs.count" "$FAKEGH/status.log" "$FAKEGH/status.reads" "$FAKEGH/failstatus" "$FAKEGH/badstatus" "$FAKEGH/ratelimit" "$FAKEGH/attempts.log" "$FAKEGH/rl.sleeps" "$WORK/gho"; cp "$FX/jobs.json" "$FAKEGH/jobs.json"; }
publish() { # [VAR=value ...] -> RC, NPOSTS, POSTS (state<TAB>description lines), CALLS (runs fetches)
  : > "$FAKEGH/jobs.calls"
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
echo "-- completed jobs cache and quota backoff --"
pubreset; snap 1 "$RERUN"; publish "${WAITENV[@]}"
chk "completed run jobs fetched once across polls" "$(grep -c '^11$' "$FAKEGH/jobs.calls")" 1
chk "active run jobs fetched each poll" "$(grep -c '^12$' "$FAKEGH/jobs.calls")" 4
pubreset; snap 1 "$NOQ"; snap 2 "$NOQ | map(if .id == 11 then .run_attempt = 2 else . end)"; publish "${WAITENV[@]}"
chk "attempt change invalidates completed jobs" "$(grep -c '^11$' "$FAKEGH/jobs.calls")" 2
pubreset; snap 1 "$NOQ"; snap 2 "$NOQ | map(if .id == 11 then .updated_at = \"2026-11-17T11:00:00Z\" else . end)"; publish "${WAITENV[@]}"
chk "fingerprint change invalidates completed jobs" "$(grep -c '^11$' "$FAKEGH/jobs.calls")" 2
pubreset; snap 1 "$NOQ"; publish "${WAITENV[@]}" QUOTA_REMAINING=25
chk "low quota backs off to deadline and fails closed" "$(paste -sd, "$FAKEGH/sleeps")/$RC/$(post_n 1 | cut -f1)" "30/1/failure"
pubreset; snap 1 "$NOQ"; snap 2 "$DONE"; publish "${WAITENV[@]}" WAIT_SECONDS=120 QUOTA_REMAINING=5 QUOTA_RESET=15
chk "low quota that resets inside the wait: sleeps to the reset (15 s, not the 10 s poll), then continues to success" "$(paste -sd, "$FAKEGH/sleeps")/$RC/$(post_n 1 | cut -f1)" "15/0/success"
pubreset; snap 1 "$NOQ"; publish "${WAITENV[@]}" QUOTA_FAIL=1
chk "an unreadable rate limit fails closed (failure, exit 1, no polling)" "$RC/$(post_n 1 | cut -f1)/$(wc -l < "$FAKEGH/sleeps")" "1/failure/0"
EXTRA='. + [range(100;118) | r(.; "Extra \(.)"; (. + 1000); "pull_request"; "completed"; "2026-11-17T10:00:00Z")]'
pubreset; snap 1 "$DEFS map(select(.name != \"CI quality\")) | $EXTRA"; publish "${WAITENV[@]}" WAIT_SECONDS=480
chk "20 kept runs over 48 polls: each completed run's jobs are read once (20 requests, not 960)" "$(grep -c . "$FAKEGH/jobs.calls")" 20
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
L_REFUSE=$(step_line 'Refuse anything'); L_PEND=$(step_line 'Mark a started or re-run'); L_READ=$(step_line 'Read the profile'); L_QS=$(step_line 'Let a burst')
{ [ -n "$L_REFUSE" ] && [ -n "$L_PEND" ] && [ -n "$L_READ" ] && [ "$L_REFUSE" -lt "$L_PEND" ] && [ "$L_PEND" -lt "$L_READ" ]; } \
  && ok "step order: input validation, then the early pending, then the profile fetch" || bad "step order is wrong ($L_REFUSE, $L_PEND, $L_READ)"
EARLY=$(sed -n "${L_PEND},$((L_QS - 1))p" "$WORKFLOW")
grep -q 'EVENT_ACTION' <<<"$EARLY" && grep -q 'in_progress' <<<"$EARLY" && grep -q 'post_status pending' <<<"$EARLY" && grep -q 're-run started' <<<"$EARLY" \
  && ok "the early step posts pending 're-run started' for an in_progress action" || bad "the early step lacks the in_progress pending"
! grep -qE '\$suite|fetch |scripts/' <<<"$EARLY" && ok "the early step reads no suite file" || bad "the early step touches the suite"
! grep -q '\${{' <(awk '/^        run: \|/{f=1;next} f' <<<"$EARLY") && ok "the early step has no \${{ }} inside its run: script" || bad "the early step interpolates into run:"

echo "-- a description never carries a character outside the BMP (GitHub answers 422 to one) --"
pubreset; reset
jq -n '[{id:7001,name:"🔴 GATE: Invisible Character Detection",status:"completed",conclusion:"failure",run:{id:11,name:"🔴 GATE: Invisible Character Detection",status:"completed"}}]' > "$FAKEGH/jobs.json"
jq -n '{checks:[{job:"🔴 GATE: Invisible Character Detection",workflow:".github/workflows/ci-build.yml"}],repository:"example/repo",schema_version:2}' > "$SUITE_DIR/profiles/ci-gate/example/repo.json"
snap 1 "$DONE"; publish
chk "a failing job with an emoji in its name: the status is published, not refused" "$RC/$(post_n 1 | cut -f1)" "1/failure"
chk "the published description names the check and carries no 4-byte character" "$(post_n 1 | cut -f2 | jq -Rr '[explode[] | select(. > 65535)] | length')/$(post_n 1 | cut -f2 | grep -c 'GATE: Invisible Character Detection')" "0/1"
chk "no 'NO VERDICT WAS PRODUCED' for it" "$(grep -c 'NO VERDICT WAS PRODUCED' <<<"$PUBOUT")" 0
cp "$FX/profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"
pubreset
echo "-- the early pending step does the same with the run's name --"
awk '/^        run: \|/{f=1;next} f' <<<"$EARLY" | sed 's/^          //' > "$WORK/early.sh"
EARLYOUT=$(env PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" EVENT_NAME=workflow_run EVENT_ACTION=in_progress RUN_NAME='🔴 GATE: Invisible Character Detection' \
  REPO=example/repo HEAD_SHA="$SHA" CONTEXT=CI/gate SERVER_URL=https://github.com RUN_ID=1 bash "$WORK/early.sh" 2>&1); ERC=$?
chk "an emoji in the run name: the early pending is published" "$ERC/$(sed -n 1p "$FAKEGH/posts.log" | cut -f1)" "0/pending"
chk "its description keeps the readable part and has no 4-byte character" "$(sed -n 1p "$FAKEGH/posts.log" | cut -f2 | jq -Rr '[explode[] | select(. > 65535)] | length')/$(sed -n 1p "$FAKEGH/posts.log" | cut -f2 | grep -c 'GATE: Invisible Character Detection')" "0/1"
pubreset

echo "== status writer: rate limits, retries and the duplicate skip, through the workflow's own steps =="
RL="$WORK/rl"; mkdir -p "$RL"
printf '#!/usr/bin/env bash\necho 1800000000\n' > "$RL/clock"                          # a fixed wall clock
printf '#!/usr/bin/env bash\necho "$1" >> "$FAKEGH_DIR/rl.sleeps"\n' > "$RL/sleep"     # records, never sleeps
chmod +x "$RL/clock" "$RL/sleep"
RLENV=(PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" CI_GATE_CLOCK="$RL/clock" CI_GATE_SLEEP="$RL/sleep")
step_text() { # <step name prefix> -> that step's run: block, de-indented
  awk -v name="$1" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    inrun { if ($0 ~ /^[[:space:]]*$/ || ind($0) > runcol) { print substr($0, runcol + 3); next } exit }
    index($0, "- name: " name) { want = 1; next }
    want && $0 ~ /^[[:space:]]+run: [|]$/ { runcol = ind($0); inrun = 1 }
  ' "$WORKFLOW"
}
step_text "Publish a failure status when no verdict" > "$WORK/fallback.sh"
grep -q post_status "$WORK/fallback.sh" && ok "extracted the failure fallback step (it writes through post_status)" || bad "could not extract the failure fallback step"
grep -q post_status "$WORK/early.sh" && ok "the early pending step writes through post_status" || bad "the early pending step does not use post_status"
early() { # [VAR=value ...] -> RC, EOUT; the workflow's early pending step for an in_progress run
  EOUT=$(env "${RLENV[@]}" API_CACHE="$(mktemp -d "$WORK/cache.XXXXXX")" EVENT_NAME=workflow_run EVENT_ACTION=in_progress RUN_NAME=CI \
    REPO=example/repo HEAD_SHA="$SHA" CONTEXT=CI/gate SERVER_URL=https://github.com RUN_ID=1 "$@" bash "$WORK/early.sh" 2>&1); RC=$?
}
fallback() { # [VAR=value ...] -> RC, EOUT; the workflow's failure fallback step
  EOUT=$(env "${RLENV[@]}" API_CACHE="$(mktemp -d "$WORK/cache.XXXXXX")" EVENT_NAME=workflow_run REPO=example/repo HEAD_SHA="$SHA" CONTEXT=CI/gate \
    SERVER_URL=https://github.com RUN_ID=1 "$@" bash "$WORK/fallback.sh" 2>&1); RC=$?
}
attempts() { grep -c . "$FAKEGH/attempts.log" 2>/dev/null || echo 0; }
sleeps() { paste -sd' ' "$FAKEGH/rl.sleeps" 2>/dev/null; }
RESET_SOON='403 Forbidden|X-Ratelimit-Limit: 5000|X-Ratelimit-Remaining: 0|X-Ratelimit-Reset: 1800000007'
RESET_LATE='403 Forbidden|X-Ratelimit-Remaining: 0|X-Ratelimit-Reset: 1800003600'
RETRY_3='429 Too Many Requests|Retry-After: 3'

echo "-- silence: no rate limit, no retry --"
pubreset; early
chk "control: the early pending posts once, with no wait and no rate-limit line" "$RC/$(attempts)/$(sleeps)/$(grep -c 'rate limited' <<<"$EOUT")" "0/1//0"
chk "control: the pending stands with the run's name" "$(cut -f1,2 "$FAKEGH/posts.log")" "$(printf 'pending\tre-run started: CI')"

echo "-- firing: rate limited, then written --"
pubreset; printf '%s\n' "$RESET_SOON" "$RETRY_3" > "$FAKEGH/ratelimit"; early
chk "403 quota spent, then 429 Retry-After 3, then accepted: exit 0, 3 attempts, one status" "$RC/$(attempts)/$(grep -c . "$FAKEGH/posts.log")" "0/3/1"
chk "it waited for x-ratelimit-reset (7 s + 1), then for Retry-After (3 s)" "$(sleeps)" "8 3"
chk "each retry is logged with its wait" "$(grep -c 'rate limited (HTTP' <<<"$EOUT")" 2
pubreset; printf '%s\n' '403 Forbidden' '403 Forbidden' > "$FAKEGH/ratelimit"
early RL_MESSAGE='You have exceeded a secondary rate limit. Please wait a few minutes before you try again.'
read -r s1 s2 <<<"$(sleeps)"
chk "a secondary rate limit with no headers: exit 0 after 3 attempts" "$RC/$(attempts)" "0/3"
{ ((s1 >= 60 && s1 <= 90 && s2 >= 120 && s2 <= 180)); } && ok "no headers: backoff starts at a minute, doubles, with jitter (${s1}s in 60..90, ${s2}s in 120..180)" || bad "backoff out of range: '$(sleeps)'"

echo "-- firing: rate limited to exhaustion --"
pubreset; for _ in 1 2 3 4 5 6; do echo "$RETRY_3"; done > "$FAKEGH/ratelimit"; early
chk "rate limited every time: exit 1 after exactly 5 attempts and 4 waits" "$RC/$(attempts)/$(sleeps)" "1/5/3 3 3 3"
chk "it fails with 'rate limited, no verdict' and writes no status" "$(grep -c '::error::rate limited, no verdict' <<<"$EOUT")/$([ -s "$FAKEGH/posts.log" ] && echo posted || echo none)" "1/none"
chk "the exhausted step does not also claim a generic publish error" "$(grep -c 'could not publish the re-run pending' <<<"$EOUT")" 0
pubreset; echo "$RESET_LATE" > "$FAKEGH/ratelimit"; early
chk "quota reset an hour away (over the 300 s budget): one attempt, no wait, rate limited, no verdict" "$RC/$(attempts)/$(sleeps)/$(grep -c 'rate limited, no verdict' <<<"$EOUT")" "1/1//1"
pubreset; for _ in 1 2 3; do echo '429 Too Many Requests|Retry-After: 120'; done > "$FAKEGH/ratelimit"; early
chk "Retry-After 120 twice fits 300 s, a third would not: 3 attempts, waits 120 120" "$RC/$(attempts)/$(sleeps)" "1/3/120 120"

echo "-- not a rate limit: no retry --"
pubreset; touch "$FAKEGH/failpost"; early
chk "an HTTP 500 is not retried: exit 1, one attempt, the generic error" "$RC/$(attempts)/$(sleeps)/$(grep -c 'could not publish the re-run pending status' <<<"$EOUT")" "1/1//1"
pubreset; echo '403 Forbidden|X-Ratelimit-Remaining: 4999' > "$FAKEGH/ratelimit"; early RL_MESSAGE='Resource not accessible by integration'
chk "a 403 that is not a rate limit (permissions) is not retried" "$RC/$(attempts)/$(sleeps)" "1/1/"

echo "-- duplicate writes skipped, new states written --"
pubreset; printf '%s\tCI/gate\tpending\tre-run started: CI\n' "$SHA" > "$FAKEGH/status.log"; early
chk "the same pending already stands: no POST, 'write skipped', exit 0" "$RC/$(attempts)/$(grep -c 'write skipped' <<<"$EOUT")" "0/0/1"
pubreset; printf '%s\tCI/gate\tsuccess\tall 3 required checks passed\n' "$SHA" > "$FAKEGH/status.log"; early
chk "a success stands: the new pending is written over it" "$RC/$(attempts)/$(cut -f1 "$FAKEGH/posts.log")" "0/1/pending"
pubreset; printf '%s\tCI/gate\tpending\tre-run started: Lint\n' "$SHA" > "$FAKEGH/status.log"; early
chk "a pending with another description: written" "$RC/$(attempts)" "0/1"
pubreset; printf '%s\tCI / gate\tpending\tre-run started: CI\n' "$SHA" > "$FAKEGH/status.log"; early
chk "the same pending under another context: written" "$RC/$(attempts)" "0/1"
pubreset; touch "$FAKEGH/failstatus"; printf '%s\tCI/gate\tpending\tre-run started: CI\n' "$SHA" > "$FAKEGH/status.log"; early
chk "the current status cannot be read: written anyway (toward writing, never silence)" "$RC/$(attempts)" "0/1"

echo "-- the failure fallback step --"
FB='ci-gate could not produce a verdict (profile or API error); see the run'
pubreset; printf '%s\n' "$RETRY_3" > "$FAKEGH/ratelimit"; fallback
chk "fallback: rate limited once, then the failure is written" "$RC/$(attempts)/$(sleeps)/$(cut -f1 "$FAKEGH/posts.log")" "0/2/3/failure"
pubreset; printf '%s\tCI/gate\tfailure\t%s\n' "$SHA" "$FB" > "$FAKEGH/status.log"; fallback
chk "fallback: the same failure already stands: skipped" "$RC/$(attempts)/$(grep -c 'write skipped' <<<"$EOUT")" "0/0/1"
pubreset; for _ in 1 2 3 4 5; do echo "$RETRY_3"; done > "$FAKEGH/ratelimit"; fallback
chk "fallback: exhausted, it warns and the step still ends" "$RC/$(attempts)/$(grep -c 'could not publish the failure status either' <<<"$EOUT")/$(grep -c 'rate limited, no verdict' <<<"$EOUT")" "0/5/1/1"
pubreset; fallback EVENT_NAME=schedule
chk "fallback: a sweep event writes nothing" "$RC/$(attempts)" "0/0"

echo "-- the publisher (verdict writes) --"
pubreset; snap 1 "$DONE"; printf '%s\n' "$RETRY_3" > "$FAKEGH/ratelimit"; : > "$FAKEGH/rl.sleeps"
publish CI_GATE_CLOCK="$RL/clock" CI_GATE_SLEEP="$RL/sleep"
chk "publisher: rate limited once, then the verdict is written: exit 0, success" "$RC/$NPOSTS/$(post_n 1 | cut -f1)/$(sleeps)" "0/1/success/3"
grep -qx 'published=true' "$WORK/gho" && ok "publisher: published=true after the retried write" || bad "publisher: no published=true"
pubreset; snap 1 "$DONE"; for _ in $(seq 10); do echo "$RETRY_3"; done > "$FAKEGH/ratelimit"; : > "$FAKEGH/rl.sleeps"
publish CI_GATE_CLOCK="$RL/clock" CI_GATE_SLEEP="$RL/sleep"
chk "publisher exhausted: exit 1, 'rate limited, no verdict', nothing written" "$RC/$NPOSTS/$(grep -c 'rate limited, no verdict' <<<"$PUBOUT")" "1/0/1"
chk "publisher exhausted: die() makes no further failure attempt (5 attempts, all the verdict)" "$(attempts)/$(sort -u "$FAKEGH/attempts.log")" "5/success"
[ ! -s "$WORK/gho" ] && ok "publisher exhausted: no published=true, so the fallback step runs" || bad "publisher exhausted but claimed published"
pubreset; snap 1 "$DONE"; publish CI_GATE_STATUS_LIB="$WORK/nonexistent"
chk "publisher without the REST layer: refused, nothing read or written" "$RC/$NPOSTS/$CALLS/$(grep -c 'REST layer' <<<"$PUBOUT")" "1/0/0/1"

echo "-- static: the writer step, the concurrency block --"
step_line2() { grep -n -- "- name: $1" "$WORKFLOW" | head -1 | cut -d: -f1; }
L_W=$(step_line2 'Write the REST layer')
{ [ -n "$L_W" ] && [ "$L_W" -gt "$L_REFUSE" ] && [ "$L_W" -lt "$L_PEND" ]; } && ok "the writer step sits between input validation and the early pending" || bad "the writer step is misplaced ($L_W)"
WSTEP=$(sed -n "${L_W},$((L_PEND - 1))p" "$WORKFLOW")
! sed '/<<.CI_GATE_STATUS_EOF.$/,/^ *CI_GATE_STATUS_EOF$/d; /^ *#/d' <<<"$WSTEP" | grep -qE '\$suite|fetch |scripts/' && ok "the REST layer step reads no suite file" || bad "the REST layer step touches the suite"
OUTSIDE=$( { sed -n "1,$((L_W - 1))p" "$WORKFLOW"; sed -n "${L_PEND},\$p" "$WORKFLOW"; } | grep 'gh api')
[ "$(grep -c . <<<"$OUTSIDE")" = 1 ] && grep -q 'contents/' <<<"$OUTSIDE" \
  && ok "outside the writer, ci-gate.yml calls gh api only to fetch suite files" || bad "ci-gate.yml calls gh api outside the writer: $OUTSIDE"
! grep -qE '^[[:space:]]*gh api -X POST' "$WORKFLOW" && ok "no bare status POST remains in ci-gate.yml" || bad "a bare status POST remains"
! grep -q 'gh api -X POST' "$ROOT/scripts/ci-gate-publish.sh" && ok "no bare status POST remains in the publisher" || bad "the publisher still posts directly"
CONC=$(sed -n '/^    concurrency:/,/^    permissions:/p' "$WORKFLOW")
grep -q 'cancel-in-progress: true' <<<"$CONC" && grep -q 'workflow_run.head_sha' <<<"$CONC" && grep -q 'inputs.context' <<<"$CONC" && grep -q "'pr'" <<<"$CONC" && grep -q 'github.run_id' <<<"$CONC" \
  && ok "the gate job has per-SHA concurrency with cancel-in-progress (context-, event- and sweep-aware)" || bad "the concurrency block is missing or incomplete"
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

echo "-- the sweep spends ONE rate-limit retry budget across all its commits --"
# The sweep evaluates the default branch head (sha 12) first, then the pull request head (sha 11).
pubreset; set_pulls "1 $T1 11"; set_default 12
sweep_sha 11 "$DONE"; sweep_sha 12 "$DONE"
echo retry429 > "$FAKEGH/by/$(sha_n 11)/limits"; echo retry429 > "$FAKEGH/by/$(sha_n 12)/limits"
sweep API_RETRY_BUDGET_SECONDS=10 CI_GATE_SLEEP=true
chk "the first commit (default branch) waits out its 429 (7 s of 10) and is judged" "$(last_for 12)" success
chk "the second commit's 429 would pass the shared budget (14 s > 10): it is not judged; the failure fallback writes failure, never a pass; the sweep fails" "$(count_for 11)/$(last_for 11)/$RC" "1/failure/1"
grep -q '7s of the 10s retry budget spent (next wait 7s)' <<< "$SOUT" \
  && ok "the refusal names the budget already spent by the earlier commit" || bad "the second publisher did not see the shared ledger"
pubreset; set_pulls "1 $T1 11"; set_default 12
sweep_sha 11 "$DONE"; sweep_sha 12 "$DONE"
echo retry429 > "$FAKEGH/by/$(sha_n 11)/limits"; echo retry429 > "$FAKEGH/by/$(sha_n 12)/limits"
sweep API_RETRY_BUDGET_SECONDS=14 CI_GATE_SLEEP=true
chk "inside the shared budget (7 + 7 = 14 s), both commits are judged" "$(last_for 11)/$(last_for 12)/$RC" "success/success/0"

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

echo "-- a sweep that meets a rate limit stops: the rest would meet the same limit --"
pubreset; set_pulls "1 $T1 1" "2 $T1 3"; set_default 2
sweep_sha 1 "$DONE"; sweep_sha 2 "$DONE"; sweep_sha 3 "$DONE"
for _ in 1 2 3 4 5; do echo '429 Too Many Requests|Retry-After: 3'; done > "$FAKEGH/ratelimit"
sweep CI_GATE_SLEEP="$RL/sleep" CI_GATE_CLOCK="$RL/clock"
chk "rate limited on the first head: exit 1, 5 attempts, nothing written" "$RC/$(attempts)/$([ -s "$FAKEGH/posts.log" ] && echo posted || echo none)" "1/5/none"
grep -q '| rate limited | skipped | 2 not evaluated: rate limited |' "$WORK/gss" && ok "the table lists the 2 heads left for the next sweep" || bad "the table does not list the heads left by the rate limit"
grep -q 'rate limited; the 2 remaining head SHA(s) were NOT evaluated' <<<"$SOUT" && ok "the sweep warns that it stopped" || bad "no warning for the stopped sweep"
grep -qF '(tamper guard)' "$WORK/gss" && bad "silence: the throttled head heads no pull request, yet a tamper row was written" || ok "silence: no tamper row for a throttled head that heads no pull request"
pubreset; set_pulls "1 $T1 1" "2 $T1 3"; set_default 2
sweep_sha 1 "$DONE"; sweep_sha 2 "$DONE"; sweep_sha 3 "$DONE"
echo '429 Too Many Requests|Retry-After: 3' > "$FAKEGH/ratelimit"
sweep CI_GATE_SLEEP="$RL/sleep" CI_GATE_CLOCK="$RL/clock"
chk "control: rate limited once and recovered: all 3 heads written, exit 0" "$(grep -c . "$FAKEGH/posts.log")/$RC/$(grep -c 'not evaluated: rate limited' "$WORK/gss")" "3/0/0"
pubreset; set_pulls "1 $T1 1"; set_default 1
sweep_sha 1 "$DONE"
for _ in 1 2 3 4 5; do echo '429 Too Many Requests|Retry-After: 3'; done > "$FAKEGH/ratelimit"
sweep CI_GATE_SLEEP="$RL/sleep" CI_GATE_CLOCK="$RL/clock"
grep -qF '(tamper guard) | skipped | not evaluated: rate limited |' "$WORK/gss" && ok "firing: the throttled head heads PR #1, so its tamper guard is listed as not evaluated" || bad "firing: the throttled head's tamper guard is not listed as not evaluated"
pubreset

echo "-- the sweep runs the tamper guard publisher for each pull request head (Silence, Firing, mutants) --"
mk_tamper() { # [exit code] -> a stand-in scripts/ci-gate-tamper-status.sh that logs what it was asked
  cat > "$SUITE_DIR/scripts/ci-gate-tamper-status.sh" <<TAMPER_EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\$HEAD_SHA" "\$PR_NUMBERS" >> "$FAKEGH/tamper.calls"
[[ ${1:-0} == 0 ]] || { echo "::error::ci-gate-tamper-status: stand-in refused; NO TAMPER VERDICT WAS PRODUCED"; exit ${1:-0}; }
echo "CI/gate-tamper-guard = success: stand-in"
TAMPER_EOF
}
SWEEP_UT="$SUITE_DIR/scripts/ci-gate-sweep.sh"
tsweep_case() { # <tamper exit> -> TC (calls), RC
  pubreset; : > "$FAKEGH/tamper.calls"; mk_tamper "$1"
  set_pulls "4 $T1 21" "9 2026-11-17T10:01:00Z 21" "5 2026-11-17T10:02:00Z 22"; set_default 23
  for i in 21 22 23; do sweep_sha "$i" "$DONE"; done
  sweep; TC=$(sort "$FAKEGH/tamper.calls")
}
tcase_silence() { tsweep_case 0; [[ $TC == "$(printf '%s\t4 9\n%s\t5' "$(sha_n 21)" "$(sha_n 22)")" && $RC == 0 ]]; }
tcase_firing()  { tsweep_case 1; [[ $RC == 1 ]] && grep -qF "| PR #5 (tamper guard) | error |" "$WORK/gss"; }
tcase_absent()  { pubreset; rm -f "$SUITE_DIR/scripts/ci-gate-tamper-status.sh"; : > "$FAKEGH/tamper.calls"; set_pulls "4 $T1 21"; set_default 23
                  for i in 21 23; do sweep_sha "$i" "$DONE"; done; sweep; [[ $RC == 0 && ! -s $FAKEGH/tamper.calls ]]; }
tcase_silence && ok "two PRs share a head: one tamper call with both numbers; one call per other PR head; none for the default branch" || bad "tamper calls from the sweep: '$TC' rc=$RC"
tcase_firing && ok "a tamper publisher that could not publish is an error row and the sweep exits non-zero" || bad "a tamper error is not surfaced by the sweep (rc=$RC)"
tcase_absent && ok "a suite without the tamper publisher: the sweep runs as before" || bad "the sweep needs the tamper publisher (rc=$RC)"
cp "$SWEEP_UT" "$WORK/sweep.orig"
tmutant() { # <case> <what> <old> <new>
  python3 -c 'import sys; s=open(sys.argv[1]).read(); assert s.count(sys.argv[2])==1; open(sys.argv[4],"w").write(s.replace(sys.argv[2],sys.argv[3]))' "$WORK/sweep.orig" "$3" "$4" "$SWEEP_UT" \
    || { bad "sweep mutant '$2': anchor not found"; cp "$WORK/sweep.orig" "$SWEEP_UT"; return; }
  if "$1" > /dev/null 2>&1; then bad "sweep mutant survived: $2"; else ok "sweep mutant killed: $2 (by $1)"; fi
  cp "$WORK/sweep.orig" "$SWEEP_UT"
}
tmutant tcase_silence 'only one PR number per head'        "| sort -un | paste -sd' ' -)" "| sort -un | head -n 1)"
tmutant tcase_silence 'every PR is judged on every head'   '$2 == s && '                '1 && '
tmutant tcase_firing  'a tamper error is not counted'       '    if (( trc != 0 )); then'"
      tdesc"                                                                     '    if (( trc > 99 )); then'"
      tdesc"
tmutant tcase_absent  'a missing publisher is still run'    'if [[ -n $prs && -f $TAMPER ]]; then' 'if [[ -n $prs ]]; then'
rm -f "$SUITE_DIR/scripts/ci-gate-tamper-status.sh"; pubreset

echo "== repository coordinate: a leading dot is a name; traversal and malformed ones are not =="
step_script() { # <file> <step name prefix> -> the step's run: block, de-indented
  awk -v name="$2" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    inrun { if ($0 ~ /^[[:space:]]*$/ || ind($0) > runcol) { print substr($0, runcol + 3); next } exit }
    index($0, "- name: " name) { want = 1; next }
    want && $0 ~ /^[[:space:]]+run: [|]$/ { runcol = ind($0); inrun = 1 }
  ' "$1"
}
step_script "$WORKFLOW" "Refuse anything but a workflow_run" > "$WORK/refuse.sh"
[ -s "$WORK/refuse.sh" ] && ok "extracted the workflow's validation step" || bad "could not extract the validation step"
refuse() { # VAR=value ... -> RC; defaults: a valid pull_request
  env EVENT_NAME=pull_request HEAD_SHA="$(printf 'b%.0s' $(seq 40))" REPO=example/repo CONTEXT=CI/gate TIMEOUT_MINUTES=180 \
    WAIT_MINUTES=30 POLL_SECONDS=20 QUIET_SECONDS=30 "$@" bash "$WORK/refuse.sh" > /dev/null 2>&1
  RC=$?
}
refuse; chk "the default inputs are accepted" "$RC" 0
refuse REPO=example/.github; chk "the workflow accepts example/.github" "$RC" 0
refuse REPO=example/.github-private; chk "the workflow accepts a leading-dot name with more" "$RC" 0
refuse REPO=o/r.js; chk "the workflow accepts a dot inside a name" "$RC" 0
for r in a/b/c /x a/ a/. a/.. notacoordinate '' 'a b/c' .a/b -a/b 'a/b c' a//b ../x a/b/; do
  refuse REPO="$r"; chk "the workflow rejects REPO '$r'" "$RC" 1
done
for q in 0 30 120 007; do refuse QUIET_SECONDS="$q"; chk "the workflow accepts quiet_seconds $q" "$RC" 0; done
for q in 121 -1 '' x 1.5 0120 999999; do refuse QUIET_SECONDS="$q"; chk "the workflow rejects quiet_seconds '$q'" "$RC" 1; done
step_script "$WORKFLOW" "Let a burst of workflow_run events settle" > "$WORK/quiet.sh"
mkdir -p "$WORK/qs/bin"
printf '#!/usr/bin/env bash\necho "$1" >> "$QSDIR/slept"\n' > "$WORK/qs/bin/sleep"; chmod +x "$WORK/qs/bin/sleep"
quiet() { rm -f "$WORK/qs/slept"; env PATH="$WORK/qs/bin:$PATH" QSDIR="$WORK/qs" HEAD_SHA=abc "$@" bash "$WORK/quiet.sh" > /dev/null 2>&1; RC=$?; }
qslept() { [ -f "$WORK/qs/slept" ] && paste -sd, "$WORK/qs/slept" || echo none; }
quiet EVENT_NAME=workflow_run QUIET_SECONDS=30; chk "workflow_run: the quiet step sleeps quiet_seconds once" "$RC/$(qslept)" "0/30"
quiet EVENT_NAME=workflow_run QUIET_SECONDS=0; chk "workflow_run with quiet_seconds 0: no sleep" "$RC/$(qslept)" "0/none"
for ev in pull_request schedule workflow_dispatch; do
  quiet EVENT_NAME=$ev QUIET_SECONDS=30; chk "$ev: no quiet period" "$RC/$(qslept)" "0/none"
done
L_QUIET=$(grep -n -- '- name: Let a burst of workflow_run events settle' "$WORKFLOW" | cut -d: -f1)
L_RD=$(grep -n -- '- name: Read the profile and the verdict scripts' "$WORKFLOW" | cut -d: -f1)
L_PD=$(grep -n -- '- name: Mark a started or re-run' "$WORKFLOW" | cut -d: -f1)
{ [ -n "$L_QUIET" ] && [ "$L_PD" -lt "$L_QUIET" ] && [ "$L_QUIET" -lt "$L_RD" ]; } \
  && ok "the quiet step sits after the early pending and before the first suite read" || bad "the quiet step is misplaced ($L_PD/$L_QUIET/$L_RD)"
! grep -q 'gh ' "$WORK/quiet.sh" && ok "the quiet step makes no API call" || bad "the quiet step calls gh"
step_script "$WORKFLOW" "Read the profile and the verdict scripts" > "$WORK/readprofile.sh"
[ -s "$WORK/readprofile.sh" ] && ok "extracted the profile-fetch step" || bad "could not extract the profile-fetch step"
mkdir -p "$WORK/rp/bin"
cat > "$WORK/rp/bin/gh" <<'RPGH'
#!/usr/bin/env bash
for a in "$@"; do case $a in repos/*/contents/*) p=${a#repos/*/contents/}; echo "${p%%\?*}" >> "$RPDIR/fetched"; echo "x"; exit 0 ;; esac; done
exit 1
RPGH
chmod +x "$WORK/rp/bin/gh"
# A stub git: GITMODE=fail refuses the fetch (the API fallback runs); ok serves every blob;
# wronghead fetches but reports another FETCH_HEAD (must not be trusted). Blob reads are logged.
cat > "$WORK/rp/bin/git" <<'RPGIT'
#!/usr/bin/env bash
[ "$1" = -C ] && shift 2
case $1 in
  init) mkdir -p "${@: -1}"; exit 0 ;;
  fetch) [ "$GITMODE" = fail ] && exit 128; echo "${@: -2}" >> "$RPDIR/gitfetch"; exit 0 ;;
  rev-parse) [ "$GITMODE" = wronghead ] && { printf 'd%.0s' $(seq 40); echo; exit 0; }; echo "$WF_SHA"; exit 0 ;;
  cat-file) p=${3#*:}; echo "$p" >> "$RPDIR/gitread"; echo "x"; exit 0 ;;
esac
exit 1
RPGIT
chmod +x "$WORK/rp/bin/git"
rp_run() { # GITMODE -> RC; logs in $WORK/rp/{fetched,gitfetch,gitread}
  rm -rf "$WORK/rp/fetched" "$WORK/rp/gitfetch" "$WORK/rp/gitread" "$WORK/rp/tmp"; : > "$WORK/rp/gh_env"
  env PATH="$WORK/rp/bin:$PATH" GITMODE="$1" RPDIR="$WORK/rp" RUNNER_TEMP="$WORK/rp/tmp" GITHUB_ENV="$WORK/rp/gh_env" REPO=example/.github \
    WF_REPO=hyperpolymath/proven-cicd-and-workflows WF_SHA="$(printf 'c%.0s' $(seq 40))" bash "$WORK/readprofile.sh" > "$WORK/rp/out" 2>&1
  RC=$?
}
rpc() { [ -f "$WORK/rp/$1" ] && grep -c "${2:-.}" "$WORK/rp/$1" || echo 0; }
rp_landed() { [ -f "$WORK/rp/tmp/ci-gate-suite/profiles/ci-gate/example/.github.json" ] && echo yes || echo no; }
rp_run fail
chk "git refused: a .github repository's profile is read through the contents API from profiles/ci-gate/example/.github.json and lands under the owner" \
  "$RC/$(rpc fetched '^profiles/ci-gate/example/\.github\.json$')/$(rpc fetched)/$(rp_landed)" "0/1/9/yes"
rp_run ok
chk "git works: one fetch of the pinned commit, all nine files read from it, no contents-API call, the profile lands under the owner" \
  "$RC/$(rpc gitfetch)/$(rpc gitfetch "github.com/hyperpolymath/proven-cicd-and-workflows $(printf 'c%.0s' $(seq 40))")/$(rpc gitread)/$(rpc gitread '^profiles/ci-gate/example/\.github\.json$')/$(rpc fetched)/$(rp_landed)/$(grep -c 'via git' "$WORK/rp/out")" "0/1/1/9/1/0/yes/1"
rp_run wronghead
chk "git fetched another commit than the pin: nothing is read from it, the contents API is used instead" \
  "$RC/$(rpc gitread)/$(rpc fetched)/$(grep -c 'via api' "$WORK/rp/out")" "0/0/9/1"
echo "== the publisher and the sweep refuse a malformed coordinate; a .github repository resolves =="
jq '.repository = "example/.github"' "$FX/profile.json" > "$SUITE_DIR/profiles/ci-gate/example/.github.json"
pubreset; snap 1 "$DONE"; publish REPO=example/.github
chk "publisher: example/.github reads profiles/ci-gate/example/.github.json and publishes success" "$RC/$NPOSTS/$(post_n 1 | cut -f1)" "0/1/success"
rm -f "$SUITE_DIR/profiles/ci-gate/example/.github.json"
for r in a/b/c /x a/ a/. a/.. notacoordinate '' ../x 'a b/c'; do
  pubreset; snap 1 "$DONE"; publish REPO="$r"
  chk "publisher: REPO '$r' is refused, no POST, no runs fetched" "$RC/$NPOSTS/$CALLS" "1/0/0"
done
for r in a/b/c /x a/ a/. a/.. notacoordinate ../x; do
  pubreset; set_pulls "1 $T1 1"; set_default 2; sweep_sha 1 "$DONE"; sweep_sha 2 "$DONE"; sweep REPO="$r"
  chk "sweep: REPO '$r' is refused, nothing posted" "$RC/$([ -s "$FAKEGH/posts.log" ] && echo posted || echo none)" "1/none"
done
pubreset
echo "== validator and shipped profiles: a repository named .github =="
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
w "$(p "$A" example/.github)"; v_ok "$WORK/p.json" example/.github "a profile for a repository named .github"
w "$(p "$A" example/.github)"; v_bad "$WORK/p.json" example/repo "a .github profile read for another repository"
for r in a/b/c /x a/ a/. a/.. notacoordinate "a b/c" ../x; do
  w "$(p "$A" "$r")"; v_bad "$WORK/p.json" "$r" "a profile whose repository is '$r'"
done
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
shopt -s nullglob dotglob   # a repository named .github has the profile .github.json
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
# The repositories known to have BOTH producers of the emoji-named Empty-linter gate
# (dogfood-gate.yml and empty-linter.yml) must require both. Repositories onboarded later name
# the job without the emoji and have one producer only (read from their check runs), so this
# exact pair is asserted where it is known to exist, and the pair rule below covers every profile.
for repo in mathesis resource-algebra rsr-template-repo tsunami-breaker work-queue; do
  f="$ROOT/profiles/ci-gate/hyperpolymath/$repo.json"
  jq -e '[.checks[] | select(.job == "🔴 GATE: Empty-linter (invisible characters)") | .workflow] | sort == [".github/workflows/dogfood-gate.yml", ".github/workflows/empty-linter.yml"]' "$f" >/dev/null && ok "hyperpolymath/$repo: both Empty-linter producers are required" || bad "hyperpolymath/$repo: Empty-linter producers are not both listed"
done
# Pair rule, every profile: listing one producer of the emoji-named gate means listing both,
# so a name satisfied by one producer can never stand in for the other.
for f in "$ROOT"/profiles/ci-gate/*/*.json; do
  repo="$(basename "$(dirname "$f")")/$(basename "$f" .json)"
  jq -e '[.checks[] | select(.job == "🔴 GATE: Empty-linter (invisible characters)") | .workflow] | sort | (length == 0 or . == [".github/workflows/dogfood-gate.yml", ".github/workflows/empty-linter.yml"])' "$f" >/dev/null && ok "$repo: Empty-linter producers are none or both" || bad "$repo: lists one Empty-linter producer without the other"
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
grep -q 'git -C "$src" fetch -q --depth 1 --no-tags "https://github.com/$WF_REPO" "$WF_SHA"' "$WORKFLOW" && grep -q 'rev-parse FETCH_HEAD)" == "$WF_SHA"' "$WORKFLOW" \
  && ok "ci-gate.yml reads the suite with one shallow git fetch of the pinned commit and checks FETCH_HEAD" || bad "ci-gate.yml does not git-fetch the pinned suite commit with a FETCH_HEAD check"
! grep -qE '^[[:space:]]*gh api -X POST' <(sed -n '/- name: Evaluate the commit/,/- name: Publish a failure/p' "$WORKFLOW") && ok "the evaluate step publishes only through the script" || bad "the evaluate step posts a status itself"
grep -qE '^  gate:' "$WORKFLOW" && ok "job id is gate" || bad "job id is not gate"
grep -qE 'default: *"?CI/gate"?' "$WORKFLOW" && ok "context input defaults to CI/gate" || bad "context default is not CI/gate"
grep -qE 'default: *180' "$WORKFLOW" && ok "timeout_minutes defaults to 180" || bad "timeout_minutes default is not 180"
WAIT_GUARD=$(sed -n '/# Reserve ten minutes/,/      - name: /{ /      - name: /d; s/^          //; p; }' "$WORKFLOW")
for spec in 0:0 30:0 50:0 51:1 60:1 999999999999999999999999:1; do
  IFS=: read -r minutes expected <<< "$spec"
  env EVENT_NAME=pull_request WAIT_MINUTES="$minutes" bash -c "$WAIT_GUARD" >/dev/null 2>&1
  chk "wait budget $minutes fits timeout iff allowed" "$?" "$expected"
done
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
NAMED=$(sed -n 's/^    workflows: \[\(.*\)\]$/\1/p' "$SELF" | tr ',' '\n' | sed 's/^ *"//; s/" *$//' | sort)
NEEDED=$(jq -r '.checks[].workflow' "$ROOT/profiles/ci-gate/hyperpolymath/proven-cicd-and-workflows.json" | sort -u \
  | while read -r w; do sed -n 's/^name: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$ROOT/$w" | head -1; done | sort)
[ -n "$NAMED" ] && [ "$NAMED" = "$NEEDED" ] \
  && ok "the suite's caller names exactly the workflows its profile requires (no more events than the verdict needs)" || bad "the caller's workflow_run list ($NAMED) is not the profile's workflows ($NEEDED)"
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
