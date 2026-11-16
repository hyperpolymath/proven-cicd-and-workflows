#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the Lean axiom gate must fail for each thing it claims to check,
# under the exact composite shell. This test runs the REAL pinned Lean 4.15.0
# (the gate refuses any other binary, so a stand-in is not possible); a missing
# or wrong Lean is exit 2, never a skip. Put the pinned bin/lean on PATH or set
# LEAN_BIN. CHECKER=<path> runs the same suite against another copy of check.sh,
# which is how a before/after record is made.
#
# The gate judges the compiled module with its own checker. So the forgeries here
# are files whose own text lies: a `#eval` that prints the clean line (with a
# required name that does not exist), `elab_rules` that rewrite `#print axioms`,
# a declaration added with debug.skipKernelTC, an axiom used only by an unprinted
# theorem, a commented-out or extra-space print. Each must be refused. A file with
# no prints at all, and a clean module, must pass. Then mutants of check.sh
# itself: each part of the judgement, made vacuous, must make the gate refuse
# (exit 2) rather than report green.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="${CHECKER:-$here/check.sh}"
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
# lean_fixture <file> [skip-name] [extra]: a theorem and its #print axioms per name.
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
  if [ "$RC" -eq "$2" ] && grep -qF -- "$3" "$OUT"; then ok "$1 (exit $RC)"; else bad "$1: want exit $2 and \"$3\", got exit $RC"; sed 's/^/        /' "$OUT" | tail -n 12; fi
}
write() { printf '%s\n' "${@:2}" > "$FIX/proofs/$1"; } # write <file> <line>...

echo "== positive control: a clean tree passes =="
fresh_fixture
run_phase detect
expect "detect on a clean tree" 0 'units=1'
run_phase prove REQUIRED_THEOREMS="sound_one sound_two haruspex"
expect "prove on a clean tree" 0 '3 required theorem(s) resolved'
grep -q 'with and without a #print axioms, accepted' "$OUT" && ok "the true planted controls were exercised" || bad "no true control"
for c in Sorry Classical Axiom AxiomUnprinted IllTyped EvalForge MacroForge SkipKernel; do
  grep -q "planted control: $c refused" "$OUT" && ok "the $c planted control was exercised" || bad "the $c control was not run"
done
grep -q 'resolution can say no' "$OUT" && ok "the resolution planted control was exercised" || bad "no resolution control"
grep -q 'kernel replay ok, no disallowed axiom' "$OUT" && ok "the checker verdict is reported" || bad "verdict not reported"

echo "== a module is judged whole: prints are neither needed nor trusted =="
fresh_fixture
write Ok.lean 'theorem lonely : True := trivial'
run_phase prove
expect "a file with no #print axioms passes" 0 'finds no disallowed axiom'

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" "" '-- #print axioms Fixture.sound_one'
run_phase prove
expect "a commented-out print does not matter" 0 'finds no disallowed axiom'

fresh_fixture
write Ok.lean 'theorem ok : True := trivial' '#print  axioms ok'
run_phase prove REQUIRED_THEOREMS=ok
expect "fixture extra-space-print: #print  axioms with two spaces" 0 '1 required theorem(s) resolved'

fresh_fixture
write Ok.lean 'theorem ok : True := trivial' 'namespace A' 'namespace B' 'theorem unprinted : True := trivial' 'end B' 'end A' '#print axioms ok'
run_phase prove REQUIRED_THEOREMS="ok unprinted"
expect "fixture generated-query: a required theorem under nested namespaces, never printed, exists" 0 '2 required theorem(s) resolved'

fresh_fixture
write Ok.lean 'axiom cheat : False' 'theorem bad : False := cheat' 'theorem ok : True := trivial' '#print  axioms ok' '-- #print axioms bad'
run_phase prove REQUIRED_THEOREMS=bad
expect "fixture hidden-print: an axiom under a commented print" 1 'not allowed: [cheat]'

fresh_fixture
write Ok.lean '#eval IO.println "'"'"'bad'"'"' does not depend on any axioms"' 'theorem ok : True := trivial' '#print axioms ok'
run_phase prove REQUIRED_THEOREMS=bad
expect "fixture eval-forge: #eval prints the clean line for an undefined required name" 1 "no axiom report for required theorem 'bad'"

fresh_fixture
write Ok.lean 'axiom cheat : False' 'theorem bad : False := cheat' \
  '#eval IO.println "'"'"'bad'"'"' does not depend on any axioms"' '#eval IO.println "'"'"'ok'"'"' does not depend on any axioms"' 'theorem ok : True := trivial'
run_phase prove REQUIRED_THEOREMS=bad
expect "fixture eval-forge-axiom: #eval prints the clean line for a theorem on an axiom" 1 'not allowed: [cheat]'

fresh_fixture
write Ok.lean 'import Lean' 'open Lean Elab Command' 'axiom cheat : False' 'theorem bad : False := cheat' \
  'elab_rules : command' "  | \`(#print axioms \$id:ident) => logInfo m!\"'{id.getId}' does not depend on any axioms\"" '#print axioms bad'
run_phase prove REQUIRED_THEOREMS=bad
expect "fixture macro-forge: elab_rules rewrite #print axioms" 1 'cheat'

fresh_fixture
write Ok.lean 'import Lean' 'open Lean Elab Command' \
  'set_option debug.skipKernelTC true in' \
  'run_cmd liftCoreM (addDecl (.thmDecl { name := `bad, levelParams := [], type := mkConst ``False, value := mkConst ``True.intro }))' \
  '#print axioms bad'
