#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the Lean axiom gate must fail for each thing it claims to check,
# under the exact composite shell. This test runs the REAL pinned Lean 4.15.0
# (the gate refuses any other binary, so a stand-in is not possible); a missing
# or wrong Lean is exit 2, never a skip. Put the pinned bin/lean on PATH or set
# LEAN_BIN. A clean fixture must pass, then one defect at a time, each of which
# the gate must fail: a sorry, Classical.choice, a declared axiom, a required
# theorem that is not printed, a file that does not compile, a file with no
# #print axioms, fewer reports than prints, a missing listed file, a wrong
# binary. Then mutants of check.sh itself: each planted control, made vacuous,
# must make the gate refuse (exit 2) rather than report green.
#
# Ported from the Lean controls of hvn-dehallucinator's
# tests/proofs/recheck_legs_test.sh.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$here/check.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

LEAN_BIN="${LEAN_BIN:-$(command -v lean || true)}"
[ -n "$LEAN_BIN" ] && [ -x "$LEAN_BIN" ] || { echo "lean-axioms-check/test.sh: lean is not installed — NO CHECK WAS PERFORMED." >&2; exit 2; }
export LEAN_BIN
BASH_BIN="$(command -v bash)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
FIX="$WORK/fixture"

names=(sound_one sound_two haruspex)
# lean <file> [skip-name] [extra]: a theorem and its #print axioms per name.
lean_fixture() {
  { echo 'namespace Fixture'
    for n in "${names[@]}"; do
      [ "$n" = "${2:-}" ] && continue
      printf 'theorem %s : True := trivial\n' "$n"
    done
    printf '%s\n' "${3:-}"
    echo 'end Fixture'
    for n in "${names[@]}"; do
      [ "$n" = "${2:-}" ] && continue
      printf '#print axioms Fixture.%s\n' "$n"
    done; } > "$1"
}
fresh_fixture() { rm -rf "$FIX"; mkdir -p "$FIX/proofs"; lean_fixture "$FIX/proofs/Ok.lean"; }
run_phase() { # run_phase <phase> [VAR=value ...]
  local phase="$1"; shift
  ( cd "$FIX" && env LEAN_GATE_PHASE="$phase" FILES=proofs/Ok.lean "$@" "$BASH_BIN" --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1
  RC=$?
}
expect() { # expect <name> <want-rc> <text>
  if [ "$RC" -eq "$2" ] && grep -qF -- "$3" "$OUT"; then ok "$1 (exit $RC)"; else bad "$1: want exit $2 and \"$3\", got exit $RC"; sed 's/^/        /' "$OUT" | tail -n 15; fi
}

echo "== positive control: a clean tree passes =="
fresh_fixture
run_phase detect
expect "detect on a clean tree" 0 'units=1'
run_phase prove REQUIRED_THEOREMS="sound_one sound_two haruspex"
expect "prove on a clean tree" 0 '3 required theorem(s) reported'
grep -q 'axiom-free theorem accepted' "$OUT" && ok "the true planted control was exercised" || bad "no true control"
for c in Sorry Classical Axiom IllTyped Unprinted; do
  grep -q "$c refused" "$OUT" && ok "the $c planted control was exercised" || bad "the $c control was not run"
done
grep -q 'PASS (3 axiom-free)' "$OUT" && ok "the axiom-free count is reported" || bad "count not reported"

echo "== negative controls (each must fail the gate) =="
fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" sound_one 'theorem sound_one : False := sorry'
echo '#print axioms Fixture.sound_one' >> "$FIX/proofs/Ok.lean"
run_phase prove
expect "a theorem left as sorry" 1 'contains a sorry'

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" sound_two 'theorem sound_two (p : Prop) : p ∨ ¬p := Classical.em p'
echo '#print axioms Fixture.sound_two' >> "$FIX/proofs/Ok.lean"
run_phase prove
expect "a theorem using Classical.choice" 1 'rests on an axiom'
grep -q 'Classical.choice' "$OUT" && ok "the axiom is named" || bad "axiom not named"

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" sound_two 'axiom cheat : False
theorem sound_two : False := cheat'
echo '#print axioms Fixture.sound_two' >> "$FIX/proofs/Ok.lean"
run_phase prove
expect "a theorem resting on a declared axiom" 1 'rests on an axiom'

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" haruspex
run_phase prove REQUIRED_THEOREMS="sound_one haruspex"
expect "a required theorem that is not printed" 1 "no axiom report for required theorem 'haruspex'"

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" "" 'theorem broken : False := trivial'
run_phase prove
expect "a file that does not compile" 1 'lean failed'

fresh_fixture
printf 'theorem lonely : True := trivial\n' > "$FIX/proofs/Ok.lean"
run_phase prove
expect "a file with no #print axioms" 1 'no #print axioms'

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" "" '-- #print axioms Fixture.sound_one'
run_phase prove
expect "more prints than reports" 1 'reports in proofs/Ok.lean are axiom-free'

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" "" 'theorem sec : True := trivial'
echo '#print axioms Fixture.sec' >> "$FIX/proofs/Ok.lean"
run_phase prove REQUIRED_THEOREMS="sec"
expect "a required name that is printed" 0 '1 required theorem(s) reported'
run_phase prove REQUIRED_THEOREMS="ec"
expect "a required name must match whole identifiers" 1 "required theorem 'ec'"

fresh_fixture
run_phase prove FILES="proofs/Ok.lean proofs/Ghost.lean"
expect "a listed file that does not exist" 1 'does not exist'
run_phase detect FILES="proofs/Ok.lean proofs/Ghost.lean"
expect "detect: a listed file that does not exist" 1 'missing: proofs/Ghost.lean'
run_phase detect FILES=
expect "detect: standalone .lean files and an empty list" 1 'names none'
run_phase prove REQUIRED_THEOREMS='bad name;'
expect "a required name that is not an identifier is exit 2" 2 'not a plain identifier'

echo "== Lake projects belong to proof-runner-check, not to this gate =="
fresh_fixture
mkdir -p "$FIX/proj/sub"
printf 'import Lake\nopen Lake DSL\npackage proj\n' > "$FIX/proj/lakefile.lean"
printf 'theorem t : True := trivial\n' > "$FIX/proj/sub/T.lean"
rm -f "$FIX/proofs/Ok.lean"; rmdir "$FIX/proofs"
run_phase detect FILES=
expect "detect ignores .lean files inside a Lake project" 0 'units=0'
printf '[package]\nname = "proj"\n' > "$FIX/proj/lakefile.toml"; rm -f "$FIX/proj/lakefile.lean"
run_phase detect FILES=
expect "detect ignores them under a lakefile.toml too" 0 'lean_files=0'
printf 'theorem s : True := trivial\n' > "$FIX/Standalone.lean"
run_phase detect FILES=
expect "detect sees a standalone file beside a Lake project" 1 'lean_files=1'

echo "== toolchain pin =="
fresh_fixture
mkdir -p "$WORK/fake"
printf '#!/usr/bin/env bash\necho "Lean (version 4.15.0, x86_64-unknown-linux-gnu, commit 0, Release)"\n' > "$WORK/fake/lean"; chmod +x "$WORK/fake/lean"
run_phase prove LEAN_BIN="$WORK/fake/lean"
expect "a binary that is not the pinned build is exit 2" 2 'pinned eacf754d25ae86ea076882a34b9444f2485659d9df4266b821443b28ca95a215'
run_phase prove LEAN_BIN="$WORK/fake/absent"
expect "an absent binary is exit 2" 2 'not found'
rm -rf "$FIX/proofs"
run_phase detect
expect "detect on a tree with no .lean file is silent" 0 'units=0'
run_phase prove FILES=
expect "prove with nothing listed is exit 2, not green" 2 'NO CHECK WAS PERFORMED'

echo "== mutants of check.sh: a vacuous planted control must be refused =="
fresh_fixture
mutant() { # mutant <label> <old-text> <new-text> <want-text>: literal replace
  local content; content="$(cat "$checker")"
  printf '%s\n' "${content/"$2"/"$3"}" > "$WORK/mutant.sh"
  if cmp -s "$checker" "$WORK/mutant.sh"; then bad "$1: the mutation did not apply"; return; fi
  ( cd "$FIX" && env LEAN_GATE_PHASE=prove FILES=proofs/Ok.lean "$BASH_BIN" --noprofile --norc -e -o pipefail "$WORK/mutant.sh" ) > "$OUT" 2>&1
  RC=$?
  expect "$1" 2 "$4"
}
mutant "a sorry control that is in fact proved" 'planted_sorry : False := sorry' 'planted_sorry : True := trivial' 'planted Sorry control was ACCEPTED'
mutant "a Classical control that is in fact constructive" 'planted_classical (p : Prop) : p ∨ ¬p := Classical.em p' 'planted_classical : True := trivial' 'planted Classical control was ACCEPTED'
mutant "an axiom control that is in fact proved" 'axiom planted_cheat : False\ntheorem planted_axiom : False := planted_cheat' 'theorem planted_axiom : True := trivial' 'planted Axiom control was ACCEPTED'
mutant "an ill-typed control that is well typed" 'planted_ill_typed : False := trivial' 'planted_ill_typed : True := trivial' 'planted IllTyped control was ACCEPTED'
mutant "an unprinted control that is printed" 'theorem planted_unprinted : True := trivial\n'"'"' > "$ctl/Unprinted.lean"' 'theorem planted_unprinted : True := trivial\n#print axioms planted_unprinted\n'"'"' > "$ctl/Unprinted.lean"' 'planted Unprinted control was ACCEPTED'
mutant "a true control that is in fact false" 'theorem planted_true : True := trivial' 'theorem planted_true : False := sorry' 'planted AXIOM-FREE theorem was refused'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
