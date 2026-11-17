#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the Rocq gate must fail for each thing it claims to check, under the
# exact composite shell. This test runs the REAL pinned coqc and coqchk (the gate
# refuses any other binary, so a stand-in is not possible); a missing or wrong
# tool is exit 2, never a skip. CHECKER=<path> runs the same suite against
# another copy of check.sh, which is how a before/after record is made.
#
# The gate judges the compiled artefact with coqchk. So the forgeries here are
# files whose own text lies: a Notation that makes `Check` print the closed-
# context line, a commented-out or extra-space `Print Assumptions`, an Admitted
# lemma nobody prints, `Unset Guard Checking` with a non-terminating fixpoint,
# type-in-type, assumed positivity. Each must be refused. A file with no prints
# at all, and a clean module, must pass. Then mutants of check.sh itself: each
# part of the judgement, made vacuous, must make the gate refuse (exit 2).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="${CHECKER:-$here/check.sh}"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v coqc >/dev/null 2>&1 || { echo "rocq-check/test.sh: coqc is not installed — NO CHECK WAS PERFORMED." >&2; exit 2; }
command -v coqchk >/dev/null 2>&1 || { echo "rocq-check/test.sh: coqchk is not installed — NO CHECK WAS PERFORMED." >&2; exit 2; }
BASH_BIN="$(command -v bash)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
FIX="$WORK/fixture"

names=(sound_one sound_two haruspex)
# A Notation that makes `Check` print the line coqc prints for a closed theorem.
FORGE_NOTATION="Notation \"'Closed' 'under' 'the' 'global' 'context'\" := tt."
FORGE_CHECK="Check (Closed under the global context)."
# rocq_fixture <file> [skip-name] [extra]: a Lemma and its Print Assumptions per name.
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
  if [ "$RC" -eq "$2" ] && grep -qF -- "$3" "$OUT"; then ok "$1 (exit $RC)"; else bad "$1: want exit $2 and \"$3\", got exit $RC"; sed 's/^/        /' "$OUT" | tail -n 12; fi
}
write() { printf '%s\n' "${@:2}" > "$FIX/proofs/$1"; } # write <file> <line>...

echo "== positive control: a clean tree passes =="
fresh_fixture
run_phase detect
expect "detect on a clean tree" 0 'units=1'
run_phase prove REQUIRED_THEOREMS="sound_one sound_two haruspex"
expect "prove on a clean tree" 0 '3 required theorem(s) resolved'
grep -q 'closed theorem, with and without a Print Assumptions, accepted' "$OUT" && ok "the true planted controls were exercised" || bad "no true control"
for c in Axiom Admitted Parameter IllTyped GuardOff TypeInType PositivityOff NotationForge; do
  grep -q "planted control: $c refused" "$OUT" && ok "the $c planted control was exercised" || bad "the $c control was not run"
done
grep -q "the existence check can say no" "$OUT" && ok "the existence planted control was exercised" || bad "no existence control"
grep -q 'coqchk: no axiom, no disabled check' "$OUT" && ok "the coqchk verdict is reported" || bad "verdict not reported"

echo "== a module is judged whole: prints are neither needed nor trusted =="
fresh_fixture
write Ok.v 'Lemma lonely : True. Proof. exact I. Qed.'
run_phase prove
expect "a file with no Print Assumptions passes" 0 'coqchk accepts them with no axiom'

fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" "" '(* Print Assumptions sound_one. *)'
run_phase prove
expect "a commented-out print does not matter" 0 'coqchk accepts them'

fresh_fixture
write Ok.v 'Lemma ok : True. Proof. exact I. Qed.' 'Print  Assumptions ok.'
run_phase prove REQUIRED_THEOREMS=ok
expect "fixture extra-space-print: Print  Assumptions with two spaces" 0 '1 required theorem(s) resolved'

fresh_fixture
write Ok.v 'Lemma ok : True. Proof. exact I. Qed.' 'Lemma unprinted : True. Proof. exact I. Qed.' 'Print Assumptions ok.'
run_phase prove REQUIRED_THEOREMS="ok unprinted"
expect "fixture generated-query: a required theorem nobody prints exists" 0 '2 required theorem(s) resolved'

