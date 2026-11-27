#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Offline controls for the interim CI/gate: the pure verdict, the profile validator, the
# shipped profiles, and static guards on the reusable workflow and the caller template.
#
# A gate that only ever goes green proves nothing, so every negative asserts the EXACT
# state and exit code, and the positive control (all present and successful) is what
# makes them meaningful. The headline negatives: a required name with NO JOB is never success
# (pending while the event-driven gate waits for the next evaluation, a failure past the timeout),
# and a failed required job is a failure at once.

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
expect_missing() { # <label> <names>: pending inside the timeout (nothing is written as a failure early), failure past it
  local saved=$NOW
  expect "$1 (inside the timeout)" pending 3 "not yet reported: $2"
  NOW=$((T0 + 181 * 60)); expect "$1 (past the timeout)" failure 1 "never reported: $2"; NOW=$saved
}
expect_unfinished() { # <label> <names>
  local saved=$NOW
  expect "$1 (inside the timeout)" pending 3 "not yet reported: $2"
  NOW=$((T0 + 181 * 60)); expect "$1 (past the timeout)" failure 1 "never completed: $2"; NOW=$saved
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

echo "== headline negative: a required name with no job and nothing active is never success =="
reset; mut_jb '[.[] | select(.name != "Lint")]'
expect_missing "Lint has no job, nothing else active" "ci-quality.yml:Lint"
mut_wr '[.[] | select(.name != "CI gate")]'
expect_missing "Lint has no job, no gate run either" "ci-quality.yml:Lint"
reset; mut_jb '[]'; mut_wr '[]'
expect "no jobs and no runs at all: no clock, so pending, never success" pending 3 "not yet reported"

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
expect_unfinished "required job in progress but no run is active" "ci-quality.yml:Test"
reset; mut_wr '. + [r(15;"Slow";5;"pull_request";"completed";"2026-11-17T10:00:10Z")]'
expect "an unrelated run that completed is not waited for" success 0

echo "-- a rerun after a full pass: while it is active the verdict is pending (a later evaluation of the commit sees it) --"
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
reset; expect_missing "second producer's workflow never ran, first succeeded, nothing active" "other-build.yml:Build"
mut_wr '. + [r(21;"Other build";6;"pull_request";"completed";"2026-11-17T10:00:09Z")]'
expect_missing "second producer ran but has no job of that name, nothing active" "other-build.yml:Build"
mut_wr 'map(select(.name != "CI gate")) | . + [r(21;"Other build";6;"pull_request";"queued";"2026-11-17T10:00:09Z")]'
expect "second producer queued, no job yet" pending 3 "waiting for 1 workflow runs: Other build"
reset; mut_jb '. + [j(2001;"Build";22;"completed";"success")]'
mut_wr '. + [r(22;"Third build";7;"pull_request";"completed";"2026-11-17T10:00:09Z")]'
expect_missing "same display name from a different workflow does not satisfy the second producer" "other-build.yml:Build"
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
expect_missing "ci-build2.yml@main does not satisfy ci-build.yml" "ci-build.yml:Build"
mut_wr 'map(if .id == 11 then .path = ".github/workflows/other.yml@main" else . end)'
expect_missing "other.yml@main does not satisfy ci-build.yml" "ci-build.yml:Build"
mut_wr 'map(if .id == 11 then .path = ".github/workflows/ci-build@main.yml" else . end)'
expect_missing "an @ inside the file stem is not a ref suffix" "ci-build.yml:Build"
mut_wr 'map(if .id == 11 then .path = null else . end)'
expect_missing "a run with no path never satisfies an entry" "ci-build.yml:Build"
mut_wr 'map(if .id == 11 then .path += "@main" else . end)'
mut_jb 'map(if .name == "Build" then .conclusion = "failure" else . end)'
expect "a failed job of a ref-suffixed run path is still a failure" failure 1 "Build (failure)"
PROFILE="$WORK/two.json"
reset; mut_jb '. + [j(2001;"Build";21;"completed";"success")]'
mut_wr 'map(if .id == 11 then .path += "@main" else . end) | . + [r(21;"Other build";6;"pull_request";"completed";"2026-11-17T10:00:09Z") | .path += "@refs/heads/x"]'
expect "two producers, both paths ref-suffixed" success 0
mut_wr 'map(if .id == 11 then .path += "@main" else . end) | . + [r(21;"Other build";6;"pull_request";"completed";"2026-11-17T10:00:09Z") | .path = ".github/workflows/third.yml@main"]'
expect_missing "two producers, the second's path is another file with a ref suffix" "other-build.yml:Build"
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

echo "== the new verdict rules: a failed run with no jobs, and zero matches =="
reset; mut_jb 'map(select(.run.id != 12))'; mut_wr 'map(if .id == 12 then .conclusion = "startup_failure" else . end)'
expect "a required workflow's run ended startup_failure and produced no jobs" failure 1 "ci-quality.yml:Lint (startup_failure)"
reset; mut_wr 'map(if .id == 12 then .conclusion = "failure" else . end)'
expect "a run that failed for another job while the required jobs succeeded is not itself a failure" success 0
reset; mut_jb '[]'
expect_missing "zero matched required checks (every run completed, no check run joined): never success" "ci-build.yml:Build, ci-quality.yml:Lint, ci-quality.yml:Test"
reset; mut_jb 'map(.status = "queued" | .conclusion = null)'; mut_wr 'map(if .id != 14 then .status = "queued" | .conclusion = null else . end)'
expect "required checks queued: pending" pending 3 "waiting for 3 workflow runs"

echo "== the fixtures agree: the check runs joined to the workflow runs are the jobs the verdict reads =="
JOIN="$ROOT/profiles/ci-gate/join-checks.jq"
JOINED=$(jq -n --slurpfile runs "$FX/workflow-runs.json" --slurpfile checks "$FX/check-runs.json" -f "$JOIN")
chk() { # <label> <actual> <expected>
  [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', expected '$3'"
}
chk "join: the Actions check runs carry their workflow run (name, path); the third-party suite matches nothing and is dropped" \
  "$(jq -r 'map("\(.name)|\(.run.id)|\(.run.name)|\(.run.path)") | join(",")' <<<"$JOINED")" \
  "Build|11|CI build|.github/workflows/ci-build.yml,Test|12|CI quality|.github/workflows/ci-quality.yml,Lint|12|CI quality|.github/workflows/ci-quality.yml,Advisory scan|13|Advisory|.github/workflows/advisory.yml,scan / gitleaks|13|Advisory|.github/workflows/advisory.yml"
chk "join: a job of a reusable workflow keeps its 'caller / called' check-run name" "$(jq -r 'map(select(.name | contains(" / "))) | map(.name) | join(",")' <<<"$JOINED")" "scan / gitleaks"
chk "join: the shape equals the jobs fixture for the same names (id, name, status, conclusion, run.id)" \
  "$(jq -c 'map({name, status, conclusion, run: .run.id})' <<<"$JOINED" | jq -c '[.[] | select(.name != "scan / gitleaks")] | sort_by(.name)')" \
  "$(jq -c 'map({name, status, conclusion, run: .run.id}) | sort_by(.name)' "$FX/jobs.json")"
chk "join: a run with no check_suite_id joins nothing (never matched by accident)" \
  "$(jq -n --slurpfile runs <(jq 'map(del(.check_suite_id))' "$FX/workflow-runs.json") --slurpfile checks "$FX/check-runs.json" -f "$JOIN" | jq length)" 0

echo "== publisher: fake gh, two reads per evaluation, settle guard, status writes =="
PUBLISH="$ROOT/scripts/ci-gate-publish.sh"
SUITE_DIR="$WORK/suite"; FAKEGH="$WORK/stub"
mkdir -p "$SUITE_DIR/scripts" "$SUITE_DIR/profiles/ci-gate/example" "$FAKEGH/bin"
cp "$ROOT"/scripts/ci-gate-verdict.sh "$ROOT"/scripts/validate-ci-gate-profile.sh "$ROOT"/scripts/ci-gate-lib.sh "$PUBLISH" "$SUITE_DIR/scripts/"
cp "$ROOT"/profiles/ci-gate/validate.jq "$ROOT"/profiles/ci-gate/select-runs.jq "$ROOT"/profiles/ci-gate/join-checks.jq "$SUITE_DIR/profiles/ci-gate/"
cp "$FX/profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"
cat > "$FAKEGH/bin/gh" <<'FAKEGH_EOF'
#!/usr/bin/env bash
# Fake `gh api -i`: it answers like the REST API (status line, headers, blank line, JSON body), with
# Link headers for pagination. Canned data in $FAKEGH_DIR:
#   runs.N.json   the Nth runs listing (else the highest-numbered file); by/<sha>/ holds the same files
#                 for ONE commit (the sweep reads many); jobs.json the jobs of the commit, served as
#                 check runs (check_suite.id = run id + 9000, the check_suite_id of the fixture runs);
#                 checkruns.extra.json more check runs (a third-party app)
#   inject.<kind> / inject.always.<kind>   lines `status~Header: v|Header: v~body`: the next call of that
#                 kind (runs checks status post contents) answers so; `always` is never consumed
#   fail.N        (in a by/<sha>/ or the root) the Nth runs listing answers with the line in the file, else 500
#   failpost failstatus badstatus failpulls faildefault lands500   flags (failpulls/faildefault may hold a `status~headers~body` line; lands500: the next status POST lands and answers 500; landscut: it lands and answers 201 with the body cut off; a status code ending in ! in an inject line is a cut-off answer, gh exit 1)
#   total.<key>   the number the listing of that wrapper key (workflow_runs, check_runs, statuses) reports as total_count
#   posts.log status.log calls.log status.reads fetched   what was asked
D=${FAKEGH_DIR:?}
method=GET; ep=''; fields=(); a=("$@"); i=0; incl=0
while ((i < ${#a[@]})); do
  case ${a[i]} in
    api) ;;
    -i) incl=1 ;;
    -X) i=$((i + 1)); method=${a[i]} ;;
    -H) i=$((i + 1)) ;;
    -f) i=$((i + 1)); fields+=("${a[i]}") ;;
    *) ep=${a[i]} ;;
  esac
  i=$((i + 1))
