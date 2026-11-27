#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Offline controls for the gate tamper guard: which files are gate files, the label logic, fail-closed
# errors, the CI/gate-tamper-guard publisher (Silence, Firing, a mutant per guard), and static guards
# showing that no workflow uses pull_request_target any more. `gh` is a fake driven by canned files.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/ci-gate-tamper-guard.sh"
STATUS="$ROOT/scripts/ci-gate-tamper-status.sh"
GATE_WF="$ROOT/.github/workflows/ci-gate.yml"
SWEEP="$ROOT/scripts/ci-gate-sweep.sh"
PASS=0; FAIL=0
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
chk() { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', expected '$3'"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
D="$WORK/gh"; mkdir -p "$D/bin"
cat > "$D/bin/gh" <<'GH'
#!/usr/bin/env bash
D=${FAKEGH_DIR:?}
args="$*"; jqarg=''; prev=''
for a in "$@"; do [[ $prev == --jq ]] && jqarg=$a; prev=$a; done
case $args in
  *"/pulls/"*"/files"*)   [[ ! -f $D/failfiles ]] || { echo "gh: HTTP 500" >&2; exit 1; }; jq -c "$jqarg" "$D/files.json" ;;
  *"/issues/"*"/events"*) [[ ! -f $D/failevents ]] || { echo "gh: HTTP 500" >&2; exit 1; }; jq -c "$jqarg" "$D/events.json" ;;
  *"/collaborators/"*"/permission"*)
    [[ ! -f $D/failperm ]] || { echo "gh: HTTP 500" >&2; exit 1; }
    u=${args#*/collaborators/}; u=${u%%/*}; echo "$u" >> "$D/perm.reads"
    p=$(jq -r --arg u "$u" '.[$u] // empty' "$D/perms.json") && [[ -n $p ]] || { echo "gh: HTTP 404" >&2; exit 1; }
    echo "$p" ;;
  *"/pulls/"*"/commits"*) [[ ! -f $D/failcommits ]] || { echo "gh: HTTP 500" >&2; exit 1; }; jq -r "$jqarg" "$D/commits.json" ;;
  *"/pulls/"[0-9]*) [[ ! -f $D/failhead ]] || { echo "gh: HTTP 500 (pull)" >&2; exit 1; }
    n=${args#*/pulls/}; n=${n%%[!0-9]*}; jq -r --arg n "$n" --arg d "${FAKE_HEAD:-}" '.[$n] // $d' "$D/heads.json" ;;
  *"-X POST"*"/statuses/"*)
    [[ ! -f $D/failpost ]] || { echo "gh: HTTP 500 (post)" >&2; exit 1; }
    st=''; ds=''; cx=''
    for a in "$@"; do case $a in state=*) st=${a#state=} ;; description=*) ds=${a#description=} ;; context=*) cx=${a#context=} ;; esac; done
    printf '%s\t%s\t%s\n' "$cx" "$st" "$ds" >> "$D/posts.log" ;;
  *"/commits/"*"/status?per_page=100"*)
    [[ ! -f $D/failstatus ]] || { echo "gh: HTTP 500 (status)" >&2; exit 1; }
    [[ -f $D/standing ]] && cat "$D/standing"; exit 0 ;;
  *) echo "fake gh: unexpected call: $args" >&2; exit 1 ;;
esac
GH
chmod +x "$D/bin/gh"
files() { printf '%s\n' "$@" | jq -R '{filename: .}' | jq -s . > "$D/files.json"; }
events() { printf '%s\n' "$@" | jq -R 'split(" ") | {event: .[0], label: {name: .[1]}, created_at: .[2], actor: (if (.[3] // "boss") == "none" then null else {login: (.[3] // "boss")} end)}' | jq -s . > "$D/events.json"; }
commits() { printf '%s\n' "$@" | jq -R '{commit: {committer: {date: .}}}' | jq -s . > "$D/commits.json"; }
reset() { rm -f "$D"/fail* "$D/perm.reads"; printf '{"boss":"admin","dev":"write","mnt":"maintain","rdr":"read"}' > "$D/perms.json"; files README.adoc; events; commits 2026-11-17T10:00:00Z; }
run() { OUT=$(env PATH="$D/bin:$PATH" FAKEGH_DIR="$D" REPO=o/r PR_NUMBER=7 "$@" bash "$GUARD" 2>&1); RC=$?; }