fresh_fixture
write Ok.v 'Axiom cheat : False.' 'Lemma bad : False. Proof. exact cheat. Qed.' \
  'Lemma ok : True. Proof. exact I. Qed.' 'Print  Assumptions ok.' '(* Print Assumptions bad. *)'
run_phase prove REQUIRED_THEOREMS=bad
expect "fixture hidden-print: an axiom under a commented print" 1 'coqchk reports axiom(s)'

fresh_fixture
write Ok.v 'Axiom cheat : False.' 'Lemma bad : False. Proof. exact cheat. Qed.' "$FORGE_NOTATION" "$FORGE_CHECK"
run_phase prove
expect "fixture notation-forge: Check prints the closed-context line over an Axiom" 1 'coqchk reports axiom(s)'

fresh_fixture
write Ok.v 'Unset Guard Checking.' 'Fixpoint loop (n : nat) : False := loop n.' \
  'Lemma bad : False. Proof. exact (loop 0). Qed.' "$FORGE_NOTATION" "$FORGE_CHECK"
run_phase prove
expect "fixture guard-off: a non-terminating fixpoint under Unset Guard Checking" 1 'unsafe (co)fixpoints'

fresh_fixture
write Ok.v 'Lemma unprinted_admitted : False. Proof. Admitted.' 'Lemma ok : True. Proof. exact I. Qed.' 'Print Assumptions ok.'
run_phase prove
expect "fixture admitted-unprinted: an Admitted lemma nobody prints" 1 'Ok.unprinted_admitted'

fresh_fixture
write Ok.v 'Unset Universe Checking.' 'Definition tit : Type := Type.' "$FORGE_NOTATION" "$FORGE_CHECK"
run_phase prove
expect "type-in-type is refused" 1 'type-in-type'

fresh_fixture
write Ok.v 'Unset Positivity Checking.' 'Inductive pbad : Type := pmk : (pbad -> False) -> pbad.' "$FORGE_NOTATION" "$FORGE_CHECK"
run_phase prove
expect "assumed positivity is refused" 1 'positivity is assumed'

fresh_fixture
write Ok.v 'Section S. Variable P : Prop. Lemma sec : P -> P. Proof. intro h; exact h. Qed. End S.'
run_phase prove REQUIRED_THEOREMS=sec
expect "a Section Variable discharged by End is not an axiom" 0 '1 required theorem(s) resolved'

echo "== other defects =="
fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" "" 'Axiom cheat : False. Lemma sound_one_bad : False. Proof. exact cheat. Qed.'
run_phase prove
expect "a theorem resting on an Axiom, printed or not" 1 'Ok.cheat'

fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" sound_two 'Lemma sound_two : False. Proof. Admitted. Print Assumptions sound_two.'
run_phase prove
expect "an Admitted theorem" 1 'an Admitted lemma is one'

fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" haruspex
run_phase prove REQUIRED_THEOREMS="sound_one haruspex"
expect "a required theorem that does not exist" 1 "no assumption report for required theorem 'haruspex'"

fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" "" 'Lemma broken : False. Proof. exact I. Qed.'
run_phase prove
expect "a file that does not compile" 1 'coqc failed'

fresh_fixture
rocq_fixture "$FIX/proofs/Ok.v" "" 'Lemma sec : True. Proof. exact I. Qed. Print Assumptions sec.'
run_phase prove REQUIRED_THEOREMS="sec"
expect "a required name that exists" 0 '1 required theorem(s) resolved'
run_phase prove REQUIRED_THEOREMS="ec"
expect "a required name must match whole identifiers" 1 "required theorem 'ec'"

fresh_fixture
write Ok.v 'Axiom cheat : False.' 'Lemma bad : False. Proof. exact cheat. Qed.'
run_phase prove ALLOWED_AXIOMS=Ok.cheat
expect "an allowed axiom is not counted" 0 'coqchk accepts them'
run_phase prove ALLOWED_AXIOMS=Ok.other
expect "an allowed name that is not the axiom does not help" 1 'Ok.cheat'

