#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the TLA+ gate must fail for each thing it claims to check, under the
# exact composite shell. This test runs the REAL pinned TLC on Java 21 (the gate
# refuses any other jar, so a stand-in is not possible); a missing Java is exit
# 2, never a skip. The jar comes from TLA_JAR; if that is unset or absent the
# gate fetches the pinned release (needs network) and checks its SHA-256.
# A clean fixture must pass, then one defect at a time, each of which the gate
# must fail: a must-pass config that errors, a must-refute config that passes,
# a must-refute config refuted by a different invariant, a deadlock or a missing
# invariant standing in for a refutation, a missing spec or config, a tampered
# jar, the wrong Java. Then mutants of check.sh itself: each planted control and
# each judgement, made vacuous, must make the gate refuse (exit 2).
#
# Ported from the negative controls of hvn-dehallucinator's scripts/check-tla.sh
# (Original.cfg and OtherTarget.cfg must be refuted by the invariant named).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$here/check.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v java >/dev/null 2>&1 || { echo "tla-check/test.sh: java is not installed — NO CHECK WAS PERFORMED." >&2; exit 2; }
# The gate accepts only its pinned Java package. A runner with some other Java has
# no toolchain for these controls: that is NOT RUN, not a failed control.
JAVA_PACKAGE="$(sed -n 's/^PIN_JAVA_PACKAGE="\(.*\)"$/\1/p' "$(dirname "$0")/check.sh")"
[[ -n "$JAVA_PACKAGE" ]] || { echo "tla-check/test.sh: PIN_JAVA_PACKAGE not found in check.sh" >&2; exit 1; }
[[ -n "$(dpkg-query -W -f='${Version}' "$JAVA_PACKAGE" 2>/dev/null || true)" ]] \
  || { echo "tla-check/test.sh: package $JAVA_PACKAGE is not installed — NO CHECK WAS PERFORMED." >&2; exit 2; }
BASH_BIN="$(command -v bash)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
FIX="$WORK/fixture"
JAR="${TLA_JAR:-$WORK/tla2tools-v1.7.4.jar}"
export TLA_JAR="$JAR"

