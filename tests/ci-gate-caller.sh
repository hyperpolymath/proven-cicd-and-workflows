#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Offline controls for scripts/ci-gate-caller.sh (render + drift check). A throwaway git repo
# stands in for the suite clone, so nothing here touches the network or a real consumer.
# Needs Go yq v4 first on PATH. Run it under each jq version the estate supports.
# Every drift kind is shown failing on a drifted tree and passing after render.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER="$ROOT/scripts/ci-gate-caller.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
yq --version 2>/dev/null | grep -q mikefarah || { echo 'tests/ci-gate-caller.sh: needs mikefarah yq v4 on PATH' >&2; exit 2; }
echo "jq: $(jq --version)  yq: $(yq --version | awk '{print $NF}')"

REPO=hyperpolymath/fixture-repo
SUITE="$WORK/suite"; mkdir -p "$SUITE/templates" "$SUITE/profiles/ci-gate/hyperpolymath"
git -C "$SUITE" init -q
git -C "$SUITE" config user.email t@example.invalid; git -C "$SUITE" config user.name t
git -C "$SUITE" config commit.gpgsign false
cp "$ROOT/templates/ci-gate-caller.yml" "$SUITE/templates/"
sed 's#example/repo#'"$REPO"'#' "$ROOT/tests/fixtures/ci-gate/profile.json" > "$SUITE/profiles/ci-gate/$REPO.json"
git -C "$SUITE" add -A; git -C "$SUITE" commit -qm A; SHA_A=$(git -C "$SUITE" rev-parse HEAD)
echo '# a later template revision' >> "$SUITE/templates/ci-gate-caller.yml"
git -C "$SUITE" commit -qam B; SHA_B=$(git -C "$SUITE" rev-parse HEAD)
printf '{"not":"a profile"}\n' > "$SUITE/profiles/ci-gate/hyperpolymath/bad-profile.json"
git -C "$SUITE" add -A; git -C "$SUITE" commit -qm C; SHA_C=$(git -C "$SUITE" rev-parse HEAD)
git -C "$SUITE" rm -q --cached -r templates >/dev/null; rm -rf "$SUITE/templates"
git -C "$SUITE" commit -qm 'no template'; SHA_NOTPL=$(git -C "$SUITE" rev-parse HEAD)
git -C "$SUITE" checkout -q "$SHA_C" -- templates 2>/dev/null; git -C "$SUITE" reset -q --hard "$SHA_C"

run() { OUT=$(bash "$CALLER" "$@" 2>&1); RC=$?; }
render() { run render --suite "$SUITE" --suite-sha "${SHA:-$SHA_A}" --repo "${R:-$REPO}" --checkout "$C"; }
check()  { run check --suite "$SUITE" --checkout "$C" "$@"; }
mk() { C="$WORK/c$((++N))"; mkdir -p "$C/.github/workflows"; }
tree() { (cd "$C" && find . -type f | sort | xargs -r sha256sum); }
expect() { # <label> <rc> [substring]
  if [ "$RC" -eq "$2" ]; then ok "$1: exit $2"; else bad "$1: exit $RC, expected $2 -- $OUT"; fi
  if [ -n "${3:-}" ]; then case "$OUT" in *"$3"*) ok "$1: names '$3'" ;; *) bad "$1: output lacks '$3' -- $OUT" ;; esac; fi
}
N=0
GUARD_BODY="name: Gate tamper guard
on:
  pull_request_target:
jobs:
  guard:
    uses: hyperpolymath/proven-cicd-and-workflows/.github/workflows/ci-gate-tamper-guard.yml@$SHA_A # cicd-suite tamper guard
"

echo "== fresh render =="
mk; render; expect "render into an empty checkout" 0 "wrote: .github/workflows/ci-gate.yml"
F="$C/.github/workflows/ci-gate.yml"
{ ! grep -q '__CICD_SUITE_SHA__' "$F" && [ "$(grep -c "ci-gate.yml@$SHA_A" "$F")" -eq 2 ]; } \
  && ok "both reusable calls carry the 40-hex pin, no placeholder left" || bad "pin substitution wrong"