fresh_fixture
run_phase prove FILES="proofs/Ok.v proofs/Ghost.v"
expect "a listed file that does not exist" 1 'does not exist'
run_phase detect FILES="proofs/Ok.v proofs/Ghost.v"
expect "detect: a listed file that does not exist" 1 'missing: proofs/Ghost.v'
run_phase detect FILES=
expect "detect: .v files and an empty list" 1 'names none'
run_phase prove REQUIRED_THEOREMS='bad name;'
expect "a required name that is not an identifier is exit 2" 2 'is not an identifier'

echo "== what coqchk's summary cannot see: sealed modules, functor bodies (refused fail-closed) =="
fresh_fixture
write Ok.v 'Module Type S.' '  Parameter bad : False.' 'End S.' 'Module M : S.' '  Unset Guard Checking.' \
  '  Fixpoint loop (n : nat) : False := loop n.' '  Set Guard Checking.' '  Lemma bad : False. Proof. exact (loop 0). Qed.' 'End M.'
run_phase prove REQUIRED_THEOREMS=M.bad
expect "fixture sealed-module: an unsafe fixpoint hidden by Module M : S" 1 'module type ascription'

fresh_fixture
write Ok.v 'Module Type E. End E.' 'Module F (X : E).' '  Axiom cheat : False.' 'End F.' 'Lemma ok : True. Proof. exact I. Qed.'
run_phase prove
expect "fixture functor-body: an axiom inside an uninstantiated functor" 1 'a functor'

fresh_fixture
write Ok.v 'Module Type E. End E.' 'Module F' '  (X : E).' '  Axiom cheat : False.' 'End F.'
run_phase prove
expect "a functor header broken over two lines is still seen" 1 'a functor'

fresh_fixture
write Ok.v 'Module Type S. Parameter p : nat. End S.' 'Module M <: S. Definition p := 1. End M.'
run_phase prove
expect "Module M <: S is refused too" 1 'module type ascription'

fresh_fixture
write Other.v 'Definition other : nat := 1.'
write Ok.v 'Load "Other".'
run_phase prove FILES="proofs/Other.v proofs/Ok.v"
expect "Load runs commands the scan cannot see" 1 'Load, Add LoadPath'

fresh_fixture
write Ok.v 'Unset Guard Checking.' 'Set Guard Checking.' 'Lemma ok : True. Proof. exact I. Qed.'
run_phase prove
expect "Unset Guard Checking is refused even when nothing used it" 1 'Unset Guard/Positivity/Universe'

fresh_fixture
write Ok.v '#[bypass_check(positivity)] Inductive pb : Type := mk : (pb -> False) -> pb.'
run_phase prove
expect "#[bypass_check] is refused (coqchk sees the flag)" 1 'unsafe (co)fixpoints'


echo "== the module scan is an allow-list: comments and Unicode names cannot slip past it =="
fresh_fixture
write Ok.v 'Module Type S.' '  Parameter bad : False.' 'End S.' 'Module (* hidden *) M : S.' '  Unset (* x *) Guard Checking.' \
  '  Fixpoint loop (n : nat) : False := loop n.' '  Set Guard Checking.' '  Lemma bad : False. Proof. exact (loop 0). Qed.' 'End M.'
run_phase prove
expect "fixture comment-sealed: Module (* hidden *) M : S with Unset (* x *) Guard Checking" 1 'Refused fail-closed'

fresh_fixture
write Ok.v 'Module Type E. End E.' 'Module (* c *) F (X : E).' '  Axiom cheat : False.' 'End F.' 'Lemma ok : True. Proof. exact I. Qed.'
run_phase prove
expect "fixture comment-functor: Module (* c *) F (X : E) with an axiom in the body" 1 'Refused fail-closed'

fresh_fixture
write Ok.v 'Module Type E. End E.' 'Module ℱ (X : E).' '  Axiom cheat : False.' 'End ℱ.' 'Lemma ok : True. Proof. exact I. Qed.'
run_phase prove
expect "fixture unicode-functor: a functor with a non-ASCII name" 1 'Refused fail-closed'

fresh_fixture
write Ok.v 'Module ℳ.' '  Definition d := 1.' 'End ℳ.'
run_phase prove
expect "a plain module with a non-ASCII name is refused (the allow-list is ASCII)" 1 'Refused fail-closed'