echo "== which files are gate files =="
for f in .github/workflows/ci-gate.yml .github/workflows/ci-gate-caller.yml .github/workflows/ci-gate-tamper-guard.yml .github/workflows/ci-gate.yaml \
         scripts/check-required-contexts.sh scripts/ci-gate-verdict.sh scripts/ci-gate-tamper-guard.sh scripts/validate-ci-gate-profile.sh \
         templates/ci-gate-caller.yml profiles/ci-gate/hyperpolymath/mathesis.json profiles/ci-gate/validate.jq; do
  bash "$GUARD" --match "$f" > /dev/null && ok "gate file: $f" || bad "not recognised as a gate file: $f"
done
for f in .github/workflows/ci.yml .github/workflows/actions.lock .github/workflows/rust-ci.yml scripts/build.sh scripts/check-required.sh \
         docs/CI-GATE.adoc README.adoc src/ci-gate.yml profiles/other/x.json workflows/ci-gate.yml; do
  bash "$GUARD" --match "$f" > /dev/null && bad "wrongly a gate file: $f" || ok "not a gate file: $f"
done

echo "== no gate file touched: pass, no label needed =="
reset; files README.adoc src/main.rs; run
chk "ordinary pull request: exit 0" "$RC" 0
echo "== gate file touched =="
reset; files README.adoc .github/workflows/ci-gate.yml; run
chk "no label: exit 1" "$RC" 1
chk "no label: names the file and the owner-only rule" "$(grep -c "ci-gate.yml.*not applied.*Only the repository owner.*agents must not" <<<"$OUT")" 1
reset; files scripts/ci-gate-publish.sh; events "labeled gate-change-approved 2026-11-17T11:00:00Z"; commits 2026-11-17T10:00:00Z; run
chk "label applied after the newest commit: exit 0" "$RC" 0
reset; files scripts/ci-gate-publish.sh; events "labeled gate-change-approved 2026-11-17T09:00:00Z"; commits 2026-11-17T10:00:00Z; run
chk "label older than the newest commit: exit 1 (re-apply after every push)" "$RC" 1
chk "label older than the newest commit: says re-apply" "$(grep -c 're-apply it after every push' <<<"$OUT")" 1
reset; files scripts/ci-gate-publish.sh; events "labeled gate-change-approved 2026-11-17T11:00:00Z"; commits 2026-11-17T10:00:00Z 2026-11-17T11:30:00Z; run
chk "a later commit after the label clears it: exit 1" "$RC" 1
reset; files scripts/ci-gate-publish.sh; events "labeled gate-change-approved 2026-11-17T11:00:00Z" "unlabeled gate-change-approved 2026-11-17T11:05:00Z"; run
chk "labeled then unlabeled: exit 1" "$RC" 1
reset; files scripts/ci-gate-publish.sh; events "labeled gate-change-approved 2026-11-17T09:00:00Z" "unlabeled gate-change-approved 2026-11-17T09:05:00Z" "labeled gate-change-approved 2026-11-17T12:00:00Z"; run
chk "labeled, unlabeled, labeled again after the commit: exit 0" "$RC" 0
reset; files scripts/ci-gate-publish.sh; events "labeled other-label 2026-11-17T11:00:00Z"; run
chk "some other label: exit 1" "$RC" 1
reset; files scripts/ci-gate-publish.sh; events "labeled gate-change-approved 2026-11-17T11:00:00Z"; commits 2026-11-17T10:00:00Z; run APPROVAL_LABEL=custom-label
chk "the label name is configurable and the default label is then not enough: exit 1" "$RC" 1
reset; files scripts/ci-gate-publish.sh; events "labeled gate-change-approved 2026-11-17T11:00:00Z"; commits 2026-11-17T10:00:00Z; run
chk "label time equal to commit time is not enough (strictly after)" "$( commits 2026-11-17T11:00:00Z; run; echo $RC)" 1
echo "== the label counts only if its latest labeled event was by an admin =="
LBL="labeled gate-change-approved 2026-11-17T11:00:00Z"
reset; files scripts/ci-gate-publish.sh; events "$LBL boss"; run
chk "admin actor, label after the newest commit: exit 0" "$RC" 0
chk "admin actor: the permission endpoint was read for that login" "$(cat "$D/perm.reads")" boss
reset; files scripts/ci-gate-publish.sh; events "$LBL dev"; run
chk "write actor: exit 1" "$RC" 1
chk "write actor: says not admin and names the actor and permission" "$(grep -c "applied by 'dev' whose repository permission is 'write', not admin" <<<"$OUT")" 1
reset; files scripts/ci-gate-publish.sh; events "$LBL mnt"; run
chk "maintain actor: exit 1" "$RC" 1
chk "maintain actor: says not admin" "$(grep -c "permission is 'maintain', not admin" <<<"$OUT")" 1
reset; files scripts/ci-gate-publish.sh; events "$LBL rdr"; run
chk "read actor: exit 1" "$RC" 1
reset; files scripts/ci-gate-publish.sh; events "$LBL boss"; : > "$D/failperm"; run
chk "permission API error: exit 1" "$RC" 1
chk "permission API error: says no verdict" "$(grep -c 'could not read the repository permission of .boss.; no verdict' <<<"$OUT")" 1
reset; files scripts/ci-gate-publish.sh; events "$LBL stranger"; run
chk "actor unknown to the permission API (404): exit 1" "$RC" 1
reset; files scripts/ci-gate-publish.sh; events "$LBL none"; run
chk "no actor on the event (deleted account): exit 1" "$RC" 1
chk "no actor: never calls the permission endpoint" "$(cat "$D/perm.reads" 2>/dev/null | grep -c . || true)" 0
reset; files scripts/ci-gate-publish.sh; events "$LBL ../../x"; run
chk "a login that is not a login is refused before any URL is built" "$RC/$(cat "$D/perm.reads" 2>/dev/null | grep -c . || true)" "1/0"
reset; files scripts/ci-gate-publish.sh; events "labeled gate-change-approved 2026-11-17T09:00:00Z dev" "unlabeled gate-change-approved 2026-11-17T09:30:00Z boss" "labeled gate-change-approved 2026-11-17T11:00:00Z boss"; run
chk "the LATEST labeled event decides: an earlier write actor does not matter" "$RC" 0
reset; files scripts/ci-gate-publish.sh; events "labeled gate-change-approved 2026-11-17T09:00:00Z boss" "unlabeled gate-change-approved 2026-11-17T09:30:00Z boss" "labeled gate-change-approved 2026-11-17T11:00:00Z dev"; run
chk "the LATEST labeled event decides: an earlier admin does not rescue a later write actor" "$RC" 1
reset; files scripts/ci-gate-publish.sh; events "labeled gate-change-approved 2026-11-17T09:00:00Z boss"; commits 2026-11-17T10:00:00Z; run
chk "admin label older than the newest commit: still exit 1" "$RC" 1
reset; files README.adoc; events "$LBL dev"; run
chk "no gate file touched: the permission endpoint is not even read" "$RC/$(cat "$D/perm.reads" 2>/dev/null | grep -c . || true)" "0/0"

