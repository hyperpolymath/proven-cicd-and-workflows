#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Controls for the stamped consumer gate (templates/proven-lock-gate.yml and
# scripts/proven-lock-gate.sh). Each design condition has a control:
#   stamp     body edit = drift; local-region edit = still matches; no stamp = NOT RUN
#   lint      NOT RUN must fail the job: no `if:` and no continue-on-error anywhere,
#             read-only token, explicit job names, a timeout
#   gate      consistent -> 0; lock defect -> 1; drifted copy -> 1 (drift)
#   selftest  a suite whose shipped C always says CONSISTENT -> 2 (not_run:selftest)
#   pin       a malformed pinned SHA -> 2 (not_run:pin), before any fetch
#   classes   identity, fetch-missing (no retry), fetch (transient), checkout,
#             suite and runtime each fail the job with their own class
# PROVEN_IDRIS2_SOURCE_DIR: Idris2 checkout for the RefC runtime (else fetched).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v yq >/dev/null && yq --version | grep -q mikefarah || { echo "proven-lock-gate: mikefarah yq missing; NOT RUN" >&2; exit 2; }
command -v gcc >/dev/null || { echo "proven-lock-gate: gcc missing; NOT RUN" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
template=$root/templates/proven-lock-gate.yml
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL $*"; fail=1; }
expect_rc() { # NAME WANT CMD...
  local name=$1 want=$2 rc=0; shift 2
  "$@" >"$tmp/out" 2>&1 || rc=$?
  if [[ $rc == "$want" ]]; then ok "$name"; else bad "$name: wanted exit $want, got $rc"; sed 's/^/    /' "$tmp/out"; fi
}

# --- stamp
expect_rc 'the template matches its stamp' 0 bash "$root/scripts/proven-stamp.sh" check "$template"
sed 's/timeout-minutes: 15/timeout-minutes: 90/' "$template" > "$tmp/edited.yml"
expect_rc 'a body edit is drift' 1 bash "$root/scripts/proven-stamp.sh" check "$tmp/edited.yml"
sed -e 's/PROVEN_SHA: "0\{40\}"/PROVEN_SHA: "1111111111111111111111111111111111111111"/' \
    -e 's/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1/checkout@2222222222222222222222222222222222222222 # v7.1.0/' \
    "$template" > "$tmp/local.yml"
grep -q 1111111111 "$tmp/local.yml" && grep -q 2222222222 "$tmp/local.yml" || bad 'local-region control did not apply its edits'
expect_rc 'a local-region edit (suite pin, Dependabot bump) still matches' 0 bash "$root/scripts/proven-stamp.sh" check "$tmp/local.yml"
sed '2d' "$template" > "$tmp/nostamp.yml"
expect_rc 'a copy without a stamp is NOT RUN' 2 bash "$root/scripts/proven-stamp.sh" check "$tmp/nostamp.yml"

# --- stamp layout: SPDX on line 1, stamp on line 2; legacy line-1 stamp still checks
st=$root/scripts/proven-stamp.sh
[[ $(sed -n 1p "$template") == '# SPDX-License-Identifier: '* ]] && ok 'template line 1 is the SPDX line' || bad 'template line 1 is not SPDX'
[[ $(sed -n 2p "$template") == '# proven-cicd: '* ]] && ok 'template line 2 is the stamp' || bad 'template line 2 is not the stamp'
# a fresh stamp from a placeholder stamp, then check
{ sed -n 1p "$template"; echo "# proven-cicd: demo@1.0.0 sha256:$(printf '0%.0s' {1..64})"; tail -n +3 "$template"; } > "$tmp/new.yml"
expect_rc 'a placeholder stamp is drift before stamping' 1 bash "$st" check "$tmp/new.yml"
expect_rc 'stamp writes the new layout' 0 bash "$st" stamp "$tmp/new.yml"
expect_rc 'a freshly stamped copy checks ok' 0 bash "$st" check "$tmp/new.yml"
[[ $(sed -n 1p "$tmp/new.yml") == '# SPDX-License-Identifier: '* && $(sed -n 2p "$tmp/new.yml") == '# proven-cicd: demo@1.0.0 sha256:'* ]] &&
  ok 'stamped copy keeps SPDX on line 1 and the stamp on line 2' || bad 'stamped layout wrong'
sed 's/timeout-minutes: 15/timeout-minutes: 90/' "$tmp/new.yml" > "$tmp/new-edited.yml"
expect_rc 'a body edit is drift (new layout)' 1 bash "$st" check "$tmp/new-edited.yml"
sed '1s/MPL-2.0/Apache-2.0/' "$tmp/new.yml" > "$tmp/new-spdx.yml"
expect_rc 'an SPDX line edit is drift (SPDX is hashed)' 1 bash "$st" check "$tmp/new-spdx.yml"
# legacy layout: stamp on line 1, no SPDX line above it
{ echo "# proven-cicd: demo@1.0.0 sha256:$(printf '0%.0s' {1..64})"; tail -n +1 "$tmp/new.yml" | tail -n +3 | sed '1i # SPDX-License-Identifier: MPL-2.0'; } > "$tmp/legacy.yml"
h=$(bash "$st" hash "$tmp/legacy.yml")
sed -i "1s/sha256:.*/sha256:$h/" "$tmp/legacy.yml"
expect_rc 'a legacy line-1 copy still checks ok' 0 bash "$st" check "$tmp/legacy.yml"
grep -q 'LEGACY layout' "$tmp/out" && ok 'a legacy copy is named as legacy' || bad 'no legacy note'
sed 's/timeout-minutes: 15/timeout-minutes: 90/' "$tmp/legacy.yml" > "$tmp/legacy-edited.yml"
expect_rc 'a body edit is drift (legacy layout)' 1 bash "$st" check "$tmp/legacy-edited.yml"
expect_rc 'stamp refuses a legacy copy (never writes the legacy layout)' 2 bash "$st" stamp "$tmp/legacy.yml"
# a template without SPDX on line 1 is refused by stamp
{ echo '# not spdx'; sed -n 2p "$tmp/new.yml"; tail -n +3 "$tmp/new.yml"; } > "$tmp/nospdx.yml"
expect_rc 'stamp refuses a template without SPDX on line 1' 2 bash "$st" stamp "$tmp/nospdx.yml"
expect_rc 'check refuses a stamp under a non-SPDX line 1' 2 bash "$st" check "$tmp/nospdx.yml"
# the stamp on any other line fails
{ sed -n 1p "$tmp/new.yml"; echo '# filler'; sed -n 2p "$tmp/new.yml"; tail -n +3 "$tmp/new.yml"; } > "$tmp/line3.yml"
expect_rc 'a stamp on line 3 fails' 2 bash "$st" check "$tmp/line3.yml"
{ tail -n +3 "$tmp/new.yml"; sed -n 2p "$tmp/new.yml"; } > "$tmp/last.yml"
expect_rc 'a stamp on the last line fails' 2 bash "$st" check "$tmp/last.yml"
{ sed -n 2p "$tmp/new.yml"; sed -n 1p "$tmp/new.yml"; tail -n +3 "$tmp/new.yml"; } > "$tmp/swapped.yml"
h=$(bash "$st" hash "$tmp/swapped.yml"); sed -i "1s/sha256:.*/sha256:$h/" "$tmp/swapped.yml"
expect_rc 'stamp-then-SPDX (old order) is read as legacy, never as the new layout' 0 bash "$st" check "$tmp/swapped.yml"

# --- lint: NOT RUN must fail the job
ifs=$(yq '[.. | select(has("if"))] | length' "$template")
coe=$(yq '[.. | select(has("continue-on-error"))] | length' "$template")
[[ $ifs == 0 ]] && ok 'no if: anywhere (a skipped job would satisfy a required check)' || bad "if: found $ifs times"
[[ $coe == 0 ]] && ok 'no continue-on-error anywhere' || bad "continue-on-error found $coe times"
[[ $(yq -o json -I 0 '.permissions' "$template") == '{"contents":"read"}' ]] && ok 'token is read-only' || bad 'permissions are not exactly contents: read'
[[ $(yq '[.jobs[] | select(has("name") | not)] | length' "$template") == 0 ]] && ok 'every job has an explicit name (stable required context)' || bad 'a job has no explicit name'
[[ $(yq '[.jobs[] | select(has("timeout-minutes") | not)] | length' "$template") == 0 ]] && ok 'every job has a timeout' || bad 'a job has no timeout'

# --- pin refusal, from the template's own run script
yq '.jobs.proven-lock.steps[1].run' "$template" > "$tmp/run.sh"
rc=0; out=$(env -i PATH="$PATH" PROVEN_SHA=not-a-sha RUNNER_TEMP="$tmp/rt" bash "$tmp/run.sh" 2>&1) || rc=$?
[[ $rc == 2 && $out == *PROVEN_LOCK_CLASS=not_run:pin* ]] && ok 'a malformed pin is NOT RUN before any fetch' || bad "malformed pin: exit $rc, output: $out"

# --- every pre-verdict failure has its own class (advisor review, 0.2.0).
# The template's run script runs against a local suite remote: git rewrites the
# github.com URL to it, curl and sleep are stubs, and a git wrapper can fail the
# checkout. Nothing here touches the network.
stubs=$tmp/stubs; mkdir -p "$stubs"
printf '#!/usr/bin/env bash\n[[ -n ${STUB_CURL_FAIL:-} ]] && exit 22\nprintf '"'"'{"id": %%s, "full_name": "hyperpolymath/proven-cicd-and-workflows"}\\n'"'"' "${STUB_ID:-1326697643}"\n' > "$stubs/curl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stubs/sleep"
realgit=$(command -v git)
printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ $a == checkout && -n ${STUB_CHECKOUT_FAIL:-} ]] && exit 128; done\nexec %q "$@"\n' "$realgit" > "$stubs/git"
chmod +x "$stubs"/*
fake_suite() { # DIR [OMIT_FILE] -> commit SHA on stdout
  local d=$1 omit=${2:-} f
  rm -rf -- "$d"; mkdir -p "$d"
  for f in scripts/proven-lock-gate.sh scripts/proven-stamp.sh scripts/build-proven-lock.sh \
           scripts/extract-lock-facts.sh dist/proven-lock/proven-lock-verdict.c; do
    [[ $f == "$omit" ]] && continue
    mkdir -p "$d/$(dirname "$f")"; echo '# fake' > "$d/$f"
  done
  printf '#!/usr/bin/env bash\necho "PROVEN_LOCK_CLASS=consistent"\n' > "$d/scripts/proven-lock-gate.sh"
  git -C "$d" init -q && git -C "$d" add -A
  git -C "$d" -c user.name=c -c user.email=c@invalid -c commit.gpgsign=false commit -qm suite
  git -C "$d" rev-parse HEAD
}
remote_from() { # SUITE_DIR -> bare remote at $tmp/remote/proven-cicd-and-workflows.git
  rm -rf -- "$tmp/remote"; mkdir -p "$tmp/remote"
  git clone -q --bare "$1" "$tmp/remote/proven-cicd-and-workflows.git"
  git -C "$tmp/remote/proven-cicd-and-workflows.git" config uploadpack.allowAnySHA1InWant true
}
printf '[url "file://%s/remote/"]\n\tinsteadOf = https://github.com/hyperpolymath/\n' "$tmp" > "$tmp/gitconfig"
run_gate_script() { # WANT_RC WANT_CLASS NAME SHA [ENV...]
  local want=$1 class=$2 name=$3 sha=$4 rc=0; shift 4
  rm -rf -- "$tmp/rt"; mkdir -p "$tmp/rt"
  env -i PATH="$stubs:$PATH" HOME="$tmp" GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    PROVEN_SHA="$sha" RUNNER_TEMP="$tmp/rt" GH_TOKEN=dummy GITHUB_WORKSPACE="$tmp/ws" "$@" \
    bash "$tmp/run.sh" >"$tmp/out" 2>&1 || rc=$?
  if [[ $rc == "$want" ]] && grep -qx "PROVEN_LOCK_CLASS=$class" "$tmp/out"; then ok "$name"
  else bad "$name: wanted $want/$class, got $rc"; sed 's/^/    /' "$tmp/out" | tail -8; fi
}
good=$(fake_suite "$tmp/fake-good"); remote_from "$tmp/fake-good"
run_gate_script 0 consistent 'a verified suite at the pinned commit runs the gate' "$good"
run_gate_script 2 not_run:identity 'a suite repository with another id is refused' "$good" STUB_ID=42
run_gate_script 2 not_run:identity 'an unreadable repository id is refused' "$good" STUB_CURL_FAIL=1
run_gate_script 2 not_run:fetch-missing 'a pinned commit the suite lacks is fetch-missing, not a transient fetch' 1111111111111111111111111111111111111111
run_gate_script 2 not_run:checkout 'a failed checkout has its own class' "$good" STUB_CHECKOUT_FAIL=1
partial=$(fake_suite "$tmp/fake-partial" dist/proven-lock/proven-lock-verdict.c); remote_from "$tmp/fake-partial"
run_gate_script 2 not_run:suite 'a suite lacking a file the gate runs is refused' "$partial"
rm -rf -- "$tmp/remote"
run_gate_script 2 not_run:fetch 'an unreachable suite after retries is a transient fetch failure' "$good"

# --- gate end to end, with this checkout as the suite
workspace() { # FIXTURE -> $tmp/ws with the stamped gate installed
  local fixture=$1
  rm -rf -- "$tmp/ws"; cp -R "$root/tests/fixtures/proven-lock/$fixture/repo" "$tmp/ws"
  mv "$tmp/ws/dot-github" "$tmp/ws/.github"
  cp "$template" "$tmp/ws/.github/workflows/proven-lock-gate.yml"
}
gate() { # WANT_RC WANT_CLASS NAME [SUITE]
  local want=$1 class=$2 name=$3 suite=${4:-$root} rc=0
  bash "$suite/scripts/proven-lock-gate.sh" "$tmp/ws" .github/workflows/proven-lock-gate.yml >"$tmp/out" 2>&1 || rc=$?
  if [[ $rc == "$want" ]] && tail -n 1 "$tmp/out" | grep -qx "PROVEN_LOCK_CLASS=$class"; then ok "$name"
  else bad "$name: wanted $want/$class, got $rc/$(tail -n 1 "$tmp/out")"; sed 's/^/    /' "$tmp/out" | tail -15; fi
}
workspace ok-tag-keyed;  gate 0 consistent 'a consistent lock passes the gate'
workspace self-sha-leaf; gate 1 defect 'a self-SHA leaf fails the gate as a defect'
workspace ok-tag-keyed;  sed -i 's/timeout-minutes: 15/timeout-minutes: 90/' "$tmp/ws/.github/workflows/proven-lock-gate.yml"
gate 1 drift 'an edited stamped copy fails as drift, before any build'

# --- self-test: a suite whose shipped C always answers CONSISTENT is refused
mkdir -p "$tmp/suite"
git -C "$root" archive HEAD dist scripts tests/fixtures/proven-lock | tar -x -C "$tmp/suite"
cp "$root/scripts/"*.sh "$tmp/suite/scripts/"
printf '#include <stdio.h>\nvoid *global_IORef_Storage;\nint main(void){puts("CONSISTENT");return 0;}\n' > "$tmp/suite/dist/proven-lock/proven-lock-verdict.c"
git -C "$tmp/suite" init -q && git -C "$tmp/suite" add -A && git -C "$tmp/suite" -c user.name=c -c user.email=c@invalid -c commit.gpgsign=false commit -qm counterfeit
workspace ok-tag-keyed
gate 2 not_run:selftest 'a counterfeit always-CONSISTENT binary is refused by the self-test' "$tmp/suite"


# --- runtime: an unreachable Idris2 runtime host is not_run:runtime, never a
# build failure (advisor review). The fetch is redirected to a path that does
# not exist; sleep is stubbed so the retries are instant.
printf '[url "file://%s/no-such-host/"]\n\tinsteadOf = https://github.com/idris-lang/\n' "$tmp" > "$tmp/gitconfig-rt"
workspace ok-tag-keyed
rc=0
env -u PROVEN_IDRIS2_SOURCE_DIR PATH="$stubs:$PATH" GIT_CONFIG_GLOBAL="$tmp/gitconfig-rt" GIT_CONFIG_NOSYSTEM=1 \
  bash "$root/scripts/proven-lock-gate.sh" "$tmp/ws" .github/workflows/proven-lock-gate.yml >"$tmp/out" 2>&1 || rc=$?
if [[ $rc == 2 ]] && tail -n 1 "$tmp/out" | grep -qx PROVEN_LOCK_CLASS=not_run:runtime; then ok 'an unreachable runtime host is not_run:runtime, not a build failure'
else bad "runtime: wanted 2/not_run:runtime, got $rc/$(tail -n 1 "$tmp/out")"; sed 's/^/    /' "$tmp/out" | tail -8; fi

exit "$fail"