run_phase prove REQUIRED_THEOREMS=bad
expect "fixture skip-kernel: a declaration added with debug.skipKernelTC" 1 'kernel replay rejected the module'

fresh_fixture
write Ok.lean 'structure S where' '  x : Nat' '  y : Nat' 'theorem ok : True := trivial'
run_phase prove
expect "fixture generated-propext: the injEq theorem Lean generates for a structure uses propext" 1 'propext'
run_phase prove ALLOWED_AXIOMS=propext
expect "propext named in allowed_axioms is not counted" 0 'finds no disallowed axiom'

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" "" 'axiom cheat : False
theorem sound_one_bad : False := cheat'
run_phase prove
expect "fixture axiom-unprinted: an axiom used by an unprinted theorem" 1 'Fixture.cheat'

echo "== other defects =="
fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" sound_one 'theorem sound_one : False := sorry'
run_phase prove
expect "a theorem left as sorry" 1 'sorryAx'

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" sound_two 'theorem sound_two (p : Prop) : p ∨ ¬p := Classical.em p'
run_phase prove
expect "a theorem using Classical.choice" 1 'Classical.choice'

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" haruspex
run_phase prove REQUIRED_THEOREMS="sound_one haruspex"
expect "a required theorem that does not exist" 1 "no axiom report for required theorem 'haruspex'"

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" "" 'theorem broken : False := trivial'
run_phase prove
expect "a file that does not compile" 1 'lean failed'

fresh_fixture
lean_fixture "$FIX/proofs/Ok.lean" "" 'theorem sec : True := trivial'
run_phase prove REQUIRED_THEOREMS="sec"
expect "a required name that exists" 0 '1 required theorem(s) resolved'
run_phase prove REQUIRED_THEOREMS="ec"
expect "a required name must match whole components" 1 "required theorem 'ec'"
run_phase prove REQUIRED_THEOREMS="Fixture.sec"
expect "a qualified required name" 0 '1 required theorem(s) resolved'

fresh_fixture
write Ok.lean 'axiom cheat : False' 'theorem bad : False := cheat'
run_phase prove ALLOWED_AXIOMS=cheat
expect "an allowed axiom is not counted" 0 'finds no disallowed axiom'
run_phase prove ALLOWED_AXIOMS=other
expect "an allowed name that is not the axiom does not help" 1 'not allowed: [cheat]'
run_phase prove ALLOWED_AXIOMS=sorryAx
expect "sorryAx is never allowable, even when named" 2 'sorryAx is never allowable'

fresh_fixture
run_phase prove FILES="proofs/Ok.lean proofs/Ghost.lean"
expect "a listed file that does not exist" 1 'does not exist'
run_phase detect FILES="proofs/Ok.lean proofs/Ghost.lean"
expect "detect: a listed file that does not exist" 1 'missing: proofs/Ghost.lean'
run_phase detect FILES=
expect "detect: standalone .lean files and an empty list" 1 'names none'
run_phase prove REQUIRED_THEOREMS='bad name;'
expect "a required name that is not an identifier is exit 2" 2 'is not an identifier'

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

echo "== mutants of check.sh: a vacuous part of the judgement must be refused =="
fresh_fixture
mutant() { # mutant <label> <old-text> <new-text> <want-text>: literal replace
  local content; content="$(cat "$checker")"
  printf '%s\n' "${content/"$2"/"$3"}" > "$WORK/mutant.sh"
  if cmp -s "$checker" "$WORK/mutant.sh"; then bad "$1: the mutation did not apply"; return; fi
  ( cd "$FIX" && env LEAN_GATE_PHASE=prove FILES=proofs/Ok.lean "$BASH_BIN" --noprofile --norc -e -o pipefail "$WORK/mutant.sh" ) > "$OUT" 2>&1
  RC=$?
  expect "$1" 2 "$4"
}
mutant "a gate that ignores its checker's exit code" 'run_checker "$scratch" check "GateMod$i" "$allowed_csv" || rc=$?' 'run_checker "$scratch" check "GateMod$i" "$allowed_csv" || true' 'was ACCEPTED'
mutant "a checker that skips the kernel replay" 'let env ← try base.replay consts catch e =>' 'let env ← try importModules #[{ module := modStr.toName }] {} 0 catch e =>' 'planted SkipKernel control was ACCEPTED'
mutant "a checker that ignores axioms" 'let bad := st.axioms.filter (!allowed.contains ·)' 'let bad : Array Name := #[]' 'was ACCEPTED'
mutant "a checker that collects no axioms" 'roots.forM CollectAxioms.collect' '(#[] : Array Name).forM CollectAxioms.collect' 'was ACCEPTED'
mutant "a checker that resolves every name" 'unless md.constNames.any (endsWith · r.toName) do' 'unless true do' 'resolved a name that does not exist'
mutant "a gate that reads lean messages instead of the checker" 'run_checker "$scratch" check "GateMod$i" "$allowed_csv" || rc=$?' 'grep -q "does not depend on any axioms" "$scratch/GateMod$i.log" || rc=1' 'planted NoPrint control was refused'
mutant "a true control that is in fact false" 'theorem planted_true : True := trivial' 'theorem planted_true : True := sorry' 'was refused'
mutant "an axiom control that is in fact proved" 'axiom planted_cheat : False\ntheorem planted_axiom : False := planted_cheat' 'theorem planted_axiom : True := trivial' 'planted Axiom control was ACCEPTED'
mutant "an ill-typed control that is well typed" 'planted_ill_typed : False := trivial' 'planted_ill_typed : True := trivial' 'planted IllTyped control was ACCEPTED'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
