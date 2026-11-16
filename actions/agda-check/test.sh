#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test.sh — the Agda gate must fail for each thing it claims to check, under the
# exact composite shell. This test runs the REAL pinned Agda (the gate refuses
# any other binary, so a stand-in prover is not possible); a missing or wrong
# Agda is exit 2, never a skip. Fixtures are planted one defect at a time:
#   a fixture Agda accepts, a scope error instead of a type error, a refusal
#   away from the marked line, no marked line, an empty reject set, an unlisted
#   module, a stale entry, a gated module that fails, a quarantined module that
#   starts to pass, a mistyped status, a missing MANIFEST, a stray source,
#   a failing sibling script, and a wrong binary.
# Then mutants of check.sh itself: each planted control, made vacuous, must make
# the gate refuse (exit 2) rather than report green.
#
# Ported from hvn-dehallucinator's tests/proofs/agda_kernel_gate_test.sh.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$here/check.sh"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v agda >/dev/null 2>&1 || { echo "agda-check/test.sh: agda is not installed — NO CHECK WAS PERFORMED." >&2; exit 2; }
BASH_BIN="$(command -v bash)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"
FIX="$WORK/fixture"

prelude() { # prelude <Module>
  printf '{-# OPTIONS --safe --without-K --cubical-compatible #-}\nmodule %s where\n\n' "$1"
  printf 'data Nat : Set where\n  zero : Nat\n  suc  : Nat → Nat\n\n'
  printf 'data _≡_ {A : Set} (x : A) : A → Set where\n  refl : x ≡ x\n\n'
}
good_module() { { prelude "$1"; printf 'ok : suc zero ≡ suc zero\nok = refl\n'; } > "$2"; }
reject_module() { { prelude "$1"; printf 'bad : suc zero ≡ zero\nbad = refl   -- refused here\n'; } > "$2"; }

fresh_fixture() {
  rm -rf "$FIX"; mkdir -p "$FIX/verification/proofs/agda" "$FIX/tests/reject"
  good_module Good "$FIX/verification/proofs/agda/Good.agda"
  printf 'verification/proofs/agda|Good.agda|gated| the one true module\n' > "$FIX/verification/proofs/agda/MANIFEST"
  reject_module Bad "$FIX/tests/reject/Bad.agda"
}
# run_phase <phase> [VAR=value ...]; the default inputs are the gate's own, and
# the fixture has no siblings, so the sibling script is switched off.
run_phase() {
  local phase="$1"; shift
  ( cd "$FIX" && env AGDA_GATE_PHASE="$phase" SIBLINGS_SCRIPT= "$@" "$BASH_BIN" --noprofile --norc -e -o pipefail "$checker" ) > "$OUT" 2>&1
  RC=$?
}
expect() { # expect <name> <want-rc> <text>
  if [ "$RC" -eq "$2" ] && grep -qF -- "$3" "$OUT"; then ok "$1 (exit $RC)"; else bad "$1: want exit $2 and \"$3\", got exit $RC"; sed 's/^/        /' "$OUT" | tail -n 15; fi
}

echo "== positive control: a clean tree passes =="
fresh_fixture
run_phase detect
expect "detect on a clean tree" 0 'units=3'
grep -qx 'agda_files=2' "$OUT" && ok "detect counts the .agda files" || bad "agda_files wrong: $(cat "$OUT")"
run_phase prove
expect "prove on a clean tree" 0 'agda-check[prove]: 1 gated module(s) check'
grep -q 'false module refused on its marked line' "$OUT" && ok "the false planted control was exercised" || bad "no false control"
grep -q 'true module accepted' "$OUT" && ok "the true planted control was exercised" || bad "no true control"
grep -q 'postulate refused under --safe' "$OUT" && ok "the --safe planted control was exercised" || bad "no safe control"
grep -q 'refused Bad at Bad.agda:' "$OUT" && ok "the reject fixture is refused at its marked line" || bad "reject fixture not reported"