echo "-- a rename counts through its old name --"
printf '%s\n' '[{"filename":"docs/x.adoc","previous_filename":".github/workflows/ci-gate.yml"}]' > "$D/files.json"; events; run
chk "renamed away from a gate file: exit 1" "$RC" 1
echo "== errors fail closed =="
reset; files .github/workflows/ci-gate.yml; : > "$D/failfiles"; run
chk "files API error: exit 1" "$RC" 1
reset; files .github/workflows/ci-gate.yml; : > "$D/failevents"; run
chk "events API error on a gate-file PR: exit 1" "$RC" 1
reset; files .github/workflows/ci-gate.yml; events "labeled gate-change-approved 2026-11-17T11:00:00Z"; : > "$D/failcommits"; run
chk "commits API error: exit 1" "$RC" 1
reset; run PR_NUMBER=abc
chk "bad PR number: exit 1" "$RC" 1
reset; files README.adoc; run REPO=example/.github
chk "dot-prefixed repository: exit 0" "$RC" 0
reset; files README.adoc; run REPO=example/.github-private
chk "dot-prefixed name with more: exit 0" "$RC" 0
for coordinate in /repo owner/ owner/repo/extra owner//repo -owner/repo 'owner/repo?x' a/. a/.. ../x /x a/b/c; do
  reset; run REPO="$coordinate"
  chk "malformed coordinate $coordinate: exit 1" "$RC" 1