fresh_fixture
write Ok.v 'Unset (* x *) Guard Checking.' 'Set Guard Checking.' 'Lemma ok : True. Proof. exact I. Qed.'
run_phase prove
expect "fixture comment-unset: a comment between the words of Unset Guard Checking" 1 'Refused fail-closed'

fresh_fixture
write Ok.v 'Module Type E. End E.' 'Module Type F (X : E). End F.'
run_phase prove
expect "a functor signature is refused" 1 'Refused fail-closed'

fresh_fixture
write Ok.v 'Declare Scope my_scope.'
run_phase prove
expect "Declare (any form) is refused" 1 'Load, Add LoadPath'

fresh_fixture
write Ok.v 'Definition Module_x : nat := 1.'
run_phase prove
expect "any other word containing Module is refused (the scan is textual)" 1 'Refused fail-closed'

fresh_fixture
write Ok.v 'Module Type T. End T.' 'Module M. Definition d := 1. End M.' 'Module Import N. Definition e := 2. End N.' 'Module Type U.' ' Parameter p : nat.' 'End U.'
run_phase prove REQUIRED_THEOREMS="M.d N.e"
expect "plain modules, Import modules and module types pass" 0 '2 required theorem(s) resolved'

fresh_fixture
write Ok.v 'Module Type E. End E.' 'Module (* gap *) F (X : E).' '  Axiom cheat : False.' 'End F.' 'Lemma ok : True. Proof. exact I. Qed.'
run_phase prove
expect "fixture comment-gap: CodeRabbit's exact comment-separated functor header" 1 'Refused fail-closed'

echo "== controls are judged with no allowance, whatever the caller allows =="
fresh_fixture
run_phase prove ALLOWED_AXIOMS="Axiom.cheat Admitted.planted_admitted Parameter.planted_param"
expect "fixture allowance-vs-controls: a caller allowing the planted axioms still gets the controls refused" 0 'coqchk accepts them'

echo "== the probe module cannot collide with a listed module =="
fresh_fixture
write GateRequired.v 'Lemma ok : True. Proof. exact I. Qed.'
run_phase prove FILES=proofs/GateRequired.v REQUIRED_THEOREMS=ok
expect "fixture probe-collision: a listed file named like the old probe" 0 '1 required theorem(s) resolved'
write GateProbe.v 'Lemma ok : True. Proof. exact I. Qed.'
run_phase prove FILES=proofs/GateProbe.v REQUIRED_THEOREMS=ok
expect "a listed file named like the current probe" 0 '1 required theorem(s) resolved'
write GateProbeX.v 'Lemma okx : True. Proof. exact I. Qed.'
write GateProbe.v 'Lemma ok : True. Proof. exact I. Qed.'
run_phase prove FILES="proofs/GateProbeX.v proofs/GateProbe.v" REQUIRED_THEOREMS="okx ok"
expect "fixture probe-order: GateProbeX.v listed before GateProbe.v" 0 '2 required theorem(s) resolved'

echo "== two files, dependency order =="
fresh_fixture
printf 'Lemma base : True. Proof. exact I. Qed.\n' > "$FIX/proofs/Base.v"
printf 'Require Import Base.\nLemma uses : True. Proof. exact base. Qed.\n' > "$FIX/proofs/Uses.v"
run_phase prove FILES="proofs/Base.v proofs/Uses.v" REQUIRED_THEOREMS="base uses"
expect "a dependency listed first, required names across files" 0 '2 required theorem(s) resolved'
run_phase prove FILES="proofs/Uses.v proofs/Base.v"
expect "a dependent listed before its dependency fails" 1 'coqc failed'
mkdir -p "$FIX/other"; cp "$FIX/proofs/Base.v" "$FIX/other/Base.v"
run_phase prove FILES="proofs/Base.v other/Base.v"
expect "two listed files with one name collide" 1 'collide'