echo "== negative controls (each must fail the gate) =="
fresh_fixture
good_module Accepted "$FIX/tests/reject/Accepted.agda"; printf -- '-- refused here\n' >> "$FIX/tests/reject/Accepted.agda"
run_phase prove
expect "a reject fixture Agda accepts" 1 'invalid proof accepted: Accepted'

fresh_fixture
{ prelude Scope; printf 'bad : Disagreeing-typo\nbad = refl   -- refused here\n'; } > "$FIX/tests/reject/Scope.agda"
run_phase prove
expect "a reject fixture refused for a scope error, not a type error" 1 'unexpected failure while checking Scope'

fresh_fixture
{ prelude Offmark; printf 'bad : (n : Nat) → n ≡ zero\nbad (suc n) = refl\nbad zero    = refl   -- refused here\n'; } > "$FIX/tests/reject/Offmark.agda"
run_phase prove
expect "a reject fixture refused away from its marked line" 1 'not at its marked line'

fresh_fixture
{ prelude Nomark; printf 'bad : suc zero ≡ zero\nbad = refl\n'; } > "$FIX/tests/reject/Nomark.agda"
run_phase prove
expect "a reject fixture with no marked line" 1 "must mark exactly one line '-- refused here'"

fresh_fixture
rm -f "$FIX/tests/reject/Bad.agda"
run_phase prove
expect "an empty reject set" 1 'no expected-rejection modules'

fresh_fixture
run_phase prove REJECT_DIR=
expect "reject_dir switched off checks the positive set only" 0 '0 expected rejection(s) refused'

fresh_fixture
good_module Orphan "$FIX/verification/proofs/agda/Orphan.agda"
run_phase prove
expect "a .agda file the MANIFEST does not list" 1 'absent from verification/proofs/agda/MANIFEST'
grep -q 'unlisted: verification/proofs/agda/Orphan.agda' "$OUT" && ok "the unlisted file is named" || bad "unlisted file not named"

fresh_fixture
printf 'verification/proofs/agda|Ghost.agda|gated| not there\n' >> "$FIX/verification/proofs/agda/MANIFEST"
run_phase prove
expect "a MANIFEST entry whose file does not exist" 1 'stale entry'

fresh_fixture
{ prelude Broken; printf 'ok : suc zero ≡ zero\nok = refl\n'; } > "$FIX/verification/proofs/agda/Broken.agda"
printf 'verification/proofs/agda|Broken.agda|gated| must check\n' >> "$FIX/verification/proofs/agda/MANIFEST"
run_phase prove
expect "a gated module that does not check" 1 "gated module 'verification/proofs/agda/Broken.agda' does not check"

fresh_fixture
{ prelude Broken; printf 'ok : suc zero ≡ zero\nok = refl\n'; } > "$FIX/verification/proofs/agda/Broken.agda"
printf 'verification/proofs/agda|Broken.agda|quarantine| known broken\n' >> "$FIX/verification/proofs/agda/MANIFEST"
run_phase prove
expect "a quarantined module that still fails is expected" 0 '1 quarantined still fail'
good_module Broken "$FIX/verification/proofs/agda/Broken.agda"
run_phase prove
expect "a quarantined module that starts to check" 1 'UNEXPECTED'

fresh_fixture
printf 'verification/proofs/agda|Good.agda|gate| typo\n' > "$FIX/verification/proofs/agda/MANIFEST"
run_phase prove
expect "a mistyped MANIFEST status" 1 "must be 'gated' or 'quarantine'"

fresh_fixture
rm -f "$FIX/verification/proofs/agda/MANIFEST"
run_phase detect
expect "detect: .agda files and no MANIFEST" 1 'no MANIFEST'

fresh_fixture
good_module Stray "$FIX/Stray.agda"
run_phase detect
expect "detect: a .agda file outside every configured directory" 1 'stray: Stray.agda'
run_phase detect INCLUDE_DIRS=.
expect "detect: the include directories cover it" 0 'units='