done
reset; run REPO=notacoordinate
chk "bad repo: exit 1" "$RC" 1
reset; run APPROVAL_LABEL='a b;c'
chk "bad label name: exit 1" "$RC" 1
reset; seq 1 3000 | sed 's|^|f|' > /dev/null; jq -n '[range(0;3000) | {filename: ("f" + tostring)}]' > "$D/files.json"; run
chk "3000 changed files cannot be checked: exit 1" "$RC" 1
reset; jq -n '[range(0;2999) | {filename: ("f" + tostring), previous_filename: ("old" + tostring)}]' > "$D/files.json"; run
chk "2999 renamed files count once each: exit 0" "$RC" 0
jq '.[0].previous_filename = "scripts/ci-gate-publish.sh"' "$D/files.json" > "$D/renamed.json"; mv "$D/renamed.json" "$D/files.json"; run
chk "old protected path still detected among 2999 renames" "$RC/$(grep -c "scripts/ci-gate-publish.sh.*not applied" <<< "$OUT")" "1/1"
reset; jq -n '[range(0;3000) | {filename: ("f" + tostring), previous_filename: ("old" + tostring)}]' > "$D/files.json"; run
chk "3000 renamed files reach the API record limit: exit 1" "$RC" 1
reset; files .github/workflows/ci-gate.yml; events "labeled gate-change-approved 2026-11-17T11:00:00Z"; : > "$D/commits.json"; echo '[]' > "$D/commits.json"; run
chk "no commits listed: exit 1" "$RC" 1
chk "the guard never applies a label: it calls only read endpoints" "$(grep -c -- '-X \(POST\|PUT\|PATCH\|DELETE\)\|--method' "$GUARD")" 0