git -C "$SUITE" show "$SHA_A:templates/ci-gate-caller.yml" | sed "s/__CICD_SUITE_SHA__/$SHA_A/g" | cmp -s - "$F" \
  && ok "rendered file is the template at the pinned SHA, byte for byte" || bad "rendered file differs from template"
[ ! -e "$C/$(printf '.github/workflows/actions.lock')" ] && ok "no actions.lock created when the checkout has none" || bad "actions.lock invented"
check --repo "$REPO"; expect "check on a freshly rendered tree" 0 "clean"

echo "== the caller is judged at its OWN pin, not the newest template =="
mk; SHA=$SHA_A render; cp "$C/.github/workflows/ci-gate.yml" "$WORK/pinA.yml"
SHA=$SHA_B render; expect "re-render at a newer SHA" 0 "wrote"
check; expect "newer pin renders clean" 0 "clean"
cp "$WORK/pinA.yml" "$C/.github/workflows/ci-gate.yml"
check; expect "older pin still clean against ITS template" 0 "clean"

echo "== idempotence =="
mk; render; T1=$(tree); render; expect "second render" 0 "unchanged: .github/workflows/ci-gate.yml"
[ "$T1" = "$(tree)" ] && ok "second render changes no byte" || bad "second render changed the tree"

echo "== lock: gains [] =="
mk; cp "$ROOT/tests/fixtures/actions-lock/v0.0.2.lock" "$C/.github/workflows/actions.lock"
L="$C/.github/workflows/actions.lock"; cp "$L" "$WORK/lock.before"
check; expect "check before: lock lacks the entry" 1 "DRIFT lock-entry-missing"
render; expect "render adds the entry" 0 "added '.github/workflows/ci-gate.yml': []"
D=$(diff "$WORK/lock.before" "$L")
[ "$(grep -c '^[<>]' <<<"$D")" -eq 1 ] && grep -q "^> *'.github/workflows/ci-gate.yml': \[\]$" <<<"$D" \
  && ok "the only lock change is the one new empty entry" || bad "lock diff is more than one added line: $D"
[ "$(yq -o=json -I0 '.workflows[".github/workflows/ci-gate.yml"]' "$L")" = '[]' ] && ok "entry is the empty list, no leaf record" || bad "entry not []"
[ "$(yq '.workflows | keys | .[]' "$L")" = "$(yq '.workflows | keys | .[]' "$L" | LC_ALL=C sort)" ] && ok "keys stay in byte order" || bad "keys out of order"
check; expect "check after" 0 "clean"
T1=$(tree); render; [ "$T1" = "$(tree)" ] && ok "second render leaves the lock untouched" || bad "lock not idempotent"

echo "== lock: a leaf record becomes [] =="
mk; cp "$ROOT/tests/fixtures/actions-lock/v0.0.2.lock" "$C/.github/workflows/actions.lock"; L="$C/.github/workflows/actions.lock"
yq -i -I4 ".workflows[\".github/workflows/ci-gate.yml\"] = [\"hyperpolymath/proven-cicd-and-workflows/.github/workflows/ci-gate.yml@$SHA_A\"]" "$L"
check; expect "check before: leaf record" 1 "DRIFT lock-entry-not-empty"
render; expect "render replaces it" 0 "replaced leaf record"
[ "$(yq -o=json -I0 '.workflows[".github/workflows/ci-gate.yml"]' "$L")" = '[]' ] && ok "leaf replaced by []" || bad "leaf survived"
grep -q "ci-gate.yml@" "$L" && bad "leaf text still in lock" || ok "no leaf text remains"
check; expect "check after" 0 "clean"

