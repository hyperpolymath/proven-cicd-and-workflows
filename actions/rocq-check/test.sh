#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the Rocq gate must fail for each thing it claims to check, under the
# exact composite shell. This test runs the REAL pinned coqc (the gate refuses
# any other binary, so a stand-in is not possible); a missing or wrong coqc is
# exit 2, never a skip. A clean fixture must pass, then one defect at a time,
# each of which the gate must fail: a theorem resting on an Axiom, an Admitted
# one, a required theorem that is not printed, a file that does not compile, a
# file with no Print Assumptions, fewer reports than prints, a missing listed
# file, a wrong binary. Then mutants of check.sh itself: each planted control,
# made vacuous, must make the gate refuse (exit 2) rather than report green.
#
# Ported from the Rocq controls of hvn-dehallucinator's
# tests/proofs/recheck_legs_test.sh.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$here/check.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v coqc >/dev/null 2>&1 || { echo "rocq-check/test.sh: coqc is not installed — NO CHECK WAS PERFORMED." >&2; exit 2; }
BASH_BIN="$(command -v bash)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
FIX="$WORK/fixture"

names=(sound_one sound_two haruspex)
# rocq <file> [skip-name] [extra]: a Lemma and its Print Assumptions per name.
rocq_fixture() {
  { for n in "${names[@]}"; do
      [ "$n" = "${2:-}" ] && continue
      printf 'Lemma %s : True. Proof. exact I. Qed.\nPrint Assumptions %s.\n' "$n" "$n"
    done; printf '%s\n' "${3:-}"; } > "$1"
}
fresh_fixture() { rm -rf "$FIX"; mkdir -p "$FIX/proofs"; rocq_fixture "$FIX/proofs/Ok.v"; }
run_phase() { # run_phase <phase> [VAR=value ...]
  local phase="$1"; shift
  ( cd "$FIX" && env ROCQ_GATE_PHASE="$phase" FILES=proofs/Ok.v "$@" "$BASH_BIN" --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1
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
grep -q 'closed theorem accepted' "$OUT" && ok "the true planted control was exercised" || bad "no true control"
grep -q 'Axiom refused' "$OUT" && grep -q 'Admitted refused' "$OUT" && grep -q 'IllTyped refused' "$OUT" && grep -q 'Unprinted refused' "$OUT" \
  && ok "every false planted control was exercised" || bad "a false control was not run"
grep -q 'PASS (3 closed)' "$OUT" && ok "the closed count is reported" || bad "closed count not reported"

echo "== negative controls (each must fail the gate) =="
fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" sound_one \
  'Axiom cheat : False. Lemma sound_one : False. Proof. exact cheat. Qed. Print Assumptions sound_one.'
run_phase prove
expect "a theorem resting on an Axiom" 1 'rests on an assumption'

fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" sound_two 'Lemma sound_two : False. Proof. Admitted. Print Assumptions sound_two.'
run_phase prove
expect "an Admitted theorem" 1 'rests on an assumption'

fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" haruspex
run_phase prove REQUIRED_THEOREMS="sound_one haruspex"
expect "a required theorem that is not printed" 1 "no assumption report for required theorem 'haruspex'"

fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" "" 'Lemma broken : False. Proof. exact I. Qed.'
run_phase prove
expect "a file that does not compile" 1 'coqc failed'

fresh_fixture
printf 'Lemma lonely : True. Proof. exact I. Qed.\n' > "$FIX/proofs/Ok.v"
run_phase prove
expect "a file with no Print Assumptions" 1 'no Print Assumptions'

fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" "" '(* Print Assumptions sound_one. *)'
run_phase prove
expect "more prints than reports" 1 'reports in proofs/Ok.v are closed'

fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" "" 'Section S. Variable P : Prop. Lemma sec : P -> P. Proof. intro h; exact h. Qed. Print Assumptions sec. End S.'
run_phase prove
expect "a theorem resting on a Section Variable" 1 'rests on an assumption'

fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" "" 'Lemma sec : True. Proof. exact I. Qed. Print Assumptions sec.'
run_phase prove REQUIRED_THEOREMS="sec"
expect "a required name that is printed" 0 '1 required theorem(s) reported'
run_phase prove REQUIRED_THEOREMS="ec"
expect "a required name must match whole identifiers" 1 "required theorem 'ec'"

fresh_fixture
run_phase prove FILES="proofs/Ok.v proofs/Ghost.v"
expect "a listed file that does not exist" 1 'does not exist'
run_phase detect FILES="proofs/Ok.v proofs/Ghost.v"
expect "detect: a listed file that does not exist" 1 'missing: proofs/Ghost.v'
run_phase detect FILES=
expect "detect: .v files and an empty list" 1 'names none'
run_phase prove REQUIRED_THEOREMS='bad name;'
expect "a required name that is not an identifier is exit 2" 2 'not a plain identifier'

echo "== two files, dependency order =="
fresh_fixture
printf 'Lemma base : True. Proof. exact I. Qed.\nPrint Assumptions base.\n' > "$FIX/proofs/Base.v"
printf 'Require Import Base.\nLemma uses : True. Proof. exact base. Qed.\nPrint Assumptions uses.\n' > "$FIX/proofs/Uses.v"
run_phase prove FILES="proofs/Base.v proofs/Uses.v" REQUIRED_THEOREMS="base uses"
expect "a dependency listed first, required names across files" 0 '2 file(s) compile'
run_phase prove FILES="proofs/Uses.v proofs/Base.v"
expect "a dependent listed before its dependency fails" 1 'coqc failed'

echo "== toolchain pin =="
fresh_fixture
mkdir -p "$WORK/fake"
printf '#!/usr/bin/env bash\necho "The Coq Proof Assistant, version 8.18.0"\n' > "$WORK/fake/coqc"; chmod +x "$WORK/fake/coqc"
run_phase prove COQC_BIN="$WORK/fake/coqc"
expect "a binary that is not the pinned build is exit 2" 2 'pinned f14ab0c140bdfdb31c7e7e1f20379703973376480a4eea2d43d0fa56ddae03ec'
run_phase prove COQC_BIN="$WORK/fake/absent"
expect "an absent binary is exit 2" 2 'not found'
rm -rf "$FIX/proofs"
run_phase detect
expect "detect on a tree with no .v file is silent" 0 'units=0'
run_phase prove FILES=
expect "prove with nothing listed is exit 2, not green" 2 'NO CHECK WAS PERFORMED'

echo "== mutants of check.sh: a vacuous planted control must be refused =="
fresh_fixture
mutant() { # mutant <label> <old-text> <new-text> <want-text>: literal replace
  local content; content="$(cat "$checker")"
  printf '%s\n' "${content/"$2"/"$3"}" > "$WORK/mutant.sh"
  if cmp -s "$checker" "$WORK/mutant.sh"; then bad "$1: the mutation did not apply"; return; fi
  ( cd "$FIX" && env ROCQ_GATE_PHASE=prove FILES=proofs/Ok.v "$BASH_BIN" --noprofile --norc -e -o pipefail "$WORK/mutant.sh" ) > "$OUT" 2>&1
  RC=$?
  expect "$1" 2 "$4"
}
mutant "an axiom control that is in fact closed" 'Axiom cheat : False.\nLemma planted_axiom : False.\nProof. exact cheat. Qed.' 'Lemma planted_axiom : True.\nProof. exact I. Qed.' 'planted Axiom control was ACCEPTED'
mutant "an ill-typed control that is in fact well typed" 'Lemma planted_ill_typed : False.' 'Lemma planted_ill_typed : True.' 'planted IllTyped control was ACCEPTED'
mutant "an unprinted control that is printed" 'Proof. exact I. Qed.\n'"'"' > "$ctl/Unprinted.v"' 'Proof. exact I. Qed.\nPrint Assumptions planted_unprinted.\n'"'"' > "$ctl/Unprinted.v"' 'planted Unprinted control was ACCEPTED'
mutant "an admitted control that is closed" 'Lemma planted_admitted : False.\nProof. Admitted.' 'Lemma planted_admitted : True.\nProof. exact I. Qed.' 'planted Admitted control was ACCEPTED'
mutant "a true control that is in fact false" 'Lemma planted_true : True.' 'Lemma planted_true : False.' 'planted CLOSED theorem was refused'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