done
echo "$method $ep" >> "$D/calls.log"
reply() { # <code> <headers separated by |> <body>; a code ending in ! is cut off: gh exits 1 even after 2xx headers
  local code=$1 h=$2 body=$3 text=OK x hh cut=0
  if [[ $code == *'!' ]]; then cut=1; code=${code%!}; fi
  [[ $code =~ ^2 ]] || text=Error
  if ((incl)); then   # gh api -i: the status line and the headers, then a blank line, then the body
    printf 'HTTP/2.0 %s %s\r\n' "$code" "$text"
    if [[ -n $h ]]; then IFS='|' read -ra hh <<< "$h"; for x in "${hh[@]}"; do printf '%s\r\n' "$x"; done; fi
    printf '\r\n'
  fi
  printf '%s\n' "$body"
  if [[ $code =~ ^2 ]]; then if ((cut)); then echo "gh: unexpected EOF reading the response body" >&2; exit 1; fi; exit 0; fi
  echo "gh: $(jq -r '.message // empty' <<< "$body" 2> /dev/null) (HTTP $code)" >&2
  exit 1
}
reply_line() { local c h b; IFS='~' read -r c h b <<< "$1"; reply "$c" "$h" "$b"; }
inject() { # <kind>
  local f=$D/inject.$1 line=''
  if [[ -s $f ]]; then line=$(head -1 "$f"); sed -i 1d "$f"
  elif [[ -s $D/inject.always.$1 ]]; then line=$(head -1 "$D/inject.always.$1"); fi
  [[ -z $line ]] || reply_line "$line"
}
page_num() { local p=${ep##*page=}; [[ $p =~ ^[0-9]+$ ]] || p=1; echo "$p"; }
page_of() { # <items file: a JSON array> <wrapper key or -> <page size>
  local file=$1 key=$2 size=$3 page total next='' body
  page=$(page_num)
  total=$(jq length "$file")
  if ((page * size < total)); then next="Link: <https://api.github.com/x?page=$((page + 1))>; rel=\"next\""; fi
  if [[ $key == - ]]; then
    body=$(jq -c --argjson p "$page" --argjson s "$size" '.[($p - 1) * $s : $p * $s]' "$file")
  else
    body=$(jq -c --argjson p "$page" --argjson s "$size" --arg k "$key" '{total_count: length, ($k): .[($p - 1) * $s : $p * $s]}' "$file")
    if [[ -f $D/total.$key ]]; then body=$(jq -c --argjson t "$(cat "$D/total.$key")" '.total_count = $t' <<< "$body"); fi   # a listing that reports more than it returns
  fi
  reply 200 "$next" "$body"
}
sha_of() { local s=${1#*/commits/}; echo "${s%%[/?]*}"; }
if [[ $method == POST && $ep == repos/*/statuses/* ]]; then
  inject post
  [[ ! -f $D/failpost ]] || reply 500 '' '{"message":"Server Error"}'
  state=''; desc=''; ctx=''; psha=${ep##*/}
  for f in "${fields[@]}"; do case $f in state=*) state=${f#state=} ;; description=*) desc=${f#description=} ;; context=*) ctx=${f#context=} ;; esac; done
  # the real API refuses these two, so a missing sanitiser is a failure of the test, not a silent pass
  printf '%s' "$desc" | perl -CSD -0777 -ne 'exit(/[\x{10000}-\x{10FFFF}]/ ? 1 : 0)' \
    || reply 422 '' '{"message":"Validation Failed","errors":[{"message":"Description doesn'"'"'t accept 4-byte Unicode"}]}'
  [[ $(jq -rn --arg d "$desc" '$d | length') -le 140 ]] || reply 422 '' '{"message":"Validation Failed","errors":[{"message":"Description is too long (maximum is 140 characters)"}]}'
  if [[ -f $D/prepost ]]; then
    cat "$D/prepost" >> "$D/posts.log"
    awk -F'\t' -v s="$psha" -v c="$ctx" '{print s "\t" c "\t" $1 "\t" $2}' "$D/prepost" >> "$D/status.log"; rm -f "$D/prepost"
  fi
  printf '%s\t%s\t%s\n' "$state" "$desc" "$psha" >> "$D/posts.log"
  printf '%s\t%s\t%s\t%s\n' "$psha" "$ctx" "$state" "$desc" >> "$D/status.log"
  if [[ -f $D/lands500 ]]; then rm -f "$D/lands500"; reply 500 '' '{"message":"Server Error"}'; fi   # the write landed, the answer did not say so
  if [[ -f $D/landscut ]]; then rm -f "$D/landscut"; reply '201!' '' '{"id":'; fi   # the write landed, 2xx headers came, the body was cut off
  reply 201 '' '{"id":1}'
elif [[ $ep == repos/*/commits/*/status\?* ]]; then
  echo "$ep" >> "$D/status.reads"
  inject status
  [[ ! -f $D/failstatus ]] || reply 500 '' '{"message":"Server Error"}'
  [[ ! -f $D/badstatus ]] || reply 200 '' 'not json'
  sha=$(sha_of "$ep"); t=$(mktemp)
  jq -R -s -c --arg sha "$sha" 'split("\n") | map(select(length > 0) | split("\t") | select(.[0] == $sha)) | reduce .[] as $r ({}; .[$r[1]] = {context: $r[1], state: $r[2], description: $r[3]}) | [.[]]' "$D/status.log" > "$t" 2> /dev/null || echo '[]' > "$t"
  page_of "$t" statuses 100
elif [[ $ep == repos/*/actions/runs\?head_sha* ]]; then
  sha=${ep#*head_sha=}; sha=${sha%%&*}
  R=$D; [[ ! -d $D/by/$sha ]] || R=$D/by/$sha
  if [[ $(page_num) == 1 ]]; then
    inject runs
    n=$(( $(cat "$R/runs.count" 2> /dev/null || echo 0) + 1 )); echo "$n" > "$R/runs.count"
    if [[ -f $R/fail.$n ]]; then
      line=$(cat "$R/fail.$n"); [[ -n $line ]] || line='500~~{"message":"Server Error"}'; reply_line "$line"
    fi
    f=$R/runs.$n.json; [[ -f $f ]] || f=$(ls "$R"/runs.*.json | sort -V | tail -1)
    echo "$f" > "$R/runs.cur"
  fi
  page_of "$(cat "$R/runs.cur")" workflow_runs "${RUNS_PAGE_SIZE:-100}"
elif [[ $ep == repos/*/commits/*/check-runs\?* ]]; then
  sha=$(sha_of "$ep")
  R=$D; [[ ! -d $D/by/$sha ]] || R=$D/by/$sha
  [[ $(page_num) != 1 ]] || inject checks
  t=$(mktemp)
  jq -c 'map({id, name, status, conclusion, check_suite: {id: (.run.id + 9000)}, app: {slug: "github-actions"}})' "$R/jobs.json" > "$t"
  if [[ -f $R/checkruns.extra.json ]]; then jq -c -s 'add' "$t" "$R/checkruns.extra.json" > "$t.2"; mv "$t.2" "$t"; fi
  page_of "$t" check_runs "${CHECKS_PAGE_SIZE:-100}"
elif [[ $ep == repos/*/pulls\?state=open* ]]; then
  if [[ -f $D/failpulls ]]; then line=$(cat "$D/failpulls"); [[ -n $line ]] || line='500~~{"message":"Server Error"}'; reply_line "$line"; fi
  page_of "$D/pulls.json" - "${PULLS_PAGE_SIZE:-100}"
elif [[ $ep == repos/*/branches/* ]]; then
  if [[ -f $D/faildefault ]]; then line=$(cat "$D/faildefault"); [[ -n $line ]] || line='500~~{"message":"Server Error"}'; reply_line "$line"; fi
  reply 200 '' "{\"commit\":{\"sha\":\"$(cat "$D/default_sha")\"}}"
elif [[ $ep == repos/*/contents/* ]]; then
  p=${ep#*/contents/}; p=${p%%\?*}
  echo "$p" >> "$D/fetched"
  inject contents
  if [[ -f $D/contents.404 ]] && grep -qxF -- "$p" "$D/contents.404"; then reply 404 '' '{"message":"Not Found"}'; fi
  reply 200 '' 'x'
elif [[ $ep =~ ^repos/[^/]+/[^/?]+$ ]]; then
  if [[ -f $D/faildefault ]]; then line=$(cat "$D/faildefault"); [[ -n $line ]] || line='500~~{"message":"Server Error"}'; reply_line "$line"; fi
  reply 200 '' "{\"default_branch\":\"$(cat "$D/default_branch")\"}"
else
  echo "fake gh: unexpected call: $method $ep" >&2; exit 1
fi
FAKEGH_EOF
chmod +x "$FAKEGH/bin/gh"
cat > "$FAKEGH/bin/clock" <<'CLOCK'
#!/usr/bin/env bash
cat "$FAKEGH_DIR/clock"
CLOCK
cat > "$FAKEGH/bin/poll-sleep" <<'SLEEP'
#!/usr/bin/env bash
echo "$1" >> "$FAKEGH_DIR/sleeps"
echo "$(( $(cat "$FAKEGH_DIR/clock") + $1 ))" > "$FAKEGH_DIR/clock"
SLEEP
cat > "$FAKEGH/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
echo "$1" >> "$FAKEGH_DIR/boot.sleeps"
SLEEP
chmod +x "$FAKEGH/bin/clock" "$FAKEGH/bin/poll-sleep" "$FAKEGH/bin/sleep"
SHA=$(printf 'a%.0s' $(seq 40))
snap() { # <n> <jq filter over the fixture runs> -> runs.n.json
  jq -c "$2" "$FX/workflow-runs.json" > "$FAKEGH/runs.$1.json"
}
pubreset() {
  rm -rf "$FAKEGH/by" "$FAKEGH/cursha" "$FAKEGH/pulls.json" "$FAKEGH/default_branch" "$FAKEGH/default_sha" "$FAKEGH/failpulls" "$FAKEGH/faildefault"
  rm -f "$FAKEGH"/runs.*.json "$FAKEGH/runs.cur" "$FAKEGH/prepost" "$FAKEGH"/fail.* "$FAKEGH"/inject.* "$FAKEGH/checkruns.extra.json" "$FAKEGH/failpost" \
    "$FAKEGH/posts.log" "$FAKEGH/runs.count" "$FAKEGH/status.log" "$FAKEGH/status.reads" "$FAKEGH/failstatus" "$FAKEGH/badstatus" \
    "$FAKEGH/contents.404" "$FAKEGH/fetched" "$FAKEGH/boot.sleeps" "$WORK/gho" "$FAKEGH/lands500" "$FAKEGH/landscut" "$FAKEGH"/total.*
  cp "$FX/jobs.json" "$FAKEGH/jobs.json"
  cp "$FX/profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"
}
publish() { # [VAR=value ...] -> RC, NPOSTS, POSTS (state<TAB>description<TAB>sha lines), CALLS (runs listings)
  : > "$FAKEGH/posts.log"; : > "$FAKEGH/calls.log"; : > "$FAKEGH/sleeps"; : > "$WORK/gho"
  rm -f "$FAKEGH/runs.count"; rm -rf "$WORK/pw"
  echo "${CLOCK0:-0}" > "$FAKEGH/clock"   # CLOCK0=<epoch> publish ... starts the fake clock there
  PUBOUT=$(env PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" REPO=example/repo HEAD_SHA="$SHA" CONTEXT=CI/gate \
    TIMEOUT_MINUTES=180 GATE_NAME='CI gate' SUITE="$SUITE_DIR" WORK="$WORK/pw" CI_GATE_NOW="$NOW" \
    CI_GATE_BACKOFF_MAX_SECONDS=0 CI_GATE_JITTER=0 CI_GATE_CLOCK="$FAKEGH/bin/clock" CI_GATE_SLEEP="$FAKEGH/bin/poll-sleep" \
    GITHUB_OUTPUT="$WORK/gho" GITHUB_STEP_SUMMARY="$WORK/gss" "$@" bash "$SUITE_DIR/scripts/ci-gate-publish.sh" 2>&1)
  RC=$?
  NPOSTS=$(grep -c . "$FAKEGH/posts.log"); POSTS=$(cat "$FAKEGH/posts.log"); CALLS=$(cat "$FAKEGH/runs.count" 2>/dev/null || echo 0)
}
post_n() { sed -n "${1}p" "$FAKEGH/posts.log"; }
has_published() { grep -qx 'published=true' "$WORK/gho" 2> /dev/null && echo 1 || echo 0; }
ncalls() { grep -c -- "$1" "$FAKEGH/calls.log" || true; }   # requests whose "METHOD endpoint" contains the text
sleeps() { paste -sd, "$FAKEGH/sleeps"; }
RERUN='map(if .id == 12 then .status = "in_progress" | .run_attempt = 2 else . end)'
DONE='.'
UNAVAIL_DESC='ci-gate: GitHub API rate-limited or unavailable; re-evaluating later'

pubreset; snap 1 "$DONE"; publish
chk "everything passed: one POST" "$NPOSTS" 1
chk "everything passed: success" "$(post_n 1 | cut -f1)" success
chk "everything passed: exit 0" "$RC" 0
chk "everything passed: three run listings (snapshot, guard, post-write verify)" "$CALLS" 3
chk "everything passed: ONE check-runs listing (the snapshot), joined on check suite id" "$(ncalls '/check-runs?')" 1
chk "everything passed: the jobs of a run are never listed" "$(ncalls '/jobs')" 0
chk "everything passed: no 'actions/runs/<id>' request of any kind" "$(grep -c 'actions/runs/' "$FAKEGH/calls.log" || true)" 0
[ -s "$WORK/gho" ] && grep -q '^published=true$' "$WORK/gho" && ok "published=true written" || bad "published=true not written"

pubreset; snap 1 "$RERUN"; publish
chk "a run is active: pending, one POST" "$(post_n 1 | cut -f1)/$NPOSTS" "pending/1"
chk "pending is a normal wait: exit 0" "$RC" 0
chk "the publisher writes no 're-run started' of its own (the in_progress start was removed)" "$(post_n 1 | cut -f2 | grep -c 're-run started')" 0

echo "-- two reads per evaluation, whatever the number of workflows --"
# N workflows with two jobs each ("wN / build", "wN / test", like a reusable workflow's jobs), N=22 as on resource-algebra#50
many() { # <workflows> -> runs.1.json, jobs.json and the profile for N workflows; the profile requires every job
  local n=$1
  jq -nc --argjson n "$n" '[range(1; $n + 1) | {id: (. + 100), check_suite_id: (. + 9100), name: "Workflow \(.)", workflow_id: ., event: "pull_request", run_attempt: 1, status: "completed", conclusion: "success", created_at: "2026-11-17T10:00:00Z", updated_at: "2026-11-17T10:05:00Z", path: ".github/workflows/w\(.).yml"}]' > "$FAKEGH/runs.1.json"
  jq -nc --argjson n "$n" '[range(1; $n + 1) as $i | ("build", "test") as $j | {id: ($i * 10 + (if $j == "build" then 0 else 1 end)), name: "w\($i) / \($j)", status: "completed", conclusion: "success", run: {id: ($i + 100), name: "Workflow \($i)", status: "completed"}}]' > "$FAKEGH/jobs.json"
  jq -n --argjson n "$n" '{checks: ([range(1; $n + 1) as $i | ("build", "test") as $j | {job: "w\($i) / \($j)", workflow: ".github/workflows/w\($i).yml"}] | sort_by([.workflow, .job])), repository: "example/repo", schema_version: 2}' > "$SUITE_DIR/profiles/ci-gate/example/repo.json"
}
pubreset; many 22; publish
chk "22 workflows, 44 required jobs: success, exit 0" "$RC/$(post_n 1 | cut -f1)" "0/success"
chk "22 workflows: the description counts all 44 required checks" "$(post_n 1 | cut -f2)" "all 44 required checks passed"
chk "22 workflows: 3 run listings and 1 check-runs listing, no other read but the one status read" "$(ncalls 'actions/runs?head_sha')/$(ncalls '/check-runs?')/$(ncalls '/status?')/$(ncalls '/jobs')" "3/1/1/0"
C22=$(wc -l < "$FAKEGH/calls.log")
pubreset; many 2; publish
chk "2 workflows: the same requests as 22 (the number of workflows does not change the call count)" "$(wc -l < "$FAKEGH/calls.log")" "$C22"
echo "-- exactly 2 logical reads: gate_read_snapshot, 22 workflows, check runs on 2 pages --"
pubreset; many 22
# shellcheck source=/dev/null
(
  export PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" CHECKS_PAGE_SIZE=25 CI_GATE_BACKOFF_MAX_SECONDS=0
  source "$SUITE_DIR/scripts/ci-gate-lib.sh"; : > "$FAKEGH/calls.log"
  gate_read_snapshot example/repo "$SHA" "$WORK" "$SUITE_DIR/profiles/ci-gate/join-checks.jq"; echo $? > "$WORK/snap.rc"
)
chk "snapshot of 22 workflows (44 check runs, pages of 25): ok" "$(cat "$WORK/snap.rc")" 0
chk "snapshot: 1 request for the runs and 2 for the check runs (page 1 and 2): the two reads, one extra page" "$(ncalls 'actions/runs?head_sha')/$(ncalls '/check-runs?')/$(wc -l < "$FAKEGH/calls.log")" "1/2/3"
chk "snapshot: the second page was asked for with page=2 and the first with page=1" "$(grep -c 'check-runs?.*page=1$' "$FAKEGH/calls.log")/$(grep -c 'check-runs?.*page=2$' "$FAKEGH/calls.log")" "1/1"
chk "snapshot: both pages of check runs reached the join (44 jobs, from workflow runs 101..122)" "$(jq 'length' "$WORK/jobs.json")/$(jq '[.[].run.id] | unique | length' "$WORK/jobs.json")" "44/22"
chk "snapshot: the join rebuilt the 'caller / called' contexts and the workflow path" "$(jq -r '[.[] | select(.run.id == 105)] | map("\(.name)@\(.run.path)") | join(",")' "$WORK/jobs.json")" "w5 / build@.github/workflows/w5.yml,w5 / test@.github/workflows/w5.yml"
pubreset; many 22; publish CHECKS_PAGE_SIZE=25 RUNS_PAGE_SIZE=10
chk "pagination end to end (runs 3 pages, check runs 2 pages): success, all 44 checks counted" "$RC/$(post_n 1 | cut -f2)" "0/all 44 required checks passed"
chk "pagination end to end: snapshot 3+2 requests, then guard and verify 3 run pages each" "$(ncalls 'actions/runs?head_sha')/$(ncalls '/check-runs?')" "9/2"
echo "-- the join feeds the verdict: missing, failed, and zero matches --"
pubreset; many 22; jq 'map(select(.name != "w5 / test"))' "$FAKEGH/jobs.json" > "$FAKEGH/jobs.tmp" && mv "$FAKEGH/jobs.tmp" "$FAKEGH/jobs.json"; publish
chk "a required check run missing from the check-runs listing: pending (the next completion or the sweep re-evaluates)" "$RC/$(post_n 1 | cut -f1)/$(post_n 1 | cut -f2)" "0/pending/not yet reported: w5.yml:w5 / test"
pubreset; many 22; jq 'map(if .name == "w7 / build" then .conclusion = "failure" else . end)' "$FAKEGH/jobs.json" > "$FAKEGH/jobs.tmp" && mv "$FAKEGH/jobs.tmp" "$FAKEGH/jobs.json"; publish
chk "a required check run failed: failure, exit 1, names it" "$RC/$(post_n 1 | cut -f1)/$(post_n 1 | cut -f2)" "1/failure/failed: w7.yml:w7 / build (failure)"
for c in cancelled timed_out action_required skipped; do
  pubreset; many 22; jq --arg c "$c" 'map(if .name == "w7 / build" then .conclusion = $c else . end)' "$FAKEGH/jobs.json" > "$FAKEGH/jobs.tmp" && mv "$FAKEGH/jobs.tmp" "$FAKEGH/jobs.json"; publish
  chk "a required check run concluded $c: failure, fail closed" "$RC/$(post_n 1 | cut -f1)" "1/failure"
done
pubreset; many 22; jq 'map(if .name == "w7 / build" then .status = "in_progress" | .conclusion = null else . end)' "$FAKEGH/jobs.json" > "$FAKEGH/jobs.tmp" && mv "$FAKEGH/jobs.tmp" "$FAKEGH/jobs.json"
jq 'map(if .id == 107 then .status = "in_progress" | .conclusion = null else . end)' "$FAKEGH/runs.1.json" > "$FAKEGH/runs.tmp" && mv "$FAKEGH/runs.tmp" "$FAKEGH/runs.1.json"; publish
chk "a required check run in progress (its run active): pending" "$RC/$(post_n 1 | cut -f1)/$(post_n 1 | cut -f2)" "0/pending/waiting for 1 workflow runs: Workflow 7"
pubreset; many 22; jq -n '[]' > "$FAKEGH/jobs.json"; publish
chk "zero check runs at all: not success, pending" "$RC/$(post_n 1 | cut -f1)" "0/pending"
pubreset; many 22; echo '[]' > "$FAKEGH/jobs.json"
jq -nc '[{id: 1, name: "w1 / build", status: "completed", conclusion: "success", check_suite: {id: 4242}, app: {slug: "github-actions"}}, {id: 2, name: "SonarCloud", status: "completed", conclusion: "success", check_suite: {id: 777}, app: {slug: "sonarqubecloud"}}]' > "$FAKEGH/checkruns.extra.json"; publish
chk "check runs of suites that belong to no workflow run (a third-party spoof of a required name): zero matches, not success" "$RC/$(post_n 1 | cut -f1)" "0/pending"
echo "-- a third-party check named like a required job never satisfies it; the Actions check does --"
pubreset; many 22; jq 'map(select(.name != "w1 / build"))' "$FAKEGH/jobs.json" > "$FAKEGH/jobs.tmp" && mv "$FAKEGH/jobs.tmp" "$FAKEGH/jobs.json"
jq -nc '[{id: 4242, name: "w1 / build", status: "completed", conclusion: "success", check_suite: {id: 4242}, app: {slug: "sonarqubecloud"}}, {id: 777, name: "SonarCloud", status: "completed", conclusion: "success", check_suite: {id: 777}, app: {slug: "sonarqubecloud"}}]' > "$FAKEGH/checkruns.extra.json"; publish
chk "the other 43 required jobs succeed; a third-party 'w1 / build' in an unmatched suite: w1 / build is the ONLY missing check, pending" "$RC/$(post_n 1 | cut -f1)/$(post_n 1 | cut -f2)" "0/pending/not yet reported: w1.yml:w1 / build"
chk "the third-party check is in the check-runs listing (43 + 2 check runs) and still not counted" "$(jq 'length' "$FAKEGH/jobs.json")" 43
jq '. + [{id: 10, name: "w1 / build", status: "completed", conclusion: "success", run: {id: 101, name: "Workflow 1", status: "completed"}}]' "$FAKEGH/jobs.json" > "$FAKEGH/jobs.tmp" && mv "$FAKEGH/jobs.tmp" "$FAKEGH/jobs.json"; publish
chk "the legitimate Actions check 'w1 / build' (a suite of a workflow run) is added: all 44 pass, success" "$RC/$(post_n 1 | cut -f1)/$(post_n 1 | cut -f2)" "0/success/all 44 required checks passed"

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
chk "verification costs one more run listing per write (3 + 3 listings)" "$CALLS" 6
chk "settled after the correction: exit 0" "$RC" 0
echo "-- the post-write verification is bounded at 5 rounds --"
pubreset; for i in $(seq 1 3 16); do snap "$i" "map(.updated_at = \"g$i\")"; snap $((i+1)) "map(.updated_at = \"g$i\")"; snap $((i+2)) "map(.updated_at = \"v$i\")"; done
publish
chk "guard passes but the verify always moves: one success POST (the 4 repeats are skipped as unchanged), then one pending" "$NPOSTS" 2
chk "the 4 repeated identical success writes were skipped, not posted" "$(grep -c 'write skipped' <<<"$PUBOUT")" 4
chk "the last write is pending 'runs still changing'" "$(post_n 2 | cut -f1,2)" "$(printf 'pending\truns still changing')"
chk "no write after round 5 other than that pending; still 5 rounds, 15 listings" "$CALLS" 15
chk "bounded: exit 0 (pending), never success last" "$RC" 0
echo "-- the runs never stabilise --"
pubreset; for i in $(seq 1 14); do snap "$i" "map(.updated_at = \"t$i\")"; done
publish
chk "never stable: one POST" "$NPOSTS" 1
chk "never stable: pending" "$(post_n 1 | cut -f1)" pending
chk "never stable: 'runs still changing'" "$(post_n 1 | cut -f2)" "runs still changing"
chk "never stable: 5 rounds, two listings each" "$CALLS" 10
chk "never stable: never success, exit 0" "$RC" 0
echo "-- a late evaluator cannot leave a stale failure either --"
pubreset; snap 1 "$DONE"; snap 2 "map(if .id == 11 then .status = \"in_progress\" else . end)"
jq 'map(if .name == "Test" then .conclusion = "failure" else . end)' "$FX/jobs.json" > "$FAKEGH/jobs.json"
snap 3 "$DONE"
publish
chk "stale failure not written when the runs moved; re-evaluated: failure on settled data" "$(post_n 1 | cut -f1)" failure
chk "failure verdict: exit 1" "$RC" 1
chk "failure verdict: names the job" "$(post_n 1 | cut -f2 | grep -c 'Test (failure)')" 1

echo "-- a real error fails closed; an unavailable API never does --"
pubreset; snap 1 "$DONE"; echo '404~~{"message":"Not Found"}' > "$FAKEGH/inject.runs"; publish
chk "404 on the first runs listing (a real error): a failure POST" "$(post_n 1 | cut -f1)" failure
chk "404: exit 1, one POST, no back-off" "$RC/$NPOSTS/$(sleeps)" "1/1/"
pubreset; snap 1 "$DONE"; echo '404~~{"message":"Not Found"}' > "$FAKEGH/inject.checks"; publish
chk "404 on the check-runs listing: a failure POST, exit 1" "$(post_n 1 | cut -f1)/$RC" "failure/1"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/fail.1"; publish
chk "HTTP 500 on the first runs listing (unavailable, no back-off budget): pending, NOT failure" "$(post_n 1 | cut -f1,2 | tr '\t' '|')/$NPOSTS" "pending|$UNAVAIL_DESC/1"
chk "unavailable: exit 75, published=true and unavailable=true written" "$RC/$(grep -c '^published=true$' "$WORK/gho")/$(grep -c '^unavailable=true$' "$WORK/gho")" "75/1/1"
chk "unavailable: a ::warning:: says it is not a failure" "$(grep -c '^::warning::.*NOT failure' <<<"$PUBOUT")" 1
pubreset; snap 1 "$DONE"; touch "$FAKEGH/fail.2"; publish
chk "HTTP 500 on the guard listing: pending, never failure, exit 75" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$RC" "pending/75"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/fail.3"; publish
chk "HTTP 500 on the post-write listing: the success cannot stand unverified: success, then pending, exit 75" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$RC" "success,pending/75"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/failpost"; publish
chk "every status POST fails: exit 1, nothing posted, and loudly no failure" "$RC/$NPOSTS/$(grep -c 'NO FAILURE WAS POSTED' <<<"$PUBOUT")" "1/0/1"
chk "every status POST fails: no published=true" "$(has_published)" 0
pubreset; snap 1 "$DONE"; rm -f "$SUITE_DIR/profiles/ci-gate/example/repo.json"; publish
chk "no profile: a failure POST, exit 1" "$(post_n 1 | cut -f1)/$RC" "failure/1"
cp "$FX/profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"
pubreset; snap 1 "$DONE"; publish HEAD_SHA=abc
chk "a head SHA that is not 40 hex: exit 1, no POST" "$RC/$NPOSTS" "1/0"
pubreset

echo "== back-off: Retry-After, x-ratelimit-reset, exponential, a bound, and a real 403 =="
RL='{"message":"API rate limit exceeded for installation. If you reach out to GitHub Support for help, please include the request ID."}'
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 7~$RL" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "429 with Retry-After: 7: sleeps exactly 7 s, then succeeds" "$(sleeps)/$RC/$(post_n 1 | cut -f1)" "7/0/success"
chk "429: the wait is logged" "$(grep -c 'waiting 7s' <<<"$PUBOUT")" 1
pubreset; snap 1 "$DONE"; echo "403~x-ratelimit-remaining: 0|x-ratelimit-reset: 40~$RL" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "403 rate limit with x-ratelimit-reset 40 (clock 0): waits until the reset (41 s), then succeeds" "$(sleeps)/$RC/$(post_n 1 | cut -f1)" "41/0/success"
pubreset; snap 1 "$DONE"; echo "403~x-ratelimit-remaining: 0|x-ratelimit-reset: 40|Retry-After: 5~$RL" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "Retry-After wins over x-ratelimit-reset" "$(sleeps)" "5"
pubreset; snap 1 "$DONE"; echo '403~~{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}' > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "403 'secondary rate limit' with no headers (budget left): backs off from 60 s, then succeeds" "$(sleeps)/$RC" "60/0"
pubreset; snap 1 "$DONE"; echo '403~x-ratelimit-remaining: 0~{"message":"Forbidden"}' > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "403 with x-ratelimit-remaining: 0 and no body hint is a rate limit too" "$(sleeps)/$RC" "2/0"
pubreset; snap 1 "$DONE"; { echo '503~~{"message":"unavailable"}'; echo '502~~{}'; echo '500~~{}'; } > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "5xx three times: exponential 2, 4, 8 s (no jitter), then succeeds" "$(sleeps)/$RC" "2,4,8/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 30~$RL" > "$FAKEGH/inject.always.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=70
chk "a rate limit that persists: waits 30 + 30, then the next 30 s would pass the 70 s bound: gives up" "$(sleeps)" "30,30"
chk "persistent rate limit: posts PENDING with the API-unavailable reason" "$(post_n 1 | cut -f1,2 | tr '\t' '|')" "pending|$UNAVAIL_DESC"
chk "persistent rate limit: NEVER a failure; exactly one POST; exit 75" "$(cut -f1 "$FAKEGH/posts.log" | sort -u | paste -sd, -)/$NPOSTS/$RC" "pending/1/75"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a known wait that overruns the bound is not slept at all: gives up at once, pending" "$(sleeps)/$(post_n 1 | cut -f1)/$RC" "/pending/75"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; publish
chk "CI_GATE_BACKOFF_MAX_SECONDS=0 (the tests' default): a throttle gives up at once: pending, no sleep" "$(sleeps)/$(post_n 1 | cut -f1)/$RC" "/pending/75"
pubreset; snap 1 "$DONE"; echo '403~~{"message":"Resource not accessible by integration"}' > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a 403 that is not a rate limit (a permissions problem) is a real error: no sleep" "$(sleeps)" ""
chk "a real 403: failure POST naming the HTTP status, exit 1" "$(post_n 1 | cut -f1)/$(post_n 1 | cut -f2 | grep -c 'HTTP 403')/$RC" "failure/1/1"
pubreset; snap 1 "$DONE"; echo "403~~$RL" > "$FAKEGH/inject.always.checks"; publish CI_GATE_BACKOFF_MAX_SECONDS=0
chk "the same budget covers the second read: pending, never failure" "$(post_n 1 | cut -f1)/$RC" "pending/75"
echo "-- the status write is retried too --"
pubreset; snap 1 "$DONE"; echo "403~Retry-After: 3~$RL" > "$FAKEGH/inject.post"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a rate-limited status POST is retried after Retry-After and then lands: one success status" "$(sleeps)/$NPOSTS/$(post_n 1 | cut -f1)/$RC" "3/1/success/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; echo "429~Retry-After: 2~$RL" > "$FAKEGH/inject.post"; publish CI_GATE_BACKOFF_MAX_SECONDS=60
chk "the pending write is itself rate-limited once: retried with back-off, then posted (pending, exit 75)" "$(sleeps)/$NPOSTS/$(post_n 1 | cut -f1)/$RC" "2/1/pending/75"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; echo "429~Retry-After: 5~$RL" > "$FAKEGH/inject.always.post"; publish CI_GATE_BACKOFF_MAX_SECONDS=20
chk "the pending write stays rate-limited: its own budget (4 x 5 s) is used, then exit 1" "$(sleeps)/$RC" "5,5,5,5/1"
chk "the pending write failed: NOTHING is posted, and in particular no failure" "$NPOSTS" 0
chk "the pending write failed: a loud error says no failure was posted" "$(grep -c '^::error::.*NO FAILURE WAS POSTED' <<<"$PUBOUT")" 1
chk "the pending write failed: published=true is not claimed" "$(has_published)" 0
pubreset

echo "-- the pull_request start: one pending, one evaluation, no wait --"
pubreset; snap 1 "$DONE"; publish EVENT_NAME=pull_request
chk "pull_request, all green: pending first, then success" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$RC" "pending,success/0"
chk "pull_request: the first status is 'waiting for the required checks to report'" "$(post_n 1 | cut -f2)" "waiting for the required checks to report"
chk "pull_request: no sleeping, no polling (3 run listings, as one evaluation)" "$(sleeps)/$CALLS/$(grep -c '^wait: ' <<<"$PUBOUT")" "/3/0"
NOQ='map(select(.name != "CI quality"))'   # CI quality produces the required jobs Lint and Test
pubreset; snap 1 "$NOQ"; jq 'map(select(.run.id != 12))' "$FX/jobs.json" > "$FAKEGH/jobs.json"; publish EVENT_NAME=pull_request
chk "pull_request, required checks not reported yet: pending, pending (never a failure), exit 0" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$RC" "pending,pending/0"
chk "pull_request, not reported yet: the verdict names what is missing" "$(post_n 2 | cut -f2)" "not yet reported: ci-quality.yml:Lint, ci-quality.yml:Test"
chk "pull_request, not reported yet: ONE evaluation and exit (3 run listings, no sleep, no second snapshot round)" "$CALLS/$(sleeps)" "3/"
chk "pull_request: the gate never waits (no WAIT/POLL loop ran)" "$(grep -c 'polling again\|^wait:' <<<"$PUBOUT")" 0
pubreset; snap 1 "$NOQ"; jq 'map(select(.run.id != 12))' "$FX/jobs.json" > "$FAKEGH/jobs.json"
printf '%s\tCI/gate\tpending\twaiting for the required checks to report\n' "$SHA" > "$FAKEGH/status.log"; publish EVENT_NAME=pull_request
chk "pull_request, the same pending already stands: that write is skipped (deduped); only the verdict is posted" "$NPOSTS/$(post_n 1 | cut -f2)" "1/not yet reported: ci-quality.yml:Lint, ci-quality.yml:Test"
pubreset; snap 1 "$DONE"; publish EVENT_NAME=workflow_run
chk "workflow_run: no initial pending, only the verdict" "$NPOSTS/$(post_n 1 | cut -f1)" "1/success"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.post"; publish EVENT_NAME=pull_request
chk "pull_request, the pending write is rate-limited past the bound: exit 1, no failure, nothing posted" "$RC/$NPOSTS" "1/0"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/fail.1"; publish EVENT_NAME=pull_request
chk "pull_request, the API is down at the read: pending, then pending (API unavailable); never failure" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$RC" "pending,pending/75"

echo "== the back-off, refined: every 5xx, Retry-After as an HTTP-date, decimal parsing, secondary limits =="
pubreset; snap 1 "$DONE"; echo '505~~{"message":"HTTP Version Not Supported"}' > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "HTTP 505 is transient like every 5xx: retried after 2 s, then succeeds" "$(sleeps)/$RC/$(post_n 1 | cut -f1)" "2/0/success"
pubreset; snap 1 "$DONE"; echo '599~~{}' > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "HTTP 599 is transient as well" "$(sleeps)/$RC" "2/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: $(LC_ALL=C date -u -d @30 '+%a, %d %b %Y %H:%M:%S GMT')~$RL" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "Retry-After as an HTTP-date 30 s ahead of the clock: sleeps 30 s, then succeeds" "$(sleeps)/$RC" "30/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: $(LC_ALL=C date -u -d @-100 '+%a, %d %b %Y %H:%M:%S GMT')~$RL" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "Retry-After as an HTTP-date in the past: the delay is clamped to 1 s" "$(sleeps)/$RC" "1/0"
pubreset; snap 1 "$DONE"; echo "503~Retry-After: Someday, whenever~{}" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "an invalid Retry-After falls back to the exponential delay (2 s)" "$(sleeps)/$RC" "2/0"
pubreset; snap 1 "$DONE"; echo "503~Retry-After: Wed, 99 Foo 2015 07:28:00 GMT~{}" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "an HTTP-date-shaped but impossible Retry-After falls back to the exponential delay (2 s)" "$(sleeps)/$RC" "2/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 000010~$RL" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "Retry-After 000010 is decimal ten (not octal): sleeps 10 s" "$(sleeps)/$RC" "10/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 08~$RL" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "Retry-After 08 (an invalid octal digit) is decimal eight: sleeps 8 s, no arithmetic error" "$(sleeps)/$RC" "8/0"
pubreset; snap 1 "$DONE"; echo "403~x-ratelimit-remaining: 0|x-ratelimit-reset: 000040~$RL" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "x-ratelimit-reset 000040 is decimal forty: waits until the reset (41 s)" "$(sleeps)/$RC" "41/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 99999999999999999999~$RL" > "$FAKEGH/inject.always.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "an absurdly long Retry-After is bounded, overruns the budget and gives up at once: pending, exit 75, no sleep" "$(sleeps)/$RC/$(post_n 1 | cut -f1)" "/75/pending"
echo "-- a secondary rate limit: x-ratelimit-reset only when remaining is 0; else 60 s, doubling, no early retry --"
pubreset; snap 1 "$DONE"; echo "429~x-ratelimit-remaining: 4000|x-ratelimit-reset: 40~$RL" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "429 with budget left (remaining 4000), a reset header and no Retry-After: the reset is ignored, backs off 60 s, then succeeds" "$(sleeps)/$RC" "60/0"
pubreset; snap 1 "$DONE"; { echo "429~x-ratelimit-remaining: 4000~$RL"; echo "429~x-ratelimit-remaining: 4000~$RL"; } > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a repeated secondary limit doubles: 60 s then 120 s" "$(sleeps)/$RC" "60,120/0"
pubreset; snap 1 "$DONE"; echo "429~x-ratelimit-remaining: 4000~$RL" > "$FAKEGH/inject.always.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=30
chk "the remaining budget (30 s) cannot cover 60 s: returns 75 at once, no early retry (no sleep), pending, never failure" "$(sleeps)/$RC/$(post_n 1 | cut -f1,2 | tr '\t' '|')" "/75/pending|$UNAVAIL_DESC"
pubreset; snap 1 "$DONE"; echo "403~x-ratelimit-remaining: 12~$RL" > "$FAKEGH/inject.always.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=59
chk "a rate-limit 403 with remaining > 0 and a 59 s budget: 75 at once, no sleep" "$(sleeps)/$RC" "/75"
pubreset; snap 1 "$DONE"; echo "403~x-ratelimit-remaining: 0|x-ratelimit-reset: 40~$RL" > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "remaining 0 with a reset header still waits for the reset (41 s)" "$(sleeps)/$RC" "41/0"

echo "== listings are validated: one JSON document of the expected shape per page =="
read_runs() { # -> LOUT "<rc>|<GATE_API_ERR or the page as compact JSON>": gate_read_runs from the repository's library, one request, no back-off
  LOUT=$( ( export PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" CI_GATE_BACKOFF_MAX_SECONDS=0 CI_GATE_CLOCK="$FAKEGH/bin/clock" GATE_WAITED_FILE="$WORK/lib.waited"
    rm -f "$GATE_WAITED_FILE"
    # shellcheck source=/dev/null
    source "$ROOT/scripts/ci-gate-lib.sh"; gate_read_runs example/repo "$SHA" "$WORK/pg.json"; rc=$?
    if ((rc == 0)); then echo "0|$(jq -c . "$WORK/pg.json")"; else echo "$rc|$GATE_API_ERR"; fi ) 2>&1 )
}
RUNSEMPTY='{"total_count":0,"workflow_runs":[]}'
pubreset; echo "200~~" > "$FAKEGH/inject.runs"; read_runs
chk "a blank 200 body is an error (1, unusable response body), never an empty listing" "${LOUT%%|*}/$(grep -c 'unusable response body' <<<"$LOUT")" "1/1"
for body in '{not json' '[]' '{"total_count":0,"workflow_runs":{}}' "$RUNSEMPTY $RUNSEMPTY" '"text"'; do
  pubreset; echo "200~~$body" > "$FAKEGH/inject.runs"; read_runs
  chk "a 200 body that is not exactly one runs document ($body): error 1, unusable response body" "${LOUT%%|*}/$(grep -c 'unusable response body' <<<"$LOUT")" "1/1"
done
pubreset; echo "200~~$RUNSEMPTY" > "$FAKEGH/inject.runs"; read_runs
chk "a valid empty page still succeeds and yields []" "$LOUT" "0|[]"
pubreset; snap 1 "$DONE"; echo "200~~" > "$FAKEGH/inject.checks"; publish
chk "a blank check-runs page through the publisher is a real error (a failure status), never 'no checks reported'" "$(post_n 1 | cut -f1)/$RC/$(grep -c 'unusable response body' <<<"$PUBOUT")" "failure/1/1"
pubreset; snap 1 "$DONE"; echo "200~~not json" > "$FAKEGH/inject.runs"; publish
chk "a malformed runs page through the publisher is a failure, exit 1 (fail closed on a real error)" "$(post_n 1 | cut -f1)/$RC" "failure/1"

echo "== an incomplete snapshot (total_count above the items returned) is unavailable, never a missing check =="
pubreset; snap 1 "$DONE"; echo 1500 > "$FAKEGH/total.workflow_runs"; publish
chk "runs: total_count 1500 but 4 returned (GitHub's 1000-result cap): pending with the unavailable reason, exit 75, no failure" "$(cut -f1,2 "$FAKEGH/posts.log" | tr '\t' '|')/$RC" "pending|$UNAVAIL_DESC/75"
chk "runs: the warning says the snapshot is incomplete" "$(grep -c 'snapshot incomplete' <<<"$PUBOUT")" 1
chk "runs: an incomplete runs listing stops before any check-runs read" "$(ncalls '/check-runs?')" 0
pubreset; snap 1 "$DONE"; echo 1200 > "$FAKEGH/total.check_runs"; publish
chk "check runs: total_count 1200 but fewer returned (the 1000 most recent check suites): pending, exit 75, no failure" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$RC" "pending/75"
chk "check runs: the reason names total_count and what was returned" "$(grep -c 'snapshot incomplete.*total_count 1200 but only' <<<"$PUBOUT")" 1
pubreset; snap 1 "$DONE"; echo 2 > "$FAKEGH/total.check_runs"; publish
chk "a total_count BELOW the items returned is not incomplete: success as usual" "$RC/$(post_n 1 | cut -f1)" "0/success"
pubreset; many 22; echo 100 > "$FAKEGH/total.check_runs"; publish CHECKS_PAGE_SIZE=25
chk "incomplete over several pages (44 check runs returned of 100 reported): pending, never 'not yet reported'" "$(cut -f1,2 "$FAKEGH/posts.log" | tr '\t' '|')/$RC" "pending|$UNAVAIL_DESC/75"
pubreset

echo "== a status POST with an unknown outcome is rechecked before it is replayed =="
pubreset; snap 1 "$DONE"; touch "$FAKEGH/lands500"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "the POST landed but answered 500: the standing status is rechecked, found, and NOT replayed: one success POST, exit 0, no sleep" "$NPOSTS/$(post_n 1 | cut -f1)/$RC/$(sleeps)" "1/success/0/"
chk "the recheck is one more status read (dedupe + recheck)" "$(wc -l < "$FAKEGH/status.reads")" 2
pubreset; snap 1 "$DONE"; touch "$FAKEGH/lands500"; publish CI_GATE_BACKOFF_MAX_SECONDS=0
chk "the recheck works with no back-off budget at all: success, exit 0, never replayed, no pending written" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/success/0"
pubreset; snap 1 "$DONE"; echo '500~~{"message":"Server Error"}' > "$FAKEGH/inject.post"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a 500 that did NOT land: the recheck says differs, the POST is replayed after 2 s and lands (one status)" "$(sleeps)/$NPOSTS/$(post_n 1 | cut -f1)/$RC/$(wc -l < "$FAKEGH/status.reads")" "2/1/success/0/2"
pubreset; snap 1 "$DONE"; echo "403~Retry-After: 3~$RL" > "$FAKEGH/inject.post"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "an explicit rate-limit rejection (403) is retried and NOT rechecked (no extra status read)" "$(sleeps)/$NPOSTS/$(wc -l < "$FAKEGH/status.reads")" "3/1/1"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 2~$RL" > "$FAKEGH/inject.post"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "an explicit 429 is retried and NOT rechecked either" "$(sleeps)/$NPOSTS/$(wc -l < "$FAKEGH/status.reads")" "2/1/1"
pubreset; snap 1 "$DONE"; echo '500~~{}' > "$FAKEGH/inject.always.post"; publish CI_GATE_BACKOFF_MAX_SECONDS=0
chk "a 5xx POST that never lands, no budget: unavailable, pending attempted (also refused): exit 1, nothing posted, no failure" "$RC/$NPOSTS" "1/0"

echo "== the pending write for an outage: its dedupe lookup spends none of the reserved budget =="
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; echo "429~Retry-After: 5~$RL" > "$FAKEGH/inject.always.status"; echo "429~Retry-After: 2~$RL" > "$FAKEGH/inject.post"; publish CI_GATE_BACKOFF_MAX_SECONDS=20
chk "the dedupe lookup is rate-limited (Retry-After 5): ONE attempt, no sleep; then the pending POST (itself limited once, Retry-After 2) still has its full budget" "$(sleeps)/$(wc -l < "$FAKEGH/status.reads")/$NPOSTS/$(post_n 1 | cut -f1,2 | tr '\t' '|')/$RC" "2/1/1/pending|$UNAVAIL_DESC/75"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; printf '%s\tCI/gate\tpending\t%s\n' "$SHA" "$UNAVAIL_DESC" > "$FAKEGH/status.log"; publish CI_GATE_BACKOFF_MAX_SECONDS=20
chk "the lookup at once finds the same pending: the write is skipped (no POST), still exit 75, one status read" "$NPOSTS/$RC/$(wc -l < "$FAKEGH/status.reads")/$(grep -c 'write skipped' <<<"$PUBOUT")" "0/75/1/1"
pubreset

echo "== published=true: the initial pending is not an evaluation write =="
pubreset; snap 1 "$DONE"; { echo ''; echo '403~~{"message":"Resource not accessible by integration"}'; } > "$FAKEGH/inject.post"; echo '404~~{"message":"Not Found"}' > "$FAKEGH/inject.runs"; publish EVENT_NAME=pull_request
chk "pull_request: the initial pending lands, then a real snapshot error whose failure write is refused: exit 1, one POST (the pending)" "$RC/$NPOSTS/$(post_n 1 | cut -f1)" "1/1/pending"
chk "that run did NOT claim published=true, and did not claim unavailable (so the workflow fallback runs)" "$(has_published)/$(grep -c '^unavailable=true$' "$WORK/gho" || true)" "0/0"
pubreset; snap 1 "$DONE"; publish EVENT_NAME=pull_request
chk "pull_request, all green: published=true is written (by the verdict write)" "$(has_published)" 1
pubreset; snap 1 "$DONE"; { echo ''; echo '403~~{"message":"Resource not accessible by integration"}'; echo '403~~{"message":"Resource not accessible by integration"}'; } > "$FAKEGH/inject.post"; publish EVENT_NAME=pull_request
chk "pull_request: the initial pending lands, the verdict write and the failure write are both refused (real error): no published=true" "$RC/$(has_published)" "1/0"
pubreset; snap 1 "$DONE"; echo '404~~{"message":"Not Found"}' > "$FAKEGH/inject.runs"; publish EVENT_NAME=pull_request
chk "pull_request: the initial pending lands, a real snapshot error, the failure write lands: published=true" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$(has_published)" "pending,failure/1"

echo "== workflow_run requested (a re-run starts): one deduplicated pending, no evaluation, never failure or success =="
REQ_DESC='ci-gate: a required workflow is re-running; re-evaluating on completion'
pubreset; snap 1 "$DONE"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=requested
chk "requested: exactly one pending POST with the re-run description, exit 0" "$NPOSTS/$(post_n 1 | cut -f1,2 | tr '\t' '|')/$RC" "1/pending|$REQ_DESC/0"
chk "requested: no run listing, no check-run listing, no jobs: only the status dedupe GET and the one POST" "$(ncalls 'actions/runs')/$(ncalls '/check-runs?')/$(ncalls '/jobs')/$(ncalls '/status?')/$(grep -c . "$FAKEGH/calls.log")" "0/0/0/1/2"
chk "requested: the description is ASCII and at most 140 characters" "$(printf '%s' "$REQ_DESC" | LC_ALL=C grep -c '[^ -~]')/$([ ${#REQ_DESC} -le 140 ] && echo ok)" "0/ok"
chk "requested: published=true is written (the pending is a status write of this evaluation)" "$(has_published)" 1
pubreset; snap 1 "$DONE"; printf '%s\tCI/gate\tpending\t%s\n' "$SHA" "$REQ_DESC" > "$FAKEGH/status.log"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=requested
chk "requested, the same pending already stands: deduplicated, no POST, exit 0" "$NPOSTS/$RC/$(grep -c 'write skipped' <<<"$PUBOUT")" "0/0/1"
pubreset; snap 1 "$DONE"; printf '%s\tCI/gate\tsuccess\tall 3 required checks passed\n' "$SHA" > "$FAKEGH/status.log"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=requested
chk "requested over a standing success: the success is replaced by the re-run pending (the gap this closes)" "$(post_n 1 | cut -f1)/$NPOSTS/$RC" "pending/1/0"
pubreset; snap 1 "$DONE"; rm -f "$SUITE_DIR/profiles/ci-gate/example/repo.json"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=requested
chk "requested with no profile: still only the pending (a missing profile is the completion's failure, never the start's)" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/pending/0"
pubreset; snap 1 "$DONE"; echo '403~~{"message":"Resource not accessible by integration"}' > "$FAKEGH/inject.post"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=requested
chk "requested, a real error on the write: exit 1, NOTHING posted, in particular no failure" "$RC/$NPOSTS/$(grep -c 'NOTHING WAS WRITTEN' <<<"$PUBOUT")" "1/0/1"
chk "requested, a real error: published=true is not claimed" "$(has_published)" 0
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.post"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=requested
chk "requested, the API is unavailable: the same no-failure handling (pending with the unavailable reason, exit 75, unavailable=true)" "$(post_n 1 | cut -f1,2 | tr '\t' '|')/$RC/$(grep -c '^unavailable=true$' "$WORK/gho")" "pending|$UNAVAIL_DESC/75/1"
pubreset; snap 1 "$DONE"; publish EVENT_NAME=pull_request WORKFLOW_RUN_ACTION=requested
chk "requested outside a workflow_run event is refused: exit 1, nothing written" "$RC/$NPOSTS" "1/0"
pubreset; snap 1 "$DONE"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=completed
chk "workflow_run completed evaluates as ever: success after the usual three run listings" "$(post_n 1 | cut -f1)/$CALLS" "success/3"
pubreset
echo "== description sanitiser: no codepoint above U+FFFF, at most 140 characters =="
# shellcheck source=/dev/null
san() { ( source "$SUITE_DIR/scripts/ci-gate-lib.sh"; gate_sanitize "$1" ); }
chk "an emoji is stripped (the statuses API rejects 4-byte Unicode)" "$(san 'build 🔴 passed')" "build  passed"
chk "only emoji: empty" "$(san '🔴🟡🟢')" ""
chk "BMP characters are kept: é and ✓ and a CJK character and an ellipsis" "$(san 'café ✓ 漢 …')" "café ✓ 漢 …"
chk "an emoji next to BMP text: only the emoji goes" "$(san '🔴 GATE: Empty-linter ✓')" " GATE: Empty-linter ✓"
chk "a short description is unchanged" "$(san 'all 3 required checks passed')" "all 3 required checks passed"
chk "exactly 140 characters: unchanged" "$(dlen "$(san "$(printf 'é%.0s' $(seq 1 140))")")" 140
S141=$(san "$(printf 'é%.0s' $(seq 1 141))")
chk "141 characters: 139 + an ellipsis = 140" "$(dlen "$S141")/$(jq -Rr '.[-1:]' <<<"$S141")" "140/…"
S300=$(san "$(printf '✓%.0s' $(seq 1 300))")
chk "300 characters: at most 140, cut between characters (139 whole characters and an ellipsis)" "$(jq -Rr 'if length == 140 and .[0:139] == ("✓" * 139) and .[139:] == "…" then "ok" else "bad" end' <<<"$S300")" ok
S4=$(san "$(printf '🔴%.0s' $(seq 1 50))$(printf 'é%.0s' $(seq 1 200))")
chk "emoji and more than 140 BMP characters: the emoji go first, then 139 + an ellipsis" "$(jq -Rr 'if length == 140 and .[0:139] == ("é" * 139) and .[139:] == "…" then "ok" else "bad" end' <<<"$S4")" ok
chk "no output of the sanitiser has a codepoint above U+FFFF" "$(printf '%s' "$S4$S300$S141" | perl -CSD -0777 -ne 'print(/[\x{10000}-\x{10FFFF}]/ ? "bad" : "ok")')" ok
printf '%s' '🔴 x' | perl -CSD -0777 -ne 'exit(/[\x{10000}-\x{10FFFF}]/ ? 1 : 0)' && bad "control: the fake API accepts a 4-byte description" || ok "control: the fake API (and so this test) detects a 4-byte character"
echo "-- end to end: a required job whose name has an emoji (the shipped profiles have one) --"
jq -n '{checks: [{job: "Build", workflow: ".github/workflows/ci-build.yml"}, {job: "🔴 GATE: Lint", workflow: ".github/workflows/ci-quality.yml"}, {job: "Test", workflow: ".github/workflows/ci-quality.yml"}] | sort_by([.workflow, .job]), repository: "example/repo", schema_version: 2}' > "$WORK/emoji-profile.json"
pubreset; cp "$WORK/emoji-profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"; snap 1 "$DONE"; jq 'map(if .name == "Lint" then .name = "🔴 GATE: Lint" | .conclusion = "failure" else . end)' "$FX/jobs.json" > "$FAKEGH/jobs.json"; publish
chk "a failing emoji-named job: the failure status is accepted by the API (sanitised) and exit is 1" "$RC/$NPOSTS/$(post_n 1 | cut -f1)" "1/1/failure"
chk "the posted description lost the emoji but kept the rest" "$(post_n 1 | cut -f2)" "failed: ci-quality.yml: GATE: Lint (failure)"
pubreset; cp "$WORK/emoji-profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"; snap 1 "$DONE"; jq 'map(select(.name != "Lint"))' "$FX/jobs.json" > "$FAKEGH/jobs.json"; publish
chk "a missing emoji-named job: pending accepted by the API, with the emoji stripped" "$RC/$(post_n 1 | cut -f1)/$(post_n 1 | cut -f2)" "0/pending/not yet reported: ci-quality.yml: GATE: Lint"
cp "$FX/profile.json" "$SUITE_DIR/profiles/ci-gate/example/repo.json"
pubreset

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
pubreset; snap 1 "$DONE"; echo '404~~{"message":"Not Found"}' > "$FAKEGH/inject.runs"; publish CONTEXT='CI / gate'
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
pubreset; snap 1 "$DONE"; echo '404~~{"message":"Not Found"}' > "$FAKEGH/inject.always.runs"; publish
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

echo "== the workflow's steps: library first, no early pending, API outages published as pending =="
step_script() { # <file> <step name prefix> -> the step's run: block, de-indented
  awk -v name="$2" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    inrun { if ($0 ~ /^[[:space:]]*$/ || ind($0) > runcol) { print substr($0, runcol + 3); next } exit }
    index($0, "- name: " name) { want = 1; next }
    want && $0 ~ /^[[:space:]]+run: [|]$/ { runcol = ind($0); inrun = 1 }
  ' "$1"
}
step_line() { grep -n -- "- name: $1" "$WORKFLOW" | head -1 | cut -d: -f1; }
L_LIB=$(step_line 'Read the gate library'); L_REFUSE=$(step_line 'Refuse anything'); L_READ=$(step_line 'Read the profile'); L_VAL=$(step_line 'Validate the profile'); L_EVAL=$(step_line 'Evaluate the commit'); L_FB=$(step_line 'Publish a failure status')
{ [ -n "$L_LIB" ] && [ "$L_LIB" -lt "$L_REFUSE" ] && [ "$L_REFUSE" -lt "$L_READ" ] && [ "$L_READ" -lt "$L_VAL" ] && [ "$L_VAL" -lt "$L_EVAL" ] && [ "$L_EVAL" -lt "$L_FB" ]; } \
  && ok "step order: the library, input validation, the profile fetch, validation, evaluation, the fallback" || bad "step order is wrong ($L_LIB, $L_REFUSE, $L_READ, $L_VAL, $L_EVAL, $L_FB)"
! grep -q 'Mark a started or re-run' "$WORKFLOW" && ! grep -q 're-run started' "$WORKFLOW" && ! grep -q 'EVENT_ACTION' "$WORKFLOW" \
  && ok "the early pending step for in_progress events is gone from the reusable" || bad "the reusable still has an early in_progress pending"
[ "$(grep -cE '^[^#]*in_progress' "$WORKFLOW")" = 3 ] && ok "the reusable mentions in_progress in exactly three code lines: the re-run start paths (fetch, validation skip, failure fallback)" || bad "the reusable mentions in_progress elsewhere than the re-run start paths"
grep -qE "^        if: \\$\\{\\{ failure\\(\\) && steps\\.publish\\.outputs\\.published != 'true' && steps\\.publish\\.outputs\\.unavailable != 'true' && steps\\.read\\.outputs\\.unavailable != 'true' && steps\\.bootstrap\\.outputs\\.unavailable != 'true' \\}\\}" "$WORKFLOW" \
  && ok "the failure fallback runs only when nothing was published and the cause was not an unavailable API" || bad "the failure fallback condition is wrong"
step_script "$WORKFLOW" "Read the gate library" > "$WORK/boot.sh"
[ -s "$WORK/boot.sh" ] && ok "extracted the library bootstrap step" || bad "could not extract the library bootstrap step"
runboot() { # [VAR=value ...] -> BRC; the suite lands in $WORK/bt/tmp/ci-gate-suite
  rm -rf "$WORK/bt"; mkdir -p "$WORK/bt/tmp"; : > "$WORK/bt/genv"; rm -f "$FAKEGH/boot.sleeps" "$FAKEGH/fetched"; : > "$FAKEGH/posts.log"; : > "$FAKEGH/calls.log"
  : > "$WORK/bt/gout"
  env PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" RUNNER_TEMP="$WORK/bt/tmp" GITHUB_ENV="$WORK/bt/genv" GITHUB_OUTPUT="$WORK/bt/gout" \
    WF_REPO=hyperpolymath/proven-cicd-and-workflows WF_SHA="$(printf 'c%.0s' $(seq 40))" "$@" bash "$WORK/boot.sh" > "$WORK/bt/out" 2>&1
  BRC=$?
}
pubreset; runboot
chk "bootstrap: the library is fetched from the suite at the pinned commit, once; suite= is exported" "$BRC/$(cat "$FAKEGH/fetched")/$(cat "$WORK/bt/genv")/$([ -s "$WORK/bt/tmp/ci-gate-suite/scripts/ci-gate-lib.sh" ] && echo yes || echo no)" "0/scripts/ci-gate-lib.sh/suite=$WORK/bt/tmp/ci-gate-suite/yes"
pubreset; echo '503~~{"message":"unavailable"}' > "$FAKEGH/inject.contents"; runboot
chk "bootstrap: a 503 is retried after 5 s and then succeeds" "$BRC/$(paste -sd, "$FAKEGH/boot.sleeps")" "0/5"
pubreset; echo "429~Retry-After: 1~{\"message\":\"API rate limit exceeded\"}" > "$FAKEGH/inject.contents"; runboot
chk "bootstrap: a rate limit is retried too" "$BRC/$(paste -sd, "$FAKEGH/boot.sleeps")" "0/5"
pubreset; echo 'scripts/ci-gate-lib.sh' > "$FAKEGH/contents.404"; runboot
chk "bootstrap: a 404 is not retried; the job fails loudly; nothing is posted" "$BRC/$(cat "$FAKEGH/boot.sleeps" 2> /dev/null | wc -l)/$(grep -c 'NO STATUS WAS WRITTEN' "$WORK/bt/out")/$(grep -c . "$FAKEGH/posts.log")" "1/0/1/0"
pubreset; echo '503~~{"message":"unavailable"}' > "$FAKEGH/inject.always.contents"; runboot
chk "bootstrap: a 503 that persists: 5 attempts, waits 5,10,20,40 s, then red with no status (never a failure status)" "$BRC/$(paste -sd, "$FAKEGH/boot.sleeps")/$(grep -c . "$FAKEGH/posts.log")" "1/5,10,20,40/0"
pubreset; echo '503~~{"message":"unavailable"}' > "$FAKEGH/inject.always.contents"; runboot
chk "bootstrap: a persistent 503 flags unavailable=true (the fallback stays silent)" "$(grep -c '^unavailable=true$' "$WORK/bt/gout")" 1
pubreset; echo '505~~{"message":"HTTP Version Not Supported"}' > "$FAKEGH/inject.always.contents"; runboot
chk "bootstrap: every 5xx is transient (505 is retried 4 times, then flagged unavailable=true)" "$(paste -sd, "$FAKEGH/boot.sleeps")/$(grep -c '^unavailable=true$' "$WORK/bt/gout")" "5,10,20,40/1"
pubreset; echo '404~~{"message":"Not Found"}' > "$FAKEGH/inject.always.contents"; runboot
chk "bootstrap: a real error (404) is NOT flagged unavailable, so the fallback writes the failure" "$BRC/$(grep -c '^unavailable=true$' "$WORK/bt/gout")" "1/0"
pubreset; { echo '503~~{"message":"unavailable"}'; echo '404~~{"message":"Not Found"}'; } > "$FAKEGH/inject.contents"; runboot
chk "bootstrap: a 503 followed by a real 404 is a real error (not flagged unavailable)" "$BRC/$(grep -c '^unavailable=true$' "$WORK/bt/gout")" "1/0"
pubreset; runboot WF_SHA=notasha
chk "bootstrap: a malformed job.workflow_sha is refused before any request" "$BRC/$(grep -c . "$FAKEGH/calls.log")" "1/0"
pubreset; runboot WF_REPO=a/..
chk "bootstrap: a malformed job.workflow_repository is refused before any request" "$BRC/$(grep -c . "$FAKEGH/calls.log")" "1/0"

step_script "$WORKFLOW" "Read the profile and the verdict scripts" > "$WORK/readprofile.sh"
[ -s "$WORK/readprofile.sh" ] && ok "extracted the profile-fetch step" || bad "could not extract the profile-fetch step"
runread() { # [VAR=value ...] -> RRC; the suite is $WORK/rd/suite with the library already in place (step 1)
  rm -rf "$WORK/rd"; mkdir -p "$WORK/rd/suite/scripts" "$WORK/rd/suite/profiles/ci-gate"; cp "$ROOT/scripts/ci-gate-lib.sh" "$WORK/rd/suite/scripts/"
  : > "$WORK/rd/out"; : > "$FAKEGH/posts.log"; : > "$FAKEGH/calls.log"; rm -f "$FAKEGH/fetched"
  env PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" suite="$WORK/rd/suite" GITHUB_OUTPUT="$WORK/rd/out" EVENT_NAME=workflow_run \
    REPO=example/repo HEAD_SHA="$SHA" CONTEXT=CI/gate SERVER_URL=https://github.com RUN_ID=9 \
    WF_REPO=hyperpolymath/proven-cicd-and-workflows WF_SHA="$(printf 'c%.0s' $(seq 40))" \
    CI_GATE_BACKOFF_MAX_SECONDS=0 CI_GATE_JITTER=0 CI_GATE_CLOCK="$FAKEGH/bin/clock" CI_GATE_SLEEP="$FAKEGH/bin/poll-sleep" "$@" bash "$WORK/readprofile.sh" > "$WORK/rd/log" 2>&1
  RRC=$?
  NPOSTS=$(grep -c . "$FAKEGH/posts.log")
}
pubreset; runread
chk "profile step: fetches the verdict scripts, the jq files, the join and the profile of the repository, in that order" "$RRC/$(paste -sd, "$FAKEGH/fetched")" "0/scripts/ci-gate-verdict.sh,scripts/validate-ci-gate-profile.sh,scripts/ci-gate-publish.sh,scripts/ci-gate-sweep.sh,profiles/ci-gate/validate.jq,profiles/ci-gate/select-runs.jq,profiles/ci-gate/join-checks.jq,profiles/ci-gate/example/repo.json"
chk "profile step: nothing is posted when everything is readable" "$NPOSTS/$(grep -c unavailable "$WORK/rd/out")" "0/0"
pubreset; runread REPO=example/.github
chk "a .github repository: the profile is fetched from profiles/ci-gate/example/.github.json and lands under the owner in the suite" \
  "$RRC/$(grep -c '^profiles/ci-gate/example/\.github\.json$' "$FAKEGH/fetched")/$([ -f "$WORK/rd/suite/profiles/ci-gate/example/.github.json" ] && echo yes || echo no)" "0/1/yes"
pubreset; echo "429~Retry-After: 600~{\"message\":\"API rate limit exceeded\"}" > "$FAKEGH/inject.always.contents"; runread
chk "profile step, rate-limited on workflow_run: pending (the API-unavailable reason), never failure, exit 0" "$RRC/$NPOSTS/$(cut -f1,2 "$FAKEGH/posts.log" | tr '\t' '|')" "0/1/pending|$UNAVAIL_DESC"
chk "profile step, rate-limited: unavailable=true is flagged so the later steps are skipped" "$(grep -c '^unavailable=true$' "$WORK/rd/out")" 1
pubreset; echo "429~Retry-After: 600~{\"message\":\"API rate limit exceeded\"}" > "$FAKEGH/inject.always.contents"; runread EVENT_NAME=pull_request
chk "profile step, rate-limited on pull_request: pending, exit 0" "$RRC/$(cut -f1 "$FAKEGH/posts.log")" "0/pending"
pubreset; echo "429~Retry-After: 600~{\"message\":\"API rate limit exceeded\"}" > "$FAKEGH/inject.always.contents"; runread EVENT_NAME=schedule HEAD_SHA=
chk "profile step, rate-limited on the sweep: red, nothing to write to, nothing posted" "$RRC/$NPOSTS/$(grep -c '^unavailable=true$' "$WORK/rd/out")" "1/0/1"
pubreset; echo "429~Retry-After: 600~{\"message\":\"API rate limit exceeded\"}" > "$FAKEGH/inject.always.contents"; echo "429~Retry-After: 600~{\"message\":\"API rate limit exceeded\"}" > "$FAKEGH/inject.always.post"; runread
chk "profile step, the pending write is rate-limited too: red, nothing posted, loudly no failure" "$RRC/$NPOSTS/$(grep -c 'NO FAILURE WAS POSTED' "$WORK/rd/log")" "1/0/1"
pubreset; echo 'profiles/ci-gate/example/repo.json' > "$FAKEGH/contents.404"; runread
chk "profile step, the profile does not exist (404): a real error, exit 1, no pending, not flagged unavailable" "$RRC/$NPOSTS/$(grep -c '^unavailable=true$' "$WORK/rd/out")/$(grep -c 'no readable CI/gate profile' "$WORK/rd/log")" "1/0/0/1"
pubreset; echo '403~~{"message":"Resource not accessible by integration"}' > "$FAKEGH/inject.contents"; runread
chk "profile step, a 403 that is a permissions problem: a real error, exit 1, no pending" "$RRC/$NPOSTS/$(grep -c '^unavailable=true$' "$WORK/rd/out")" "1/0/0"

pubreset; runread WORKFLOW_RUN_ACTION=requested
chk "profile step, a re-run start (requested): only the publisher is read, no profile and no other script; nothing posted" "$RRC/$(paste -sd, "$FAKEGH/fetched")/$NPOSTS" "0/scripts/ci-gate-publish.sh/0"
pubreset; echo 'scripts/ci-gate-publish.sh' > "$FAKEGH/contents.404"; runread WORKFLOW_RUN_ACTION=requested
chk "profile step, requested, the publisher cannot be read (404): a real error, exit 1 (the fallback writes no failure for requested)" "$RRC/$NPOSTS" "1/0"
pubreset; echo "429~Retry-After: 600~{\"message\":\"API rate limit exceeded\"}" > "$FAKEGH/inject.always.contents"; runread WORKFLOW_RUN_ACTION=requested
chk "profile step, requested, rate-limited: pending, never failure, unavailable=true so the later steps are skipped" "$RRC/$(cut -f1 "$FAKEGH/posts.log")/$(grep -c '^unavailable=true$' "$WORK/rd/out")" "0/pending/1"

step_script "$WORKFLOW" "Publish a failure status" > "$WORK/fb.sh"
[ -s "$WORK/fb.sh" ] && ok "extracted the failure fallback step" || bad "could not extract the failure fallback step"
runfb() { # [VAR=value ...] -> FRC, NPOSTS
  : > "$FAKEGH/posts.log"; : > "$FAKEGH/calls.log"
  env PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" suite="$SUITE_DIR" EVENT_NAME=workflow_run REPO=example/repo HEAD_SHA="$SHA" CONTEXT=CI/gate \
    SERVER_URL=https://github.com RUN_ID=9 CI_GATE_BACKOFF_MAX_SECONDS=0 CI_GATE_JITTER=0 "$@" bash "$WORK/fb.sh" > "$WORK/fb.out" 2>&1
  FRC=$?
  NPOSTS=$(grep -c . "$FAKEGH/posts.log")
}
pubreset; runfb
chk "fallback: a real fail-closed cause posts a FAILURE status (through gate_post), exit 0" "$FRC/$NPOSTS/$(cut -f1 "$FAKEGH/posts.log")" "0/1/failure"
chk "fallback: its description is the profile-or-input one (no longer 'or API error')" "$(cut -f2 "$FAKEGH/posts.log")" "ci-gate could not produce a verdict (profile or input error); see the run"
pubreset; runfb EVENT_NAME=schedule
chk "fallback: a sweep has no commit to write to" "$FRC/$NPOSTS" "0/0"
pubreset; runfb CONTEXT=' bad'
chk "fallback: an invalid context writes nothing" "$FRC/$NPOSTS" "0/0"
pubreset; runfb HEAD_SHA=abc
chk "fallback: an invalid head SHA writes nothing" "$FRC/$NPOSTS" "0/0"
pubreset; runfb suite=/nonexistent
chk "fallback: no library was read (a real error in the first step): an independent inline write, FAILURE, exit 0" "$FRC/$NPOSTS/$(cut -f1 "$FAKEGH/posts.log")/$(cut -f3 "$FAKEGH/posts.log")" "0/1/failure/$SHA"
chk "fallback: the inline write carries the fixed ASCII description" "$(cut -f2 "$FAKEGH/posts.log")" "ci-gate could not produce a verdict (profile or input error); see the run"
pubreset; runfb suite=/nonexistent REPO='a/..'
chk "fallback: no library and a malformed repository coordinate: nothing is written" "$FRC/$NPOSTS" "0/0"
pubreset; runfb suite=/nonexistent EVENT_NAME=schedule
chk "fallback: no library on a sweep: nothing is written" "$FRC/$NPOSTS" "0/0"
pubreset; echo '429~Retry-After: 600~{"message":"API rate limit exceeded"}' > "$FAKEGH/inject.always.post"; runfb suite=/nonexistent
chk "fallback: no library and the inline write is refused: a warning, nothing posted, exit 0" "$FRC/$NPOSTS/$(grep -c '^::warning::could not publish the failure status either' "$WORK/fb.out")" "0/0/1"
pubreset; runfb suite=/nonexistent WORKFLOW_RUN_ACTION=requested
chk "fallback: a requested (re-run start) event never gets a failure, library or not" "$FRC/$NPOSTS" "0/0"
pubreset; runfb WORKFLOW_RUN_ACTION=requested
chk "fallback: a requested event with the library read gets no failure either" "$FRC/$NPOSTS" "0/0"
pubreset; echo "429~Retry-After: 600~{\"message\":\"API rate limit exceeded\"}" > "$FAKEGH/inject.always.post"; runfb
chk "fallback: the failure write cannot be made (rate-limited): a warning, nothing posted" "$FRC/$NPOSTS/$(grep -c '^::warning::could not publish the failure status' "$WORK/fb.out")" "0/0/1"
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
  : > "$WORK/gss"; rm -rf "$WORK/sw"; : > "$FAKEGH/calls.log"; : > "$FAKEGH/sleeps"; echo 0 > "$FAKEGH/clock"
  SOUT=$(env PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" REPO=example/repo CONTEXT=CI/gate \
    TIMEOUT_MINUTES=180 GATE_NAME='CI gate' SUITE="$SUITE_DIR" WORK="$WORK/sw" CI_GATE_NOW="$NOW" \
    CI_GATE_BACKOFF_MAX_SECONDS=0 CI_GATE_JITTER=0 CI_GATE_CLOCK="$FAKEGH/bin/clock" CI_GATE_SLEEP="$FAKEGH/bin/poll-sleep" \
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
echo '404~~{"message":"Not Found"}' > "$FAKEGH/by/$(sha_n 13)/fail.1"
sweep
chk "the SHA whose runs could not be read gets a failure status" "$(last_for 13)" failure
chk "the SHAs before and after it are still evaluated (12, 14, 15 success)" "$(last_for 12) $(last_for 14) $(last_for 15)" "success success success"
chk "one SHA's API error: the sweep exits non-zero" "$RC" 1
grep -qF "| \`$(sha_n 13 | cut -c1-12)\` | PR #2 | error |" "$WORK/gss" && ok "the table marks it as an error" || bad "the table does not mark the error"
pubreset; set_pulls "1 $T1 12"; set_default 14
for i in 12 14; do sweep_sha "$i" "$DONE"; done
echo '404~~{"message":"Not Found"}' > "$FAKEGH/failpulls"
sweep
chk "the pull request listing fails (a real error, not an outage): the default branch head is still evaluated" "$(last_for 14)" success
chk "the pull request listing fails: exit non-zero and a loud error" "$RC/$(grep -c '^::error::ci-gate-sweep: could not list the open pull requests' <<<"$SOUT")" "1/1"
pubreset; set_pulls "1 $T1 12"; set_default 14
for i in 12 14; do sweep_sha "$i" "$DONE"; done
echo '404~~{"message":"Not Found"}' > "$FAKEGH/faildefault"
sweep
chk "the default branch head is unreadable (a real error, not an outage): the pull request is still evaluated" "$(last_for 12)" success
chk "the default branch head is unreadable: exit non-zero and a loud error" "$RC/$(grep -c '^::error::ci-gate-sweep: could not read the default branch head' <<<"$SOUT")" "1/1"
pubreset; set_pulls; set_default 14; sweep_sha 14 "$DONE"
sweep
chk "no open pull requests: only the default branch head, exit 0" "$(count_for 14)/$RC" "1/0"
pubreset; set_pulls "1 $T1 12"; set_default 14
sweep_sha 12 "$DONE" "$TESTFAIL"; sweep_sha 14 "$DONE" "$TESTFAIL"
sweep
chk "every SHA failing: both failure statuses are written, exit 1" "$(last_for 12) $(last_for 14)/$RC" "failure failure/1"
pubreset

echo "-- every request of a sweep goes through the API helper: pull request pages, and an unavailable API --"
pubreset; set_pulls "1 2026-11-17T10:03:00Z 12" "2 2026-11-17T10:02:00Z 13" "3 2026-11-17T10:01:00Z 15"; set_default 14
for i in 12 13 14 15; do sweep_sha "$i" "$DONE"; done
sweep PULLS_PAGE_SIZE=1
chk "pull request listing across 3 pages (page size 1): all four heads are evaluated, exit 0" "$(cut -f3 "$FAKEGH/posts.log" | sort -u | grep -c .)/$RC" "4/0"
chk "the listing asked for page=1, 2 and 3 of the pull requests" "$(grep -c 'pulls?state=open.*page=[123]$' "$FAKEGH/calls.log")" 3
chk "the sweep read the repository and the default branch through the helper (one request each)" "$(grep -c '^GET repos/example/repo$' "$FAKEGH/calls.log")/$(grep -c 'branches/main$' "$FAKEGH/calls.log")" "1/1"
pubreset; set_pulls "1 2026-11-17T10:03:00Z 12" "2 2026-11-17T10:02:00Z 13"; set_default 14
for i in 12 13 14; do sweep_sha "$i" "$DONE"; done
echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"
sweep
chk "an unavailable API: the first head (the default branch) gets pending, never failure" "$(cut -f1,2,3 "$FAKEGH/posts.log" | tr '\t' '|')" "pending|$UNAVAIL_DESC|$(sha_n 14)"
chk "an unavailable API: the sweep stops there, so the other two heads were not evaluated" "$(count_for 12)$(count_for 13)" 00
chk "an unavailable API: the sweep is red (it did not do its job), loudly, naming the 2 heads" "$RC/$(grep -c '^::error::ci-gate-sweep: the GitHub API was rate-limited or unavailable; the sweep stopped at head 1 and 2 further head(s) were NOT evaluated' <<<"$SOUT")" "1/1"
grep -qF "| unavailable |" "$WORK/gss" && grep -qF "2 further head(s) not evaluated (API unavailable)" "$WORK/gss" && ok "the step summary table names the unavailable head and the skipped ones" || bad "the summary table does not name the outage"
chk "an unavailable API: no failure status anywhere" "$(grep -c '^failure' "$FAKEGH/posts.log" || true)" 0
pubreset; set_pulls "1 2026-11-17T10:03:00Z 12"; set_default 14
for i in 12 14; do sweep_sha "$i" "$DONE"; echo "429~Retry-After: 30~$RL" > "$FAKEGH/by/$(sha_n "$i")/fail.1"; done
sweep CI_GATE_BACKOFF_MAX_SECONDS=40
chk "the back-off bound is shared by the whole sweep: the default branch head waits 30 s and succeeds; the next head's 30 s would pass the 40 s bound, so it does not wait at all" "$(sleeps)/$(last_for 14)/$(last_for 12)" "30/success/pending"
chk "that second head got the API-unavailable pending, never a failure; the sweep is red" "$(grep -P "\t$(sha_n 12)$" "$FAKEGH/posts.log" | cut -f2)/$RC" "$UNAVAIL_DESC/1"
pubreset

nposts() { { cat "$FAKEGH/posts.log" 2> /dev/null || true; } | grep -c . || true; }
echo "-- a discovery read that meets an outage stops the sweep at once; other discovery errors keep the partial discovery --"
pubreset; set_pulls "1 $T1 12"; set_default 14
for i in 12 14; do sweep_sha "$i" "$DONE"; done
touch "$FAKEGH/failpulls"
sweep
chk "the pull request listing meets an outage (500): the sweep stops at once, red, and no head is evaluated (nothing posted)" "$RC/$(nposts)" "1/0"
chk "outage at the listing: no workflow run is read and no publisher runs (the default branch head, already found, is not evaluated either)" "$(ncalls 'actions/runs')/$(ncalls 'check-runs')/$(ncalls 'statuses')" "0/0/0"
chk "outage at the listing: the error names the failed step and the 1 discovered head not evaluated" "$(grep -c '^::error::ci-gate-sweep: the GitHub API was rate-limited or unavailable while listing the open pull requests .*1 head(s) already discovered were NOT evaluated' <<<"$SOUT")" 1
grep -qF "| unavailable |" "$WORK/gss" && grep -qF 'listing the open pull requests' "$WORK/gss" && ok "outage at the listing: the step summary table names the step" || bad "the summary table does not name the discovery step"
pubreset; set_pulls "1 $T1 12"; set_default 14
for i in 12 14; do sweep_sha "$i" "$DONE"; done
touch "$FAKEGH/faildefault"
sweep
chk "the repository read meets an outage: stops after that one request (no branch, no listing, no evaluation, nothing posted), red" "$RC/$(grep -c . "$FAKEGH/calls.log")/$(nposts)/$(grep -c 'while reading the repository' <<<"$SOUT")" "1/1/0/1"

echo "-- a publisher that hit an outage stops the sweep, even if its pending write failed --"
pubreset; set_pulls "1 2026-11-17T10:03:00Z 12" "2 2026-11-17T10:02:00Z 13"; set_default 14
for i in 12 13 14; do sweep_sha "$i" "$DONE"; done
echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"
sweep
chk "outage, pending written (publisher exit 75): the sweep stops after the first head, red, and says the pending was written" "$RC/$(grep -c 'The pending status was written for that head' <<<"$SOUT")/$(grep -c 'FAILED' <<<"$SOUT")/$(ncalls "head_sha=$(sha_n 12)")" "1/1/0/0"
grep -qF 'pending written, sweep stopped' "$WORK/gss" && ok "the table row says: pending written" || bad "the table row does not say pending written"
pubreset; set_pulls "1 2026-11-17T10:03:00Z 12" "2 2026-11-17T10:02:00Z 13"; set_default 14
for i in 12 13 14; do sweep_sha "$i" "$DONE"; done
echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.post"
sweep
chk "outage AND the pending write failed (publisher exit 1 with unavailable=true): the sweep still stops after that head, red" "$RC/$(ncalls "head_sha=$(sha_n 12)")/$(ncalls "head_sha=$(sha_n 13)")/$(nposts)" "1/0/0/0"
chk "the pending write's outcome is unknown (429): the error says NOT CONFIRMED, not FAILED, and that no failure was posted" "$(grep -c '^::error::ci-gate-sweep: .*stopped at head 1 and 2 further head(s) were NOT evaluated. The pending write for that head is NOT CONFIRMED (its outcome is unknown and it may have landed). No failure status was posted' <<<"$SOUT")" 1
grep -qF 'pending not confirmed (it may have landed)' "$WORK/gss" && ! grep -qF 'FAILED' "$WORK/gss" && ok "the table row says: pending not confirmed (it may have landed), never FAILED" || bad "the table row does not say pending not confirmed"
pubreset; set_pulls "1 2026-11-17T10:03:00Z 12" "2 2026-11-17T10:02:00Z 13"; set_default 14
for i in 12 13 14; do sweep_sha "$i" "$DONE"; done
echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; echo '403~~{"message":"Resource not accessible by integration"}' > "$FAKEGH/inject.always.post"
sweep
chk "outage AND GitHub rejected the pending write (a real 403): the error says REJECTED, not NOT CONFIRMED, and no failure was posted" "$RC/$(grep -c 'The pending write for that head was REJECTED by GitHub: no status was written there. No failure status was posted' <<<"$SOUT")/$(grep -c 'NOT CONFIRMED' <<<"$SOUT")/$(nposts)" "1/1/0/0"
grep -qF 'GitHub rejected the pending write (no status written)' "$WORK/gss" && ok "the table row says: GitHub rejected the pending write" || bad "the table row does not say GitHub rejected the pending write"
chk "the table headline counts the heads attempted (1 of 3), not the planned total" "$(grep -c '1 of 3 distinct head SHAs attempted' "$WORK/gss")" 1
pubreset; set_pulls "1 2026-11-17T10:03:00Z 12" "2 2026-11-17T10:02:00Z 13"; set_default 14
for i in 12 13 14; do sweep_sha "$i" "$DONE"; done
echo '404~~{"message":"Not Found"}' > "$FAKEGH/by/$(sha_n 14)/fail.1"
sweep
chk "an ordinary (non-outage) head failure still continues with the other heads, and is red" "$(last_for 12)/$(last_for 13)/$(last_for 14)/$RC" "success/success/failure/1"
pubreset

echo "-- a sweep every 15 minutes must not re-post an unchanged status (1000-status cap), with a spaced context --"
pubreset; set_pulls "1 $T1 12"; set_default 13
sweep_sha 12 "$DONE"; sweep_sha 13 "$DONE"
sweep CONTEXT='CI / gate'
chk "first sweep, context 'CI / gate': two SHAs, two success POSTs" "$(grep -c . "$FAKEGH/posts.log")/$(cut -f1 "$FAKEGH/posts.log" | sort -u)/$RC" "2/success/0"
chk "first sweep: every status is under the context 'CI / gate'" "$(cut -f2 "$FAKEGH/status.log" | sort -u)" "CI / gate"
: > "$FAKEGH/posts.log"
sweep CONTEXT='CI / gate'
chk "second sweep, nothing changed: no POST at all" "$(nposts)" 0
chk "second sweep: both writes skipped and logged" "$(grep -c 'write skipped' <<<"$SOUT")" 2
chk "second sweep: both SHAs still reported success, exit 0" "$(grep -c '| success | all 3 required checks passed |' "$WORK/gss")/$RC" "2/0"
sweep_sha 12 "$DONE" "$TESTFAIL"; : > "$FAKEGH/posts.log"
sweep CONTEXT='CI / gate'
chk "third sweep, one head now failing: exactly that one is written" "$(cut -f1,3 "$FAKEGH/posts.log" | tr '\t' ' ')/$RC" "failure $(sha_n 12)/1"
pubreset

echo "== re-run start events: requested and in_progress take ONE pending-only path (which GitHub sends for a re-run is unconfirmed) =="
pubreset; snap 1 "$DONE"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=in_progress
chk "in_progress: exactly one pending POST with the re-run description, exit 0" "$NPOSTS/$(post_n 1 | cut -f1,2 | tr '\t' '|')/$RC" "1/pending|$REQ_DESC/0"
chk "in_progress: no run listing, no check-run listing, no jobs: only the status dedupe GET and the one POST" "$(ncalls 'actions/runs')/$(ncalls '/check-runs?')/$(ncalls '/jobs')/$(ncalls '/status?')/$(grep -c . "$FAKEGH/calls.log")" "0/0/0/1/2"
chk "in_progress: published=true is written" "$(has_published)" 1
pubreset; snap 1 "$DONE"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=requested; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=in_progress
chk "both start events for one attempt (requested, then in_progress): the second is a no-op apart from the dedupe GET (no POST, no listing)" "$NPOSTS/$(grep -c . "$FAKEGH/calls.log")/$(ncalls '/status?')/$(ncalls 'POST')/$RC" "0/1/1/0/0"
pubreset; snap 1 "$DONE"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=in_progress; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=requested
chk "both start events in the other order (in_progress, then requested): the second is a no-op apart from the dedupe GET" "$NPOSTS/$(grep -c . "$FAKEGH/calls.log")/$(ncalls '/status?')/$RC" "0/1/1/0"
pubreset; snap 1 "$DONE"; printf '%s\tCI/gate\tsuccess\tall 3 required checks passed\n' "$SHA" > "$FAKEGH/status.log"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=in_progress
chk "in_progress over a standing success: the success is replaced by the re-run pending" "$(post_n 1 | cut -f1)/$NPOSTS/$RC" "pending/1/0"
pubreset; snap 1 "$DONE"; rm -f "$SUITE_DIR/profiles/ci-gate/example/repo.json"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=in_progress
chk "in_progress with no profile: still only the pending, never a failure" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/pending/0"
pubreset; snap 1 "$DONE"; echo '403~~{"message":"Resource not accessible by integration"}' > "$FAKEGH/inject.post"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=in_progress
chk "in_progress, a real error on the write: exit 1, NOTHING posted, in particular no failure" "$RC/$NPOSTS/$(grep -c 'NOTHING WAS WRITTEN' <<<"$PUBOUT")" "1/0/1"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.post"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=in_progress
chk "in_progress, the API is unavailable: pending with the unavailable reason, exit 75, unavailable=true, never a failure" "$(post_n 1 | cut -f1,2 | tr '\t' '|')/$RC/$(grep -c '^unavailable=true$' "$WORK/gho")" "pending|$UNAVAIL_DESC/75/1"
pubreset; snap 1 "$DONE"; publish EVENT_NAME=pull_request WORKFLOW_RUN_ACTION=in_progress
chk "in_progress outside a workflow_run event is refused: exit 1, nothing written" "$RC/$NPOSTS" "1/0"
pubreset; runread WORKFLOW_RUN_ACTION=in_progress
chk "profile step, a re-run start (in_progress): only the publisher is read, no profile and no other script; nothing posted" "$RRC/$(paste -sd, "$FAKEGH/fetched")/$NPOSTS" "0/scripts/ci-gate-publish.sh/0"
pubreset; runfb suite=/nonexistent WORKFLOW_RUN_ACTION=in_progress
chk "fallback: an in_progress (re-run start) event never gets a failure, library or not" "$FRC/$NPOSTS" "0/0"

echo "== a 2xx whose body was cut off (headers 2xx, gh exit non-zero): a GET is transient, a write is an unknown outcome =="
pubreset; snap 1 "$DONE"; echo '200!~~{"total_count":1,"workflow_runs":[' > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a GET whose 2xx body was cut off is transient: retried after the 2 s exponential delay, then success, one POST" "$(sleeps)/$RC/$NPOSTS/$(post_n 1 | cut -f1)" "2/0/1/success"
pubreset; snap 1 "$DONE"; echo '200!~~{"total_count":1,"workflow_runs":[' > "$FAKEGH/inject.always.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=0
chk "a persistently cut-off GET outlasts the budget: unavailable (pending, exit 75), never a failure" "$RC/$(post_n 1 | cut -f1,2 | tr '\t' '|')" "75/pending|$UNAVAIL_DESC"
pubreset; snap 1 "$DONE"; echo '200~~{not json' > "$FAKEGH/inject.runs"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a COMPLETE but malformed 2xx body stays a real error: no retry (no sleep), a failure status, exit 1" "$(sleeps)/$RC/$(post_n 1 | cut -f1)" "/1/failure"
pubreset; snap 1 "$DONE"; touch "$FAKEGH/landscut"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a status POST whose 2xx headers arrived but whose body was cut off was acknowledged: success, one POST, no sleep, exit 0, and NO recheck (the dedupe read is the only status read)" "$NPOSTS/$(post_n 1 | cut -f1)/$RC/$(sleeps)/$(wc -l < "$FAKEGH/status.reads")" "1/success/0//1"
chk "a cut-off 201 is treated as landed with zero further calls: exactly one POST call in all" "$(ncalls 'POST')" 1
pubreset; snap 1 "$DONE"; echo '201!~~{"id":' > "$FAKEGH/inject.post"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a 201 cut off (nothing logged by the fake): still acknowledged, never replayed, no sleep, one POST call, no recheck" "$(ncalls 'POST')/$RC/$(sleeps)/$(wc -l < "$FAKEGH/status.reads")" "1/0//1"
echo "-- a recheck that cannot tell is not a licence to replay --"
pubreset; snap 1 "$DONE"; echo '500~~{"message":"Server Error"}' > "$FAKEGH/inject.post"; echo '500~~{"message":"Server Error"}' > "$FAKEGH/inject.always.status"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a 500 POST whose recheck read also fails: NOT replayed (the success POST is made once), the outcome is unknown (75): only the unavailable pending is written, exit 75" "$(ncalls 'POST')/$NPOSTS/$(post_n 1 | cut -f1)/$RC" "2/1/pending/75"
chk "that unknown outcome is said so in the log (recheck could not tell, not replayed)" "$(grep -c 'recheck could not tell whether the write landed, so it is not replayed' <<<"$PUBOUT")" 1
pubreset; snap 1 "$DONE"; echo '500~~{"message":"Server Error"}' > "$FAKEGH/inject.post"; echo '200~~not json' > "$FAKEGH/inject.always.status"; publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a 500 POST whose recheck read is malformed (200 'not json'): not replayed either, exit 75" "$(ncalls 'POST')/$RC" "2/75"
echo "-- the outcome of a write stays unknown across its retries; a local error is neither rejected nor unconfirmed --"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; printf '%s\n' '500~~{"message":"Server Error"}' '403~~{"message":"Resource not accessible by integration"}' > "$FAKEGH/inject.post"; publish CI_GATE_BACKOFF_MAX_SECONDS=60
chk "an unknown POST (500, recheck: not landed) then a real 403: pending=unconfirmed, never rejected; exit 1, nothing posted" "$(grep -c '^pending=unconfirmed$' "$WORK/gho")/$(grep -c '^pending=rejected$' "$WORK/gho")/$RC/$NPOSTS" "1/0/1/0"
chk "that error log says not confirmed, not 'GitHub rejected it'" "$(grep -c 'pending not confirmed' <<<"$PUBOUT")/$(grep -c 'GitHub rejected it' <<<"$PUBOUT")" "1/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; echo '403~~{"message":"Resource not accessible by integration"}' > "$FAKEGH/inject.post"; publish CI_GATE_BACKOFF_MAX_SECONDS=60
chk "control: a lone real 403 on the pending write is still pending=rejected" "$(grep -c '^pending=rejected$' "$WORK/gho")/$(grep -c '^pending=unconfirmed$' "$WORK/gho")/$RC" "1/0/1"
mkdir -p "$WORK/badmk"; printf '#!/bin/sh\nexit 1\n' > "$WORK/badmk/mktemp"; chmod +x "$WORK/badmk/mktemp"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; publish PATH="$WORK/badmk:$FAKEGH/bin:$PATH" CI_GATE_BACKOFF_MAX_SECONDS=60
chk "mktemp fails on the pending write: pending=local-error (neither rejected nor unconfirmed), no POST was made, exit 1" "$(grep -c '^pending=local-error$' "$WORK/gho")/$(grep -c '^pending=\(rejected\|unconfirmed\)$' "$WORK/gho")/$(ncalls 'POST')/$RC" "1/0/0/1"
chk "that error log says no write was attempted" "$(grep -c 'NO WRITE WAS ATTEMPTED' <<<"$PUBOUT")" 1
pubreset; set_pulls "1 2026-11-17T10:03:00Z 13"; set_default 12
sweep_sha 12 "$DONE"; sweep_sha 13 "$DONE"
echo "429~Retry-After: 600~$RL" > "$FAKEGH/inject.always.runs"; printf '%s\n' '500~~{"message":"Server Error"}' '403~~{"message":"Resource not accessible by integration"}' > "$FAKEGH/inject.post"
sweep CI_GATE_BACKOFF_MAX_SECONDS=60
chk "sweep: an unknown pending write followed by a 403 is worded NOT CONFIRMED, never REJECTED" "$(grep -c 'NOT CONFIRMED' <<<"$SOUT")/$(grep -c 'REJECTED' <<<"$SOUT")/$RC" "1/0/1"

echo "== x-ratelimit-reset is an epoch timestamp: ten digits are not truncated =="
pubreset; snap 1 "$DONE"; echo "403~x-ratelimit-remaining: 0|x-ratelimit-reset: 1800000040~$RL" > "$FAKEGH/inject.runs"; CLOCK0=1800000000 publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a ten-digit reset 40 s ahead of a ten-digit clock: waits 41 s, then succeeds" "$(sleeps)/$RC/$(post_n 1 | cut -f1)" "41/0/success"
pubreset; snap 1 "$DONE"; echo "403~x-ratelimit-remaining: 0|x-ratelimit-reset: 1800009999~$RL" > "$FAKEGH/inject.always.runs"; CLOCK0=1800000000 publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a ten-digit reset beyond the budget (10000 s): no early retry (no sleep), pending, exit 75" "$(sleeps)/$RC/$(post_n 1 | cut -f1)" "/75/pending"
pubreset; snap 1 "$DONE"; echo "403~x-ratelimit-remaining: 0|x-ratelimit-reset: 9999999999999~$RL" > "$FAKEGH/inject.always.runs"; CLOCK0=1800000000 publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "a thirteen-digit reset saturates (overflow-checked) and is far beyond the budget: no sleep, pending, exit 75" "$(sleeps)/$RC/$(post_n 1 | cut -f1)" "/75/pending"
pubreset; snap 1 "$DONE"; echo "403~x-ratelimit-remaining: 0|x-ratelimit-reset: 0001800000040~$RL" > "$FAKEGH/inject.runs"; CLOCK0=1800000000 publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "leading zeros of a long reset are stripped (decimal, not octal): waits 41 s" "$(sleeps)/$RC" "41/0"

echo "== Retry-After HTTP-date: IMF-fixdate, RFC 850 (two-digit year rule) and asctime, in the C locale =="
T_NOW=1800000000   # 2027-01-15 08:00:00 UTC
hd() { LC_ALL=C date -u -d "@$1" "+$2"; }   # <epoch> <date format>
RFC850='%A, %d-%b-%y %H:%M:%S GMT'; ASCT='%a %b %e %H:%M:%S %Y'; IMF='%a, %d %b %Y %H:%M:%S GMT'
pubreset; snap 1 "$DONE"; echo "429~Retry-After: $(hd $((T_NOW + 30)) "$IMF")~$RL" > "$FAKEGH/inject.runs"; CLOCK0=$T_NOW publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "IMF-fixdate 30 s ahead of a ten-digit clock: sleeps 30 s" "$(sleeps)/$RC" "30/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: $(hd $((T_NOW + 30)) "$RFC850")~$RL" > "$FAKEGH/inject.runs"; CLOCK0=$T_NOW publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "RFC 850 (Friday, 15-Jan-27 08:00:30 GMT) 30 s ahead: sleeps 30 s, then succeeds" "$(sleeps)/$RC/$(hd $((T_NOW + 30)) "$RFC850" | cut -c1-6)" "30/0/Friday"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: $(hd $((T_NOW + 30)) "$ASCT")~$RL" > "$FAKEGH/inject.runs"; CLOCK0=$T_NOW publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "asctime 30 s ahead: sleeps 30 s" "$(sleeps)/$RC" "30/0"
T_D6=$(date -u -d '2027-01-06 08:00:00' +%s)
pubreset; snap 1 "$DONE"; echo "429~Retry-After: $(hd $((T_D6 + 30)) "$ASCT")~$RL" > "$FAKEGH/inject.runs"; CLOCK0=$T_D6 publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "asctime with a space-padded single-digit day ($(hd $((T_D6 + 30)) "$ASCT")): sleeps 30 s" "$(sleeps)/$RC" "30/0"
pubreset; snap 1 "$DONE"; echo "503~Retry-After: Wed Jan 6 08:00:30 2027~{}" > "$FAKEGH/inject.runs"; CLOCK0=$T_D6 publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "asctime with an unpadded day is not an asctime date: falls back to the exponential delay (2 s)" "$(sleeps)/$RC" "2/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: Sunday, 06-Nov-94 08:49:37 GMT~$RL" > "$FAKEGH/inject.runs"; CLOCK0=$T_NOW publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "RFC 850 year 94 (2094 would be 67 years ahead): read as 1994, in the past: clamped to 1 s" "$(sleeps)/$RC" "1/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: Sunday, 06-Feb-77 08:49:37 GMT~$RL" > "$FAKEGH/inject.runs"; CLOCK0=$T_NOW publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "RFC 850 year 77, 06-Feb (2077-02-06 is more than 50 years ahead of 2027-01-15): read as 1977, clamped to 1 s" "$(sleeps)/$RC" "1/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: Sunday, 06-Jan-77 08:49:37 GMT~$RL" > "$FAKEGH/inject.always.runs"; CLOCK0=$T_NOW publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "RFC 850 year 77, 06-Jan (2077-01-06 is within 50 years): read as 2077, far beyond the budget: no sleep, pending, exit 75" "$(sleeps)/$RC/$(post_n 1 | cut -f1)" "/75/pending"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: Sunday, 06-Nov-70 08:49:37 GMT~$RL" > "$FAKEGH/inject.always.runs"; CLOCK0=$T_NOW publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "RFC 850 year 70: read as 2070 (43 years ahead): beyond the budget, no sleep, pending, exit 75" "$(sleeps)/$RC/$(post_n 1 | cut -f1)" "/75/pending"
pubreset; snap 1 "$DONE"; echo "503~Retry-After: Sunday, 99-Foo-94 08:49:37 GMT~{}" > "$FAKEGH/inject.runs"; CLOCK0=$T_NOW publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "an RFC 850-shaped but impossible date falls back to the exponential delay (2 s)" "$(sleeps)/$RC" "2/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: Sun Nov  6 08:49:37 1994~$RL" > "$FAKEGH/inject.runs"; CLOCK0=$T_NOW publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "an asctime date in the past (1994): clamped to 1 s" "$(sleeps)/$RC" "1/0"
pubreset; snap 1 "$DONE"; echo "429~Retry-After: Sun Nov  6 08:49:37 2094~$RL" > "$FAKEGH/inject.always.runs"; CLOCK0=$T_NOW publish CI_GATE_BACKOFF_MAX_SECONDS=300
chk "an asctime date far ahead (2094, four-digit year, no two-digit rule): beyond the budget, no sleep, pending, exit 75" "$(sleeps)/$RC/$(post_n 1 | cut -f1)" "/75/pending"

echo "== the post-write verification read is unavailable: unavailable=true whatever was posted, no recovery write =="
pubreset; snap 1 "$RERUN"; snap 2 "$RERUN"; touch "$FAKEGH/fail.3"; publish
chk "pending posted, the verification read returns 500: the pending stands, ONE POST (no recovery write), exit 0" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/pending/0"
chk "pending posted, verification unavailable: unavailable=true is written (so a sweep stops)" "$(grep -c '^unavailable=true$' "$WORK/gho")" 1
pubreset; snap 1 "$DONE"; jq 'map(if .name == "Test" then .conclusion = "failure" else . end)' "$FX/jobs.json" > "$FAKEGH/jobs.json"; touch "$FAKEGH/fail.3"; publish
chk "failure posted, the verification read returns 500: the failure stands, ONE POST, exit 1 (the verdict), no pending written" "$NPOSTS/$(post_n 1 | cut -f1)/$RC" "1/failure/1"
chk "failure posted, verification unavailable: unavailable=true is written" "$(grep -c '^unavailable=true$' "$WORK/gho")" 1
pubreset; snap 1 "$DONE"; touch "$FAKEGH/fail.3"; publish
chk "success posted, verification unavailable: the success is replaced by the unavailable pending (unchanged)" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$RC/$(grep -c '^unavailable=true$' "$WORK/gho")" "success,pending/75/1"
pubreset; set_pulls "1 2026-11-17T10:03:00Z 13"; set_default 12
sweep_sha 12 "$RERUN"; sweep_sha 13 "$DONE"; touch "$FAKEGH/by/$(sha_n 12)/fail.3"
sweep
chk "sweep: a head whose pending stands but whose verification was unavailable stops the sweep: the next head is not evaluated, red" "$RC/$(count_for 13)/$(count_for 12)" "1/0/1"
chk "sweep: the error says the posted status stands (not that a pending write failed)" "$(grep -c 'The status already posted for that head stands (pending); the post-write check could not be made' <<<"$SOUT")/$(grep -c 'FAILED' <<<"$SOUT")" "1/0"
pubreset

echo "== pull_request: a published success whose post-write fingerprint moved is replaced by pending 'runs still changing' before the next round =="
pubreset; snap 1 "$DONE"; snap 2 "$DONE"; snap 3 "$RERUN"; snap 4 "$RERUN"; snap 5 "$RERUN"; snap 6 "$RERUN"; publish EVENT_NAME=pull_request
chk "pull_request: initial pending, success, then 'runs still changing' before the re-evaluation, then the re-evaluated pending" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$(post_n 3 | cut -f2)" "pending,success,pending,pending/runs still changing"
chk "pull_request: the 'runs still changing' pending is not the last write: the next round wrote its own verdict, exit 0" "$(post_n 4 | cut -f2 | grep -c 'waiting for')/$RC" "1/0"
pubreset; snap 1 "$DONE"; snap 2 "$DONE"; snap 3 "$RERUN"; snap 4 "$RERUN"; snap 5 "$RERUN"; snap 6 "$RERUN"; publish EVENT_NAME=workflow_run WORKFLOW_RUN_ACTION=completed
chk "workflow_run keeps its behaviour: no 'runs still changing' write between the rounds" "$(cut -f1 "$FAKEGH/posts.log" | paste -sd, -)/$(grep -c 'runs still changing' "$FAKEGH/posts.log" || true)" "success,pending/0"
pubreset; snap 1 "$RERUN"; snap 2 "$RERUN"; snap 3 "$DONE"; snap 4 "$DONE"; snap 5 "$DONE"; publish EVENT_NAME=pull_request
chk "pull_request, a pending verdict whose runs moved: no extra 'runs still changing' (only a published success is replaced)" "$(grep -c 'runs still changing' "$FAKEGH/posts.log" || true)" 0

echo "== bulk-read completeness: total_count must be numeric, and 1000 runs or 1000 check suites are incomplete whatever total_count says =="
read_checks() { # -> LOUT "<rc>|<GATE_API_ERR or ok>": gate_read_checks from the repository's library, no back-off
  LOUT=$( ( export PATH="$FAKEGH/bin:$PATH" FAKEGH_DIR="$FAKEGH" CI_GATE_BACKOFF_MAX_SECONDS=0 CI_GATE_CLOCK="$FAKEGH/bin/clock" GATE_WAITED_FILE="$WORK/lib.waited"
    rm -f "$GATE_WAITED_FILE"
    # shellcheck source=/dev/null
    source "$ROOT/scripts/ci-gate-lib.sh"; gate_read_checks example/repo "$SHA" "$WORK/pg.json"; rc=$?
    if ((rc == 0)); then echo "0|ok"; else echo "$rc|$GATE_API_ERR"; fi ) 2>&1 )
}
for body in '{"workflow_runs":[]}' '{"total_count":"7","workflow_runs":[]}' '{"total_count":null,"workflow_runs":[]}'; do
  pubreset; echo "200~~$body" > "$FAKEGH/inject.runs"; read_runs
  chk "runs listing without a numeric total_count ($body): error 1 (unusable body), not read as 0" "${LOUT%%|*}/$(grep -c 'unusable response body.*no numeric total_count' <<<"$LOUT")" "1/1"
done
for body in '{"check_runs":[]}' '{"total_count":"7","check_runs":[]}' '{"total_count":null,"check_runs":[]}'; do
  pubreset; echo "200~~$body" > "$FAKEGH/inject.checks"; read_checks
  chk "check-runs listing without a numeric total_count ($body): error 1 (unusable body), not read as 0" "${LOUT%%|*}/$(grep -c 'unusable response body.*no numeric total_count' <<<"$LOUT")" "1/1"
done
pubreset; snap 1 "$DONE"; echo '200~~{"workflow_runs":[]}' > "$FAKEGH/inject.runs"; publish
chk "end to end: a runs listing without total_count is a real error: a failure status, exit 1, never an empty snapshot" "$RC/$(post_n 1 | cut -f1)" "1/failure"
many_runs() { jq -nc --argjson n "$1" '[range(1; $n + 1) | {id: ., check_suite_id: (. + 9100), name: "W\(.)", workflow_id: ., event: "push", run_attempt: 1, status: "completed", conclusion: "success", created_at: "2026-11-17T10:00:00Z", updated_at: "2026-11-17T10:05:00Z", path: ".github/workflows/w.yml"}]' > "$FAKEGH/runs.1.json"; }
many_jobs() { # <check runs> <distinct suites>
  jq -nc --argjson n "$1" --argjson s "$2" '[range(1; $n + 1) | {id: ., name: "j\(.)", status: "completed", conclusion: "success", run: {id: (. % $s + 1), name: "r", status: "completed"}}]' > "$FAKEGH/jobs.json"; }
pubreset; many_runs 999; read_runs
chk "999 workflow runs (total_count 999): complete, rc 0" "${LOUT%%|*}" 0
pubreset; many_runs 1000; read_runs
chk "1000 workflow runs (total_count 1000 agrees): incomplete, 75, whatever total_count says" "${LOUT%%|*}/$(grep -c 'snapshot incomplete.*1000 workflow runs.*undocumented' <<<"$LOUT")" "75/1"
pubreset; many_runs 1000; publish
chk "1000 workflow runs end to end: pending (never a verdict), exit 75, no check-runs read" "$(post_n 1 | cut -f1,2 | tr '\t' '|')/$RC/$(ncalls '/check-runs?')" "pending|$UNAVAIL_DESC/75/0"
pubreset; many_jobs 999 999; read_checks
chk "check runs spanning 999 distinct check suites: complete, rc 0" "${LOUT%%|*}" 0
pubreset; many_jobs 1000 1000; read_checks
chk "check runs spanning 1000 distinct check suites (total_count 1000 agrees): incomplete, 75, whatever total_count says" "${LOUT%%|*}/$(grep -c 'snapshot incomplete.*1000 distinct check suites.*undocumented' <<<"$LOUT")" "75/1"
pubreset; many_jobs 1200 2; read_checks
chk "1200 check runs in only 2 suites: complete (the threshold counts distinct suites, not check runs), rc 0" "${LOUT%%|*}" 0
pubreset; snap 1 "$DONE"; many_jobs 1000 1000; publish
chk "1000 check suites end to end: pending (never a verdict or a missing check), exit 75" "$(post_n 1 | cut -f1,2 | tr '\t' '|')/$RC" "pending|$UNAVAIL_DESC/75"
pubreset

echo "== repository coordinate: a leading dot is a name; traversal and malformed ones are not =="
step_script "$WORKFLOW" "Refuse anything but a workflow_run" > "$WORK/refuse.sh"
[ -s "$WORK/refuse.sh" ] && ok "extracted the workflow's validation step" || bad "could not extract the validation step"
refuse() { # VAR=value ... -> RC; defaults: a valid pull_request
  env EVENT_NAME=pull_request HEAD_SHA="$(printf 'b%.0s' $(seq 40))" REPO=example/repo CONTEXT=CI/gate TIMEOUT_MINUTES=180 "$@" bash "$WORK/refuse.sh" > /dev/null 2>&1
  RC=$?
}
refuse; chk "the default inputs are accepted" "$RC" 0
refuse REPO=example/.github; chk "the workflow accepts example/.github" "$RC" 0
refuse REPO=example/.github-private; chk "the workflow accepts a leading-dot name with more" "$RC" 0
refuse REPO=o/r.js; chk "the workflow accepts a dot inside a name" "$RC" 0
for r in a/b/c /x a/ a/. a/.. notacoordinate '' 'a b/c' .a/b -a/b 'a/b c' a//b ../x a/b/; do
  refuse REPO="$r"; chk "the workflow rejects REPO '$r'" "$RC" 1
done
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
REFUSE=$(sed -n "/- name: Refuse anything/,/- name: Read the profile and the verdict scripts/p" "$WORKFLOW")
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
echo "== call budget, coalescing, deprecated inputs and one API helper (read from the YAML with yq) =="
if yq --version > /dev/null 2>&1; then ok "yq is available"; else bad "yq is not installed: the YAML assertions below cannot run"; fi
ym() { yq -r "$2" "$1" 2> /dev/null; }   # <file> <expression>
ON='(.on // .["true"])'                  # PyYAML-based yq reads the key `on` as true
SELFWF="$ROOT/.github/workflows/ci-gate-caller.yml"
WGROUP=$(ym "$WORKFLOW" '.jobs.gate.concurrency.group')
WCANCEL=$(ym "$WORKFLOW" '.jobs.gate.concurrency["cancel-in-progress"]')
[[ $WGROUP == *'github.repository'* && $WGROUP == *'inputs.context'* ]] && ok "coalescing: the group is keyed on the repository and the context" || bad "coalescing: the group lacks the repository or the context: $WGROUP"
[[ $WGROUP == *'github.event.workflow_run.head_sha'* ]] && ok "coalescing: workflow_run is keyed on its head SHA" || bad "coalescing: no workflow_run head SHA in the group"
[[ $WGROUP == *'github.event.pull_request.head.sha'* ]] && ok "coalescing: pull_request is keyed on its head SHA" || bad "coalescing: no pull_request head SHA in the group"
group_key() { # <event> -> the head-SHA part of the group key for that event, evaluated from the expression in the YAML
  local expr alt wr='' pr=''
  case $1 in workflow_run) wr=$(printf 'd%.0s' $(seq 40)) ;; pull_request) pr=$(printf 'e%.0s' $(seq 40)) ;; esac
  expr=$(sed -n 's/.*-\${{ \(github\.event\.workflow_run\.head_sha[^}]*\) }}$/\1/p' <<<"$WGROUP")
  while IFS= read -r alt; do
    case $alt in
      "'"*"'") echo "${alt//\'/}"; return ;;
      github.event.workflow_run.head_sha) [[ -z $wr ]] || { echo "$wr"; return; } ;;
      github.event.pull_request.head.sha) [[ -z $pr ]] || { echo "$pr"; return; } ;;
    esac
  done < <(sed 's/ || /\n/g' <<<"$expr")
}
chk "coalescing: a workflow_run event's key is its head SHA" "$(group_key workflow_run)" "$(printf 'd%.0s' $(seq 40))"
chk "coalescing: a pull_request event's key is its head SHA" "$(group_key pull_request)" "$(printf 'e%.0s' $(seq 40))"
chk "the sweep (schedule) has its own key, which no commit can have" "$(group_key schedule)" sweep
chk "the sweep (workflow_dispatch) has the same own key" "$(group_key workflow_dispatch)" sweep
chk "cancel-in-progress is true for workflow_run and pull_request, and only for them" "$WCANCEL" "\${{ github.event_name == 'workflow_run' || github.event_name == 'pull_request' }}"
for e in schedule workflow_dispatch; do
  [[ $WCANCEL == *"'$e'"* ]] && bad "cancel-in-progress covers the sweep ($e)" || ok "the sweep ($e) is never cancelled by a newer event, and never cancels per-SHA evaluations (own group, no cancel)"
done
REQ_IF="github.event_name != 'pull_request' && (github.event_name != 'workflow_run' || (github.event.workflow_run.name != 'CI gate' && (github.event.action == 'completed' || ((github.event.action == 'requested' || github.event.action == 'in_progress') && github.event.workflow_run.run_attempt > 1))))"
for f in "$SELFWF" "$TEMPLATE"; do
  n=$(basename "$f")
  chk "$n: workflow_run types are exactly [completed, requested, in_progress] (which start event a re-run sends is unconfirmed, so both)" "$(ym "$f" "$ON.workflow_run.types | join(\",\")")" "completed,requested,in_progress"
  chk "$n: the gate job's if: admits completed always and a requested or in_progress event only for a re-run (run_attempt > 1) and keeps the gate's own name out" "$(ym "$f" '.jobs.gate.if')" "$REQ_IF"
  chk "$n: gate-pr passes the context and nothing else (no wait or poll input)" "$(ym "$f" '.jobs["gate-pr"].with | keys | join(",")')" context
  chk "$n: gate passes the context and no wait input" "$(ym "$f" '.jobs.gate.with | keys | join(",")' | sed 's/,timeout_minutes//')" context
  chk "$n: grants checks: read (the gate reads check runs)" "$(ym "$f" '.permissions.checks')" read
  chk "$n: still grants statuses: write, actions: read, contents: read, pull-requests: read" "$(ym "$f" '[.permissions.statuses, .permissions.actions, .permissions.contents, .permissions["pull-requests"]] | join(",")')" "write,read,read,read"
done
chk "the reusable's job asks for checks: read" "$(ym "$WORKFLOW" '.jobs.gate.permissions.checks')" read
chk "the reusable's job asks for exactly statuses, actions, checks, contents, pull-requests" "$(ym "$WORKFLOW" '.jobs.gate.permissions | keys | sort | join(",")')" "actions,checks,contents,pull-requests,statuses"
chk "the job env derives WORKFLOW_RUN_ACTION from the event action, for workflow_run only" "$(ym "$WORKFLOW" '.jobs.gate.env.WORKFLOW_RUN_ACTION')" "\${{ github.event_name == 'workflow_run' && github.event.action || '' }}"
chk "the profile validation step is skipped for a requested or in_progress event (it was not fetched)" "$(ym "$WORKFLOW" '.jobs.gate.steps[] | select(.name == "Validate the profile") | .if')" "\${{ steps.read.outputs.unavailable != 'true' && env.WORKFLOW_RUN_ACTION != 'requested' && env.WORKFLOW_RUN_ACTION != 'in_progress' }}"
for spec in wait_minutes:30 poll_seconds:20; do
  IFS=: read -r inp def <<< "$spec"
  d=$(ym "$WORKFLOW" "$ON.workflow_call.inputs.$inp.description")
  [[ $d == *DEPRECATED* && $d == *IGNORED* ]] && ok "input $inp is still accepted, and documented as DEPRECATED and IGNORED" || bad "input $inp is not documented as deprecated and ignored: $d"
  chk "input $inp keeps its type, default and optionality (pinned callers keep working)" "$(ym "$WORKFLOW" "[$ON.workflow_call.inputs.$inp.type, $ON.workflow_call.inputs.$inp.default, $ON.workflow_call.inputs.$inp.required] | join(\",\")")" "number,$def,false"
done
nc() { grep -hvE '^[[:space:]]*#' "$@"; }   # a file without its comment lines
for f in "$ROOT/scripts/ci-gate-publish.sh" "$WORKFLOW"; do
  [ "$(nc "$f" | grep -cE 'WAIT_SECONDS|WAIT_MINUTES|POLL_SECONDS|wait_again|deadline')" = 0 ] && ok "gate-pr has no wait or poll loop: $(basename "$f") has no wait deadline, wait loop or poll interval" || bad "$(basename "$f") still has a wait or poll loop"
done
[ "$(nc "$ROOT/scripts/ci-gate-publish.sh" | grep -c 'sleep')" = 0 ] && ok "the publisher never sleeps itself (only the library's back-off does)" || bad "the publisher sleeps"
[ "$(nc "$ROOT/scripts/ci-gate-lib.sh" | grep -c 'gate_sleep "')" = 1 ] && ok "the library sleeps in exactly one place, the rate-limit back-off" || bad "the library sleeps in an unexpected place"
chk "no request of the pull_request path other than the two reads, the guard, the verify, the status read and the writes (no 'jobs' endpoint in any script)" "$(nc "$ROOT/scripts/ci-gate-lib.sh" "$ROOT/scripts/ci-gate-publish.sh" "$ROOT/scripts/ci-gate-sweep.sh" | grep -cE 'runs/[^[:space:]"]*/jobs|jobs\?filter')" 0
for f in scripts/ci-gate-publish.sh scripts/ci-gate-sweep.sh; do
  [ "$(nc "$ROOT/$f" | grep -cE '(^|[^_a-z])gh ')" = 0 ] && ok "$f makes no gh call of its own: every request goes through gate_api" || bad "$f calls gh directly"
done
chk "the library has exactly one gh call, inside gate_api" "$(nc "$ROOT/scripts/ci-gate-lib.sh" | grep -cE '^[^#]*\bgh api -i')" 1
chk "the reusable has exactly two gh calls: the bootstrap fetch of the library itself (which cannot use the library it fetches) and the library-less failure write of the fallback step" "$(nc "$WORKFLOW" | grep -cE '(^|[^_a-z])gh api')" 2
chk "the library-less failure write is in the fallback step, and the bootstrap fetch in the bootstrap step" "$(step_script "$WORKFLOW" 'Publish a failure status' | grep -cE '(^|[^_a-z])gh api -X POST')/$(step_script "$WORKFLOW" 'Read the gate library' | grep -cE '(^|[^_a-z])gh api')" "1/1"
chk "no status endpoint is written to outside the library, except that one fallback write" "$(nc "$ROOT/scripts/ci-gate-publish.sh" "$ROOT/scripts/ci-gate-sweep.sh" | grep -c 'statuses/')/$(nc "$WORKFLOW" | grep -c 'statuses/')/$(step_script "$WORKFLOW" 'Publish a failure status' | grep -c 'statuses/')" "0/1/1"
chk "no status description is built outside the library's one writer, except the fallback's fixed one" "$(nc "$ROOT/scripts/ci-gate-publish.sh" "$ROOT/scripts/ci-gate-sweep.sh" | grep -c -- '-f description')/$(nc "$WORKFLOW" | grep -c -- '-f description')/$(step_script "$WORKFLOW" 'Publish a failure status' | grep -c -- '-f description=\"\$desc\"')" "0/1/1"
FBDESC=$(step_script "$WORKFLOW" 'Publish a failure status' | sed -n "s/^ *desc='\(.*\)'$/\1/p")
chk "the fallback's fixed description is plain ASCII and at most 140 characters" "$(printf '%s' "$FBDESC" | LC_ALL=C grep -c '[^ -~]')/$([ -n "$FBDESC" ] && [ ${#FBDESC} -le 140 ] && echo ok)" "0/ok"
chk "the fallback writes the failure inline only when the library file is absent, the library path (gate_post) otherwise" "$(step_script "$WORKFLOW" 'Publish a failure status' | grep -c 'gate_post "\$REPO"')/$(step_script "$WORKFLOW" 'Publish a failure status' | grep -c '^else')" "1/1"
chk "the bootstrap step has an id (bootstrap) and flags unavailable=true only for a transient cause" "$(ym "$WORKFLOW" '.jobs.gate.steps[0].id')/$(step_script "$WORKFLOW" 'Read the gate library' | grep -c 'if ((transient)); then echo "unavailable=true"')" "bootstrap/1"
chk "the library has one description writer, after gate_sanitize" "$(nc "$ROOT/scripts/ci-gate-lib.sh" | grep -c -- '-f description=')" 1
grep -q 'fetch profiles/ci-gate/join-checks.jq' "$WORKFLOW" && ok "the reusable fetches the join" || bad "the reusable does not fetch join-checks.jq"

# Template: workflow_run main path; pull_request only as the permanent gate-pr job (pr_start_ok).
tpl_code() { grep -vE '^[[:space:]]*#' "$1"; }
# A pull_request trigger is allowed ONLY together with a same-repo-only gate-pr job
# and a main job that does not also run on pull_request. pr_start_ok <code-lines-fn> <file>
pr_start_ok() {
  local code=$1 file=$2
  "$code" "$file" | grep -qE '^  pull_request:' || return 1
  "$code" "$file" | grep -qE "^    if: github.event_name != 'pull_request' && \(github.event_name != 'workflow_run' \|\| \(github.event.workflow_run.name != 'CI gate' && \(github.event.action == 'completed' \|\| \(\(github.event.action == 'requested' \|\| github.event.action == 'in_progress'\) && github.event.workflow_run.run_attempt > 1\)\)\)\)$" || return 1
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
tpl_code "$TEMPLATE" | grep -qE '^    types: \[completed, requested, in_progress\]$' \
  && ok "template triggers on workflow_run types completed, requested and in_progress" || bad "template types are not exactly [completed, requested, in_progress]"
tpl_code "$TEMPLATE" | grep -qE 'uses: hyperpolymath/proven-cicd-and-workflows/\.github/workflows/ci-gate\.yml@__CICD_SUITE_SHA__' \
  && ok "template calls the reusable at the __CICD_SUITE_SHA__ placeholder" || bad "template does not call the reusable at the placeholder"
tpl_code "$TEMPLATE" | grep -qE '^  schedule:' && tpl_code "$TEMPLATE" | grep -qE '^    - cron: ' && ok "template has the schedule trigger" || bad "template has no schedule trigger"
tpl_code "$TEMPLATE" | grep -qE '^  workflow_dispatch:' && ok "template has the workflow_dispatch trigger" || bad "template has no workflow_dispatch trigger"
tpl_code "$TEMPLATE" | grep -qE '^  pull-requests: read' && ok "template grants pull-requests: read" || bad "template does not grant pull-requests: read"
tpl_code "$TEMPLATE" | grep -qE "^    if: github.event_name != 'pull_request' && \(github.event_name != 'workflow_run' \|\| \(github.event.workflow_run.name != 'CI gate' && \(github.event.action == 'completed' \|\| \(\(github.event.action == 'requested' \|\| github.event.action == 'in_progress'\) && github.event.workflow_run.run_attempt > 1\)\)\)\)$" && ok "template excludes the gate's own workflow_run events and pull_request from the main job" || bad "template main job if: is wrong"
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
self_code | grep -qE '^    types: \[completed, requested, in_progress\]$' && self_code | grep -qE '^  schedule:' && self_code | grep -qE '^  workflow_dispatch:' \
  && ok "it has workflow_run (completed, requested and in_progress), schedule and workflow_dispatch" || bad "its triggers are not the caller shape"
self_code | grep -qE '^  pull-requests: read' && self_code | grep -qE '^  statuses: write' && self_code | grep -qE '^  actions: read' && self_code | grep -qE '^  checks: read' && self_code | grep -qE '^  contents: read' \
  && ok "it grants statuses: write, actions: read, checks: read, contents: read, pull-requests: read" || bad "its permissions are not the caller shape"
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