echo "== guard caller removal =="
mk; printf '%s' "$GUARD_BODY" > "$C/.github/workflows/ci-gate-tamper-guard-caller.yml"
printf '%s' "$GUARD_BODY" | sed 's/^name: .*/name: other guard/' > "$C/.github/workflows/ci-gate-tamper-guard.yml"
printf 'name: unrelated\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps: [{run: "true"}]\n' > "$C/.github/workflows/ci-gate-tamper-guard-notes.yml"
cp "$ROOT/tests/fixtures/actions-lock/v0.0.2.lock" "$C/.github/workflows/actions.lock"; L="$C/.github/workflows/actions.lock"
yq -i -I4 '.workflows[".github/workflows/ci-gate-tamper-guard-caller.yml"] = []' "$L"
check; expect "check before: leftover guard" 1 "DRIFT guard-caller-leftover"
case "$OUT" in *"DRIFT lock-extra-entry"*) ok "check before: names lock-extra-entry" ;; *) bad "lock-extra-entry not named -- $OUT" ;; esac
render; expect "render removes the guard callers" 0 "removed retired guard caller: .github/workflows/ci-gate-tamper-guard-caller.yml"
[ ! -e "$C/.github/workflows/ci-gate-tamper-guard-caller.yml" ] && [ ! -e "$C/.github/workflows/ci-gate-tamper-guard.yml" ] \
  && ok "both suite-calling guard files are gone" || bad "guard file survived"
[ -e "$C/.github/workflows/ci-gate-tamper-guard-notes.yml" ] && ok "a same-glob file that does not call the suite is kept" || bad "unrelated file deleted"
grep -q 'tamper-guard' "$L" && bad "guard lock entry survived" || ok "guard lock entry removed"
check; expect "check after" 0 "clean"

echo "== guard detection is parsed, and a record for an unrelated same-glob file is kept =="
mk; cp "$ROOT/tests/fixtures/actions-lock/v0.0.2.lock" "$C/.github/workflows/actions.lock"; L="$C/.github/workflows/actions.lock"
printf 'name: g\non: pull_request_target\njobs: {guard: {uses: "hyperpolymath/proven-cicd-and-workflows/.github/workflows/ci-gate-tamper-guard.yml@%s"}}\n' "$SHA_A" > "$C/.github/workflows/ci-gate-tamper-guard-flow.yml"
printf 'name: notes\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps: [{run: "true"}]\n' > "$C/.github/workflows/ci-gate-tamper-guard-notes.yml"
yq -i -I4 '.workflows[".github/workflows/ci-gate-tamper-guard-notes.yml"] = ["actions/checkout@v7.0.1"]' "$L"
check; expect "flow-style guard caller is detected" 1 "DRIFT guard-caller-leftover"
case "$OUT" in *"lock-extra-entry"*) bad "kept record for a non-caller flagged as retired -- $OUT" ;; *) ok "record of the non-caller file is not flagged" ;; esac
render; expect "render" 0 "removed retired guard caller: .github/workflows/ci-gate-tamper-guard-flow.yml"
[ ! -e "$C/.github/workflows/ci-gate-tamper-guard-flow.yml" ] && ok "flow-style guard file removed" || bad "flow-style guard file survived"
[ "$(yq -o=json -I0 '.workflows[".github/workflows/ci-gate-tamper-guard-notes.yml"]' "$L")" = '["actions/checkout@v7.0.1"]' ] \
  && ok "the non-caller's lock record is preserved" || bad "non-caller lock record was removed"
check; expect "check after" 0 "clean"

echo "== refusals (nothing is written) =="
mk; T0=$(tree); R=hyperpolymath/no-such-repo render; expect "no profile at the SHA" 1 "missing or invalid"
[ "$T0" = "$(tree)" ] && ok "missing profile: tree untouched" || bad "missing profile wrote files"
mk; R=hyperpolymath/bad-profile SHA=$SHA_C render; expect "invalid profile" 1 "missing or invalid"
mk; R=$REPO SHA=$SHA_A render; R=hyperpolymath/bad-profile SHA=$SHA_A render; expect "profile absent AT that SHA though present later" 1 "missing or invalid"
mk; SHA=$SHA_NOTPL R=$REPO render; expect "no template at that SHA" 1
for s in main HEAD "${SHA_A:0:12}" "${SHA_A^^}" "${SHA_A}0" " "; do
  mk; SHA=$s render; expect "bad SHA '${s:0:14}'" 1 "40-hex"
  [ -z "$(tree)" ] && ok "bad SHA '${s:0:14}': nothing written" || bad "bad SHA wrote files"
