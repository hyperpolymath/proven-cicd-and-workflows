#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Offline controls for the gate tamper guard: which files are gate files, the label logic, fail-closed
# errors, and static guards on the reusable and its callers. `gh` is a fake driven by canned files.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/ci-gate-tamper-guard.sh"
WF="$ROOT/.github/workflows/ci-gate-tamper-guard.yml"
SELF="$ROOT/.github/workflows/ci-gate-tamper-guard-caller.yml"
TPL="$ROOT/templates/ci-gate-tamper-guard-caller.yml"
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

echo "== static guards =="
code() { grep -vE '^[[:space:]]*#' "$1"; }
for f in "$WF" "$SELF" "$TPL"; do
  b=$(basename "$f")
  code "$f" | grep -qE 'actions/checkout|ref: *\$\{\{ *github\.(event\.pull_request\.head|head_ref)' && bad "$b checks out code" || ok "$b has no checkout"
  code "$f" | grep -qE 'github\.actor|actor\.login|sender\.login|user\.login' && bad "$b makes a decision on a forgeable actor field" || ok "$b has no actor-based trust decision"
  grep -qE '^[[:space:]]*secrets:' "$f" && bad "$b has a secrets: line" || ok "$b has no secrets"
  grep -q 'AGENTS MUST NEVER APPLY THAT LABEL' "$f" && ok "$b says agents must never apply the label" || bad "$b lacks the agents-never-apply note"
done
code "$WF" | grep -qE '^  workflow_call:' && ! code "$WF" | grep -qE '^  (push|pull_request|pull_request_target|workflow_run|schedule):' && ok "the reusable is workflow_call only" || bad "the reusable has other triggers"
code "$WF" | grep -qE '^      pull-requests: read' && code "$WF" | grep -qE '^      contents: read' && ! code "$WF" | grep -qE '(write|issues:|statuses:)' && ok "the reusable asks for pull-requests: read and contents: read only" || bad "the reusable's permissions are not minimal"
! grep -qE '^[[:space:]]*(- )?uses:' "$WF" && ok "the reusable uses no actions" || bad "the reusable has a uses: line"
grep -q 'pull_request_target' <(sed -n '/Refuse anything but/,/Read the guard script/p' "$WF") && ok "the reusable refuses every event but pull_request_target" || bad "the reusable does not refuse other events"
code "$WF" | grep -qE '^  check:' && code "$WF" | grep -qE '^    name: check$' && ok "the reusable job is check (the gate profile entry is 'guard / check')" || bad "the reusable job is not named check"
for f in "$SELF" "$TPL"; do
  b=$(basename "$f")
  code "$f" | grep -qE '^  pull_request_target:' && code "$f" | grep -qE '^    types: \[opened, reopened, synchronize, labeled, unlabeled\]' && ok "$b: pull_request_target with the five types" || bad "$b: wrong trigger or types"
  code "$f" | grep -qE '^  pull-requests: read' && code "$f" | grep -qE '^  contents: read' && ! code "$f" | grep -qE '^  [a-z-]+: write' && ok "$b: read-only permissions" || bad "$b: permissions not minimal"
  code "$f" | grep -qE '^  guard:' && ok "$b: job id is guard" || bad "$b: job id is not guard"
done
code "$TPL" | grep -qE 'uses: hyperpolymath/proven-cicd-and-workflows/\.github/workflows/ci-gate-tamper-guard\.yml@__CICD_SUITE_SHA__' && ok "the template pins the reusable at the placeholder" || bad "the template does not use the placeholder"
code "$SELF" | grep -qE '^    uses: \./\.github/workflows/ci-gate-tamper-guard\.yml$' && ok "the suite's caller uses the local reusable" || bad "the suite's caller does not use the local reusable"
for b in ci-gate-tamper-guard.yml ci-gate-tamper-guard-caller.yml; do
  jq -e --arg p ".github/workflows/$b" 'any(.workflows[]; .path == $p)' "$ROOT/config/workflow-lock-scope.json" >/dev/null && ok "lock scope lists $b" || bad "lock scope lacks $b"
done
for f in "$WF" "$SELF" "$TPL"; do
  b=$(basename "$f")
  [ -z "$(awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    { line = $0
      if (inblock) { if (line ~ /^[[:space:]]*$/ || ind(line) > keycol) { if (line ~ /\$\{\{/) print NR; next } inblock = 0 }
      if (line ~ /^[[:space:]]*(- )?run:/) { keycol = ind(line) + (line ~ /^[[:space:]]*- / ? 2 : 0)
        rest = line; sub(/^[[:space:]]*(- )?run:[[:space:]]*/, "", rest)
        if (rest ~ /^[|>]/) inblock = 1; else if (rest ~ /\$\{\{/) print NR } }' "$f")" ] \
    && ok "$b has no \${{ }} inside a run: script" || bad "$b interpolates into a run: script"
done
code "$WF" | grep -qE '^[[:space:]]+run:' && ok "the reusable has run: steps (the check had something to scan)" || bad "the reusable has no run: steps"
echo "== the approval label name: one default, said the same everywhere =="
chk "the default is defined exactly once, in the script" "$(grep -c 'APPROVAL_LABEL:-' "$GUARD")" 1
DEFAULT_LABEL=$(sed -n 's/^APPROVAL_LABEL=\${APPROVAL_LABEL:-\([^}]*\)}$/\1/p' "$GUARD")
chk "the script's default label" "$DEFAULT_LABEL" gate-change-approved
for f in "$WF" "$SELF" "$TPL" "$ROOT/templates/ci-gate-caller.yml" "$ROOT/.github/workflows/ci-gate-caller.yml" "$ROOT/docs/CI-GATE.adoc"; do
  b=$(basename "$f")
  others=$(grep -oE '[a-z]+(-[a-z]+)*-approved\b' "$f" | sort -u | grep -vxF "$DEFAULT_LABEL" || true)
  [ -z "$others" ] && ok "$b names no approval label but the default" || bad "$b names another approval label: $others"
done
echo
printf 'ci-gate-tamper-guard: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