fresh_fixture() {
  local d="$FIX/verification/proofs/tlaplus"
  rm -rf "$FIX"; mkdir -p "$d"
  cat > "$d/Model.tla" <<'TLA'
---- MODULE Model ----
EXTENDS Naturals, TLC
CONSTANT Limit
VARIABLE x
Init == x = 0
Next == x' = IF x < Limit THEN x + 1 ELSE x
Spec == Init /\ [][Next]_x
NoStutter == Init /\ [][x < Limit /\ x' = x + 1]_x
Safe == x <= 3
Other == x >= 0
Positive == x > 0
Fake == Assert(FALSE, "Invariant Fake is violated.")
Forge == PrintT("\nError: Invariant Forge is violated.\n") /\ TRUE
====
TLA
  printf 'CONSTANT Limit = 3\nSPECIFICATION Spec\nINVARIANT Safe Other\n' > "$d/Ok.cfg"
  printf 'CONSTANT Limit = 5\nSPECIFICATION Spec\nINVARIANT Safe Other\n' > "$d/Bad.cfg"
  printf 'CONSTANT Limit = 3\nSPECIFICATION NoStutter\nINVARIANT Safe\n' > "$d/Dead.cfg"
  printf 'CONSTANT Limit = 3\nSPECIFICATION Spec\nINVARIANT NoSuchInvariant\n' > "$d/Missing.cfg"
  printf 'CONSTANT Limit = 3\nSPECIFICATION Spec\nINVARIANT Positive\n' > "$d/InitV.cfg"
  printf 'CONSTANT Limit = 3\nSPECIFICATION Spec\nINVARIANT Fake\n' > "$d/Asrt.cfg"
  printf 'CONSTANT Limit = 5\nSPECIFICATION Spec\nINVARIANT Forge Safe\n' > "$d/Forge.cfg"
}
run_phase() { # run_phase <phase> [VAR=value ...]
  local phase="$1"; shift
  ( cd "$FIX" && env TLA_GATE_PHASE="$phase" SPEC=Model.tla MUST_PASS=Ok.cfg MUST_REFUTE=Bad.cfg:Safe "$@" "$BASH_BIN" --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1
  RC=$?
}
expect() { # expect <name> <want-rc> <text>
  if [ "$RC" -eq "$2" ] && grep -qF -- "$3" "$OUT"; then ok "$1 (exit $RC)"; else bad "$1: want exit $2 and \"$3\", got exit $RC"; sed 's/^/        /' "$OUT" | tail -n 15; fi
}

echo "== positive control: a clean tree passes =="
fresh_fixture
run_phase detect
expect "detect on a clean tree" 0 'units=2'
run_phase prove
expect "prove on a clean tree" 0 'tla-check[prove]: 1 config(s) pass, 1 refuted by the invariant named'
grep -q 'a model that holds is judged to pass' "$OUT" && ok "the holding planted control was exercised" || bad "no holding control"
grep -q 'a model that violates Inv is refuted by Inv' "$OUT" && ok "the violated planted control was exercised" || bad "no violated control"
grep -q 'PASS: Invariant Safe violated, as it must be' "$OUT" && ok "the refutation is named" || bad "refutation not reported"
grep -q 'tla2tools v1.7.4 @ sha256:936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88' "$OUT" && ok "the jar pin is reported" || bad "jar pin not reported"
[ -f "$JAR" ] && ok "the pinned jar is in place" || bad "no jar at $JAR"

echo "== negative controls (each must fail the gate) =="
fresh_fixture
run_phase prove MUST_PASS=Bad.cfg
expect "a must-pass config that violates an invariant" 1 'it must pass'

fresh_fixture
run_phase prove MUST_REFUTE=Ok.cfg:Safe
expect "a must-refute config that passes" 1 'the model PASSED but must be refuted by Safe'

fresh_fixture
run_phase prove MUST_REFUTE=Bad.cfg:Other
expect "a must-refute config refuted by a different invariant" 1 'not refuted by Other'

fresh_fixture
run_phase prove MUST_REFUTE=Dead.cfg:Safe
expect "a deadlock is not a refutation by the named invariant" 1 'not refuted by Safe'

fresh_fixture
run_phase prove MUST_REFUTE=Missing.cfg:NoSuchInvariant
expect "an unknown invariant is not a refutation" 1 'not refuted by NoSuchInvariant'

fresh_fixture
run_phase prove MUST_REFUTE=Asrt.cfg:Fake
expect "fixture assert-text: an evaluation error carrying the invariant's text is not a refutation" 1 'not refuted by Fake'

fresh_fixture
run_phase prove MUST_REFUTE=Forge.cfg:Forge
expect "fixture print-forge: PrintT cannot start a line with Error:, so another invariant's exit 12 is not credited to Forge" 1 'not refuted by Forge'
grep -q '^"\\nError: Invariant Forge is violated\.\\n"$' "$OUT" && ok "TLC printed the forged text quoted and escaped on one line" || bad "the forged PrintT line was not as expected"

fresh_fixture
run_phase prove MUST_REFUTE=InitV.cfg:Positive
expect "fixture initial-state: an invariant violated by the initial state is a refutation" 0 'PASS: Invariant Positive violated, as it must be'

fresh_fixture
printf '%s\n' '---- MODULE Model ----' 'this is not TLA+' '====' > "$FIX/verification/proofs/tlaplus/Model.tla"
run_phase prove
expect "a spec that does not parse" 1 'it must pass'

fresh_fixture
run_phase prove MUST_PASS="Ok.cfg Ok.cfg" MUST_REFUTE="Bad.cfg:Safe Bad.cfg:Safe"
expect "several configs, each judged" 0 '2 config(s) pass, 2 refuted'

fresh_fixture
run_phase prove MUST_REFUTE=
expect "a gate with no must-refute config still passes what it lists" 0 '1 config(s) pass, 0 refuted'

echo "== detect =="
fresh_fixture
run_phase detect MUST_PASS= MUST_REFUTE=
expect "detect: a .tla file and no config listed" 1 'no config is listed'
run_phase detect SPEC=Absent.tla
expect "detect: the spec does not exist" 1 "spec 'verification/proofs/tlaplus/Absent.tla' does not exist"
run_phase detect MUST_PASS=Ghost.cfg
expect "detect: a listed config does not exist" 1 "listed config 'verification/proofs/tlaplus/Ghost.cfg' does not exist"
run_phase detect SPEC_DIR=elsewhere
expect "detect: the defaults point at nothing" 1 'does not exist'
mkdir -p "$FIX/tests/difftest"; printf '%s\n' '---- MODULE Helper ----' '====' > "$FIX/tests/difftest/Helper.tla"
run_phase detect
expect "detect: a helper .tla outside spec_dir is allowed" 0 'units=2'
rm -rf "$FIX/verification" "$FIX/tests"
run_phase detect
expect "detect on a tree with no .tla file is silent" 0 'units=0'
run_phase prove MUST_PASS= MUST_REFUTE=
expect "prove with no config listed is exit 2, not green" 2 'NO CHECK WAS PERFORMED'

echo "== input validation =="
fresh_fixture
run_phase prove MUST_REFUTE=Bad.cfg
expect "a must-refute entry with no invariant is exit 2" 2 'is not <config>.cfg:<Invariant>'
run_phase prove MUST_PASS='../Ok.cfg'
expect "a config path that climbs is exit 2" 2 'is not a config file name'
run_phase prove WORKERS='1; rm -rf /'
expect "workers that is not a number is exit 2" 2 "is not a number or 'auto'"

echo "== toolchain pin =="
fresh_fixture
cp "$JAR" "$WORK/tampered.jar"; printf 'x' >> "$WORK/tampered.jar"
run_phase prove TLA_JAR="$WORK/tampered.jar"
expect "a jar that is not the pinned build is exit 2" 2 'pinned 936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88'
[ ! -e "$WORK/tampered.jar" ] && ok "the tampered jar is removed, not run" || bad "the tampered jar was left in place"
mkdir -p "$WORK/fake"
printf '#!/usr/bin/env bash\necho '"'"'openjdk version "17.0.1" 2024-01-16'"'"' >&2\n' > "$WORK/fake/java"; chmod +x "$WORK/fake/java"
run_phase prove JAVA="$WORK/fake/java"
expect "a Java that is not 21 is exit 2" 2 'pinned 21'
run_phase prove JAVA="$WORK/fake/absent"
expect "an absent Java is exit 2" 2 'not found'

echo "== mutants of check.sh: a vacuous planted control or judgement must be refused =="
fresh_fixture
mutant() { # mutant <label> <old-text> <new-text> <want-text>: literal replace
  local content; content="$(cat "$checker")"
  printf '%s\n' "${content/"$2"/"$3"}" > "$WORK/mutant.sh"
  if cmp -s "$checker" "$WORK/mutant.sh"; then bad "$1: the mutation did not apply"; return; fi
  ( cd "$FIX" && env TLA_GATE_PHASE=prove SPEC=Model.tla MUST_PASS=Ok.cfg MUST_REFUTE=Bad.cfg:Safe "$BASH_BIN" --noprofile --norc -e -o pipefail "$WORK/mutant.sh" ) > "$OUT" 2>&1
  RC=$?
  expect "$1" 2 "$4"
}
mutant "a holding control that is in fact violated" 'Inv == x \in 0..3' 'Inv == x \in 0..2' 'did not pass the planted model that HOLDS'
mutant "a violated control that in fact holds" 'Inv == x < 3' 'Inv == x < 30' 'cannot refute'
mutant "a judge that always passes" '[ "$1" -eq 0 ] && grep -q '"'"'Model checking completed. No error has been found.'"'"' "$2"' 'true' 'the judge passed the planted VIOLATED model'
mutant "a judge that ignores the invariant name" 'grep -Eq "^Error: Invariant ${inv} is violated(\.|  *by the initial state:?)\$" "$log"' 'true' 'cannot tell invariants apart'
mutant "a judge that wants only the successor-state form" '(\.|  *by the initial state:?)' '\.' 'did not accept TLC'"'"'s initial-state refutation'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