done
mk; SHA=$(printf 'a%.0s' {1..40}) render; expect "well-formed SHA that is not in the suite" 1 "not found"
mk; R='../etc/passwd' render; expect "malformed --repo" 2 "OWNER/NAME"
mk; run render --suite "$WORK/nope" --suite-sha "$SHA_A" --repo "$REPO" --checkout "$C"; expect "missing suite dir" 2
mk; cp "$ROOT/tests/fixtures/actions-lock/v0.0.2.lock" "$C/.github/workflows/actions.lock"; sed -i "s/^version: .*/version: 'v9.9.9'/" "$C/.github/workflows/actions.lock"
T0=$(tree); render; expect "untested lock schema" 3 "untested"
[ "$T0" = "$(tree)" ] && ok "untested lock schema: checkout untouched (no caller written)" || bad "untested lock schema still wrote files"
mk; run bogus; expect "bad mode" 2

echo "== the consumer's own lock checker =="
stub() { mkdir -p "$C/scripts"; printf '%s\n' "$1" > "$C/scripts/check-lock-sync.sh"; }
mk; stub 'echo "refs missing from the lockfile"; exit 7'
render; expect "failing consumer checker" 1 "REFUSED consumer-lock-checker"
case "$OUT" in *"refs missing from the lockfile"*) ok "failing checker: its output is shown" ;; *) bad "checker output hidden -- $OUT" ;; esac
[ -f "$C/.github/workflows/ci-gate.yml" ] && ok "failing checker: written files are left in place" || bad "files rolled back"
mk; stub 'echo fine; exit 0'
render; expect "passing consumer checker" 0 "consumer lock checker scripts/check-lock-sync.sh passed"
mk; stub 'echo "cwd=$(pwd)" > ran.txt; exit 0'; render >/dev/null
[ "$(cat "$C/ran.txt" 2>/dev/null)" = "cwd=$C" ] && ok "checker runs from the checkout root" || bad "checker not run from the checkout"
mk; stub 'echo "refs missing"; exit 1'
run render --suite "$SUITE" --suite-sha "$SHA_A" --repo "$REPO" --checkout "$C" --skip-consumer-checker
expect "failing checker with --skip-consumer-checker" 0 "SKIPPED consumer lock checker"
mk; render; expect "no consumer checker present" 0 "wrote"
case "$OUT" in *"consumer lock checker"*) bad "mentions a checker that is absent" ;; *) ok "absent checker: nothing reported" ;; esac
mk; stub 'exit 0'; SHA=zzz render; expect "refusal before write still wins; checker not reached" 1 "40-hex"