echo "== toolchain pin =="
fresh_fixture
mkdir -p "$WORK/fake"
printf '#!/usr/bin/env bash\necho "The Coq Proof Assistant, version 8.18.0"\n' > "$WORK/fake/coqc"; chmod +x "$WORK/fake/coqc"
printf '#!/usr/bin/env bash\necho "The Coq Proof Checker, version 8.18.0"\n' > "$WORK/fake/coqchk"; chmod +x "$WORK/fake/coqchk"
run_phase prove COQC_BIN="$WORK/fake/coqc"
expect "a coqc that is not the pinned build is exit 2" 2 'pinned f14ab0c140bdfdb31c7e7e1f20379703973376480a4eea2d43d0fa56ddae03ec'
run_phase prove COQCHK_BIN="$WORK/fake/coqchk"
expect "a coqchk that is not the pinned build is exit 2" 2 'pinned 788a7a87e176bfd4a8820f76871efaa087a052d68447d8f129bcdf15c6c7ac87'
run_phase prove COQCHK_BIN="$WORK/fake/absent"
expect "an absent coqchk is exit 2" 2 'not found'
run_phase prove COQC_BIN="$WORK/fake/absent"
expect "an absent coqc is exit 2" 2 'not found'
rm -rf "$FIX/proofs"
run_phase detect
expect "detect on a tree with no .v file is silent" 0 'units=0'
run_phase prove FILES=
expect "prove with nothing listed is exit 2, not green" 2 'NO CHECK WAS PERFORMED'

echo "== mutants of check.sh: a vacuous part of the judgement must be refused =="
fresh_fixture
mutant() { # mutant <label> <old-text> <new-text> <want-text>: literal replace
  local content; content="$(cat "$checker")"
  printf '%s\n' "${content/"$2"/"$3"}" > "$WORK/mutant.sh"
  if cmp -s "$checker" "$WORK/mutant.sh"; then bad "$1: the mutation did not apply"; return; fi
  ( cd "$FIX" && env ROCQ_GATE_PHASE=prove FILES=proofs/Ok.v "$BASH_BIN" --noprofile --norc -e -o pipefail "$WORK/mutant.sh" ) > "$OUT" 2>&1
  RC=$?
  expect "$1" 2 "$4"
}
mutant "a judge that ignores axioms" 'axioms) if is_allowed "$name"; then continue; fi; axioms="$axioms $name" ;;' 'axioms) : ;;' 'was ACCEPTED'
mutant "a judge that ignores type-in-type" 'tit) tit="$tit $name" ;;' 'tit) : ;;' 'wrong stage'
mutant "a judge that ignores unsafe fixpoints" 'unsafe) unsafe="$unsafe $name" ;;' 'unsafe) : ;;' 'wrong stage'
mutant "a judge that ignores assumed positivity" 'pos) pos="$pos $name" ;;' 'pos) : ;;' 'wrong stage'
mutant "a judge that never runs coqchk" '(cd "$scratch" && "$coqchk_bin" -o "${mods[@]}") > "$scratch/coqchk.log" 2>&1 || rc=$?' ': > "$scratch/coqchk.log"' "summary is not in the expected shape"
mutant "a judge that trusts a clean-looking coqchk exit code only" 'parse_summary "$scratch/coqchk.log" "$rows" ||' 'true ||' 'was ACCEPTED'
mutant "an existence check that ignores the exit code" '(cd "$scratch" && "$coqc_bin" "$probe_mod.v") > "$scratch/$probe_mod.log" 2>&1' '(cd "$scratch" && "$coqc_bin" "$probe_mod.v") > "$scratch/$probe_mod.log" 2>&1; true' 'resolved a name that does not exist'
mutant "a judge without the text rule" 'if [ -n "$why" ]; then DEFECT="$f: $why"; DEFECT_KIND=text; return 1; fi' ':' 'planted Sealed control was ACCEPTED'
mutant "a true control that is in fact false" 'Lemma planted_true : True.' 'Lemma planted_true : False.' 'was refused'
mutant "an axiom control that is in fact closed" "Axiom cheat : False.\\nLemma planted_axiom : False.\\nProof. exact cheat. Qed.\\n" "Lemma planted_axiom : True.\\nProof. exact I. Qed.\\n" 'planted Axiom control was ACCEPTED'
mutant "an ill-typed control that is well typed" 'Lemma planted_ill_typed : False.' 'Lemma planted_ill_typed : True.' 'planted IllTyped control was ACCEPTED'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