echo "== siblings =="
fresh_fixture
mkdir -p "$FIX/scripts"
printf '#!/usr/bin/env bash\nexit 7\n' > "$FIX/scripts/fetch-siblings.sh"
run_phase prove SIBLINGS_SCRIPT=scripts/fetch-siblings.sh
expect "a failing siblings script is exit 2" 2 'NO CHECK WAS PERFORMED'
run_phase prove SIBLINGS_SCRIPT=scripts/absent.sh
expect "a named siblings script that is absent is exit 2" 2 'does not exist'
mkdir -p "$FIX/dep-src"
good_module Dep "$FIX/dep-src/Dep.agda"
printf '{-# OPTIONS --safe --without-K --cubical-compatible #-}\nmodule UsesDep where\nopen import Dep\n' > "$FIX/verification/proofs/agda/UsesDep.agda"
printf 'verification/proofs/agda|UsesDep.agda|gated| imports a sibling\n' >> "$FIX/verification/proofs/agda/MANIFEST"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/scripts/fetch-siblings.sh"
run_phase prove SIBLINGS_SCRIPT=scripts/fetch-siblings.sh SIBLINGS_INCLUDE_GLOB='dep-*'
expect "a sibling on the include glob is found" 0 '2 gated module(s) check'
run_phase prove SIBLINGS_SCRIPT=scripts/fetch-siblings.sh SIBLINGS_INCLUDE_GLOB='nothing-*'
expect "without the sibling on the path the import fails" 1 'UsesDep.agda'
run_phase prove INCLUDE_DIRS='verification/proofs/agda dep-src'
expect "include_dirs puts an extra directory on the path" 0 '2 gated module(s) check'

echo "== toolchain pin =="
fresh_fixture
mkdir -p "$WORK/fake"
printf '#!/usr/bin/env bash\necho "Agda version 2.6.3"\n' > "$WORK/fake/agda"; chmod +x "$WORK/fake/agda"
run_phase prove AGDA_BIN="$WORK/fake/agda"
expect "a binary that is not the pinned build is exit 2" 2 'pinned 852806142a15951f667df303c73cfce5f4123218ce6e1f1b29acaddc242af00d'
run_phase prove AGDA_BIN="$WORK/fake/absent"
expect "an absent binary is exit 2" 2 'not found'
rm -rf "$FIX/verification" "$FIX/tests"
run_phase prove
expect "prove with nothing to check is exit 2, not green" 2 'NO CHECK WAS PERFORMED'
run_phase detect
expect "detect on a tree with no Agda is silent success" 0 'units=0'

echo "== mutants of check.sh: a vacuous planted control must be refused =="
fresh_fixture
mutant() { # mutant <label> <sed-script> <want-text>
  sed "$2" "$checker" > "$WORK/mutant.sh"
  if cmp -s "$checker" "$WORK/mutant.sh"; then bad "$1: the mutation did not apply"; return; fi
  ( cd "$FIX" && env AGDA_GATE_PHASE=prove SIBLINGS_SCRIPT= "$BASH_BIN" --noprofile --norc -e -o pipefail "$WORK/mutant.sh" ) > "$OUT" 2>&1
  RC=$?
  expect "$1" 2 "$3"
}
mutant "a false control that is in fact true" 's/^one-is-zero : suc zero ≡ zero$/one-is-zero : suc zero ≡ suc zero/' 'ACCEPTED the planted FALSE module'
mutant "a true control that is in fact false" 's/^one-is-one : suc zero ≡ suc zero$/one-is-one : suc zero ≡ zero/' 'could not check the planted TRUE module'
mutant "a postulate control that is not a postulate" 's/^postulate cheat : ⊥$/cheat : Set/' 'did not refuse a postulate under --safe'
mutant "a false control with no marked line" 's/^one-is-zero = refl   -- refused here$/one-is-zero = refl/' 'not as a type error on its marked line'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