echo "== check on a clean tree, then each drift kind =="
clean() { mk; cp "$ROOT/tests/fixtures/actions-lock/v0.0.2.lock" "$C/.github/workflows/actions.lock"; render >/dev/null; F="$C/.github/workflows/ci-gate.yml"; L="$C/.github/workflows/actions.lock"; }
clean; T0=$(tree); check --repo "$REPO"; expect "clean tree with lock" 0 "clean"
[ "$T0" = "$(tree)" ] && ok "check writes nothing" || bad "check modified the tree"
drift() { # <label> <kind> -- the mutation has already been applied to $C
  T0=$(tree); check --repo "$REPO"; expect "$1" 1 "DRIFT $2"
  [ "$T0" = "$(tree)" ] && ok "$1: check wrote nothing" || bad "$1: check wrote files"
  render >/dev/null 2>&1; check --repo "$REPO"; expect "$1: clean after render" 0 "clean"
}
clean; echo '# local edit' >> "$F";                                  drift "caller edited by hand" caller-differs
clean; sed -i "s/@$SHA_A/@main/g" "$F";                              drift "pin is a branch name" pin-not-40hex
clean; sed -i "s/@$SHA_A/@${SHA_A:0:12}/g" "$F";                     drift "pin is abbreviated" pin-not-40hex
clean; sed -i "s/@$SHA_A/@${SHA_A^^}/g" "$F";                        drift "pin is upper-case" pin-not-40hex
clean; sed -i "0,/@$SHA_A/s//@$SHA_B/" "$F";                         drift "the two calls pin different SHAs" pin-inconsistent
clean; sed -i "s/@$SHA_A/@$(printf 'b%.0s' {1..40})/g" "$F";         drift "pin is not in the suite" pin-unknown-to-suite
clean; sed -i '/uses: hyperpolymath/d' "$F";                         drift "no suite pin at all" pin-missing
clean; rm "$F";                                                      drift "caller deleted" caller-missing
clean; yq -i -I4 'del(.workflows[".github/workflows/ci-gate.yml"])' "$L"; drift "lock entry absent" lock-entry-missing
clean; yq -i -I4 '.workflows[".github/workflows/ci-gate.yml"] = ["actions/checkout@v7.0.1"]' "$L"; drift "lock leaf record" lock-entry-not-empty
clean; yq -i -I4 '.workflows[".github/workflows/ci-gate-tamper-guard-caller.yml"] = []' "$L"; drift "lock lists retired guard" lock-extra-entry
clean; printf '%s' "$GUARD_BODY" > "$C/.github/workflows/ci-gate-tamper-guard-caller.yml"; drift "guard caller still present" guard-caller-leftover
clean; T0=$(tree); run check --suite "$SUITE" --checkout "$C" --repo hyperpolymath/no-such-repo; expect "check names a repo with no profile" 1 "DRIFT profile-missing"
mk; check; expect "check on an empty checkout" 1 "DRIFT caller-missing"
clean; rm "$L"; check; expect "no actions.lock: lock checks reported not run" 0 "lock checks not run"

echo "== an unparseable guard-named workflow is an error, never 'clean' =="
clean_c() { clean; printf 'jobs: [unclosed\n' > "$C/.github/workflows/ci-gate-tamper-guard-bad.yml"; }
clean_c; T0=$(tree); check; expect "check with a malformed guard-named file" 2 "cannot inspect workflows"
case "$OUT" in *clean:*) bad "reported clean over an uninspected file" ;; *) ok "never reports clean" ;; esac
[ "$T0" = "$(tree)" ] && ok "check wrote nothing" || bad "check wrote files"
clean_c; T0=$(tree); render; expect "render with a malformed guard-named file" 2 "cannot inspect workflows"
[ "$T0" = "$(tree)" ] && ok "render refused before writing anything" || bad "render wrote files before failing"
clean; yq -i -I4 '.workflows[".github/workflows/ci-gate-tamper-guard-gone.yml"] = []' "$L"
printf 'jobs: [unclosed\n' > "$C/.github/workflows/ci-gate-tamper-guard-gone.yml"
check; expect "check with a malformed file that has a lock record" 2 "cannot inspect workflows"
clean; cmp -s "$C/.github/workflows/ci-gate.yml" <(git -C "$SUITE" show "$SHA_A:templates/ci-gate-caller.yml" | sed "s/__CICD_SUITE_SHA__/$SHA_A/g") && ok "fixture has a valid caller and lock (so clean would be reachable)"
printf 'version: [unclosed\nworkflows: {\n' > "$L"; T0=$(tree)
check; expect "check with a malformed actions.lock" 3 "unreadable"
case "$OUT" in *clean:*) bad "reported clean over an unreadable lock" ;; *) ok "malformed lock: never clean" ;; esac
render; expect "render with a malformed actions.lock" 3 "unreadable"
[ "$T0" = "$(tree)" ] && ok "malformed lock: nothing written" || bad "malformed lock: files written"
clean; printf 'version: %s\nworkflows: [1, 2]\n' "'v0.0.2'" > "$L"
check; expect "check with a lock whose workflows is not a map" 3 "no workflows map"

echo
echo "ci-gate-caller: $PASS passed, $FAIL failed (jq $(jq --version))"
[ "$FAIL" -eq 0 ]