echo "== CI/gate-tamper-guard publisher: Silence and Firing =="
SHA=$(printf 'b%.0s' $(seq 40))
MOVED=$(printf 'c%.0s' $(seq 40))
SUT="$STATUS"
SUITE_T="$WORK/suite"; mkdir -p "$SUITE_T/scripts"; cp "$GUARD" "$SUITE_T/scripts/"
pub() { # [VAR=value ...] -> PRC, POUT, NP (posts), LASTP (context<TAB>state<TAB>description)
  : > "$D/posts.log"
  POUT=$(env PATH="$D/bin:$PATH" FAKEGH_DIR="$D" FAKE_HEAD="$SHA" REPO=o/r HEAD_SHA="$SHA" PR_NUMBERS=7 SUITE="$SUITE_T" RUN_ID=1 "$@" bash "$SUT" 2>&1); PRC=$?
  NP=$(grep -c . "$D/posts.log"); LASTP=$(tail -n 1 "$D/posts.log")
}
preset() { reset; rm -f "$D/standing" "$D/posts.log" "$D/failhead"; echo '{}' > "$D/heads.json"; }
# Each case prints nothing and returns 0 when the publisher behaves; the mutants below must make one fail.
case_silence()      { preset; pub; [[ $PRC == 0 && $NP == 1 && $LASTP == $'CI/gate-tamper-guard\tsuccess\t'* ]]; }
case_firing()       { preset; files .github/workflows/ci-gate.yml; pub; [[ $PRC == 0 && $NP == 1 && $LASTP == $'CI/gate-tamper-guard\tfailure\t#7: this pull request touches gate files'* ]]; }
case_approved()     { preset; files scripts/ci-gate-publish.sh; events "labeled gate-change-approved 2026-11-17T11:00:00Z"; pub; [[ $PRC == 0 && $LASTP == $'CI/gate-tamper-guard\tsuccess\t'* ]]; }
case_one_of_two()   { preset; files .github/workflows/ci-gate.yml; pub PR_NUMBERS="7 7 9"; [[ $PRC == 0 && $NP == 1 && $LASTP == *$'\tfailure\t#7 #9: this pull request touches'* ]]; }
case_no_pr()        { preset; pub PR_NUMBERS=''; [[ $PRC == 0 && $NP == 0 ]]; }
case_bad_number()   { preset; pub PR_NUMBERS='7 0x9'; [[ $PRC == 1 && $NP == 0 && $POUT == *'NO TAMPER VERDICT'* ]]; }
case_bad_sha()      { preset; pub HEAD_SHA=abc; [[ $PRC == 1 && $NP == 0 ]]; }
case_bad_repo()     { preset; pub REPO='a/..'; [[ $PRC == 1 && $NP == 0 ]]; }
case_no_guard()     { preset; pub SUITE="$WORK/empty"; [[ $PRC == 1 && $NP == 0 ]]; }
case_guard_error()  { preset; touch "$D/failfiles"; pub; [[ $PRC == 0 && $LASTP == $'CI/gate-tamper-guard\tfailure\t#7: could not list the changed files'* ]]; }
case_standing()     { preset; printf '{"context":"CI/gate-tamper-guard","state":"success","description":"no unapproved gate-file change in PR #7"}\n' > "$D/standing"; pub; [[ $PRC == 0 && $NP == 0 && $POUT == *'write skipped'* ]]; }
case_other_ctx()    { preset; printf '{"context":"CI/gate","state":"success","description":"no unapproved gate-file change in PR #7"}\n' > "$D/standing"; pub; [[ $PRC == 0 && $NP == 1 ]]; }
case_status_fail()  { preset; touch "$D/failstatus"; pub; [[ $PRC == 0 && $NP == 1 ]]; }
case_post_fail()    { preset; touch "$D/failpost"; pub; [[ $PRC == 1 && $POUT == *'NO TAMPER VERDICT'* ]]; }
case_clip()         { preset; files .github/workflows/ci-gate.yml; pub PR_NUMBERS="$(seq 1 30 | paste -sd' ' -)"; d=${LASTP##*$'\t'}; [[ $(jq -rn --arg d "$d" '$d | length') -le 140 ]]; }
case_moved()        { preset; files .github/workflows/ci-gate.yml; echo "{\"7\":\"$MOVED\"}" > "$D/heads.json"; pub; [[ $PRC == 0 && $NP == 0 && $POUT == *"#7 now heads $MOVED"* ]]; }
case_moved_one()    { preset; files .github/workflows/ci-gate.yml; echo "{\"7\":\"$MOVED\"}" > "$D/heads.json"; pub PR_NUMBERS="7 9"; [[ $PRC == 0 && $NP == 1 && $LASTP == $'CI/gate-tamper-guard\tfailure\t#9: '* ]]; }
case_head_fail()    { preset; touch "$D/failhead"; pub; [[ $PRC == 0 && $NP == 1 && $LASTP == $'CI/gate-tamper-guard\tfailure\t#7: could not read the head of #7'* ]]; }
case_head_fail_keeps() { preset; files .github/workflows/ci-gate.yml; touch "$D/failhead"; pub; [[ $LASTP == $'CI/gate-tamper-guard\tfailure\t#7: this pull request touches gate files'* ]]; }
CASES=(case_silence case_firing case_approved case_one_of_two case_no_pr case_bad_number case_bad_sha case_bad_repo
       case_no_guard case_guard_error case_standing case_other_ctx case_status_fail case_post_fail case_clip
       case_moved case_moved_one case_head_fail case_head_fail_keeps)
for c in "${CASES[@]}"; do "$c" && ok "$c" || bad "$c (rc=$PRC posts=$NP last='$LASTP')"; done
chk "the publisher writes only commit statuses (no label, no other write)" \
  "$(grep -oE -- '-X (POST|PUT|PATCH|DELETE) "[^"]*' "$STATUS" | sort -u)" '-X POST "repos/$REPO/statuses/$HEAD_SHA'

echo "== mutants: each guard in the publisher is killed by a case =="
# <case> <description> <python expression old>|||<new>: the mutant must make the case fail.
mutant() {
  local c=$1 what=$2 old=$3 new=$4 m="$WORK/mutant.sh"
  python3 -c 'import sys; s=open(sys.argv[1]).read(); assert s.count(sys.argv[2])>=1, "anchor missing"; open(sys.argv[4],"w").write(s.replace(sys.argv[2],sys.argv[3],1))' \
    "$STATUS" "$old" "$new" "$m" || { bad "mutant '$what': anchor not found (the publisher changed; update the mutant)"; return; }
  SUT=$m; if "$c" > /dev/null 2>&1; then bad "mutant survived: $what ($c still passes)"; else ok "mutant killed: $what (by $c)"; fi; SUT=$STATUS
}
mutant case_firing      'a guard failure does not fail the status'       'state=failure; failed+=("#$n")'        'failed+=("#$n")'
mutant case_guard_error 'a guard error is ignored'                         'if ((rc != 0)); then'                   'if ((rc > 1)); then'
mutant case_one_of_two  'only the first pull request is judged'            'for n in "${prs[@]}"; do'$'\n''  out='   'for n in "${prs[@]:0:1}"; do'$'\n''  out='
mutant case_bad_number  'a malformed pull request number is accepted'      '|| fail "pull request number'           '|| true "pull request number'
mutant case_bad_sha     'the head SHA is not checked'                      '|| fail '"'"'HEAD_SHA is not a 40-hex commit'"'" '|| true '"'"'HEAD_SHA is not a 40-hex commit'"'"
mutant case_bad_repo    'the repository coordinate is not checked'         '|| fail '"'"'REPO is not'                   '|| true '"'"'REPO is not'
mutant case_no_guard    'a missing guard script is not refused'            '|| fail '"'"'the guard script is missing'   '|| true '"'"'the guard script is missing'
mutant case_no_pr       'no pull request still publishes'                  'if ((${#prs[@]} == 0)); then'           'if ((${#prs[@]} < 0)); then'
mutant case_standing    'a standing status is written again'               'if [[ $same == same ]]; then'           'if [[ $same == never ]]; then'
mutant case_other_ctx   'another context counts as standing'               '.context == $c and'                     'true and'
mutant case_post_fail   'a failed POST counts as published'                '|| fail "could not publish the'         '|| true "could not publish the'
mutant case_clip        'the description is not clipped'                   'if length > 140 then'                   'if length > 99999 then'
mutant case_moved      'a moved head is still published'              '&& $now != "$HEAD_SHA" ]]; then'   '&& $now == never ]]; then'
mutant case_head_fail  'a failed head read counts as the same head'   '|| now='"''"   '|| now=$HEAD_SHA'
mutant case_moved_one  'a moved pull request is still counted'         '    continue'$'\n''  fi'   '    :'$'\n''  fi'
mutant case_head_fail_keeps 'a failed head read hides the guard reason' '((rc != 0)) || out='   'out='

echo "== static guards: no pull_request_target anywhere; the gate runs the guard from the default branch =="
code() { grep -vE '^[[:space:]]*#' "$1"; }
for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/templates/*.yml; do
  code "$f" | grep -q 'pull_request_target' && bad "$(basename "$f") still uses pull_request_target"
done
ok "no workflow or template in the suite triggers on pull_request_target"
for f in .github/workflows/ci-gate-tamper-guard.yml .github/workflows/ci-gate-tamper-guard-caller.yml templates/ci-gate-tamper-guard-caller.yml; do
  [ -e "$ROOT/$f" ] && bad "$f still exists" || ok "$f is removed"
  jq -e --arg p "$f" 'any(.workflows[]; .path == $p)' "$ROOT/config/workflow-lock-scope.json" >/dev/null && bad "lock scope still lists $f" || ok "lock scope does not list $f"
done
for s in ci-gate-tamper-guard.sh ci-gate-tamper-status.sh; do
  grep -qE "^          fetch scripts/$s$" "$GATE_WF" && ok "the gate fetches $s from the suite at its own commit" || bad "the gate does not fetch $s"
done
tstep=$(awk '/- name: Publish the gate tamper guard status/{p=1} p&&/- name: Publish a failure status/{exit} p' "$GATE_WF")
grep -qE "if: \\$\\{\\{ !cancelled\\(\\) && github\\.event_name == 'workflow_run' && github\\.event\\.action == 'completed' \\}\\}" <<< "$tstep" \
  && ok "the gate's tamper step runs only on workflow_run completed (never on the pull_request job)" || bad "the tamper step's condition is wrong"
grep -qF 'PR_NUMBERS: ${{ join(github.event.workflow_run.pull_requests.*.number, '"' '"') }}' <<< "$tstep" \
  && ok "the tamper step takes its pull requests from the workflow_run payload through env" || bad "the tamper step does not take PR_NUMBERS from the payload"
! grep -vE '^[[:space:]]*#' <<< "$tstep" | sed -n '/run: |/,$p' | grep -q '\${{' && ok "the tamper step has no \${{ }} inside its run: script" || bad "the tamper step interpolates into run:"
grep -q 'ci-gate-tamper-status.sh' "$SWEEP" && ok "the sweep runs the tamper status for pull request heads" || bad "the sweep does not run the tamper status"
for f in "$STATUS" "$GATE_WF" "$ROOT/templates/ci-gate-caller.yml" "$ROOT/.github/workflows/ci-gate-caller.yml"; do
  grep -q 'AGENTS MUST NEVER APPLY TH\(E\|AT\) \(APPROVAL \)\?LABEL' "$f" && ok "$(basename "$f") says agents must never apply the label" || bad "$(basename "$f") lacks the agents-never-apply note"
done
code "$STATUS" | grep -qE 'actions/checkout|github\.actor|sender\.login' && bad "the publisher checks out code or trusts an actor field" || ok "the publisher checks out nothing and trusts no actor field"

echo "== the approval label name: one default, said the same everywhere =="
chk "the default is defined exactly once, in the script" "$(grep -c 'APPROVAL_LABEL:-' "$GUARD")" 1
DEFAULT_LABEL=$(sed -n 's/^APPROVAL_LABEL=\${APPROVAL_LABEL:-\([^}]*\)}$/\1/p' "$GUARD")
chk "the script's default label" "$DEFAULT_LABEL" gate-change-approved
for f in "$STATUS" "$GATE_WF" "$ROOT/templates/ci-gate-caller.yml" "$ROOT/.github/workflows/ci-gate-caller.yml" "$ROOT/docs/CI-GATE.adoc"; do
  b=$(basename "$f")
  others=$(grep -oE '[a-z]+(-[a-z]+)*-approved\b' "$f" | sort -u | grep -vxF "$DEFAULT_LABEL" || true)
  [ -z "$others" ] && ok "$b names no approval label but the default" || bad "$b names another approval label: $others"
done
echo
printf 'ci-gate-tamper-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
