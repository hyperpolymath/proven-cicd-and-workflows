#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The prover-gate detectors in rollout_language_gates.sh, both ways: a tree the
# gate belongs to is detected, and a tree it does not belong to is not. Pathnames
# with spaces must survive; Verilog `.v` files must not select the Rocq gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
fns="$WORK/fns.sh"
awk '/^# Trees the prover gates never look in/{p=1} p{print} p&&/^has_lean\(\)/{l=1} l&&/^}$/{exit}' "$ROOT/rollout_language_gates.sh" > "$fns"
[ -s "$fns" ] || { echo "cannot extract the detectors — NO CHECK WAS PERFORMED"; exit 2; }
# shellcheck disable=SC1090
source "$fns"
T="$WORK/estate clones"
mkdir -p "$T"/{plainrocq,coqfrom,coqqual,ver1,ver2,agda,tla,lean,lakelean,empty,builddir}
printf 'Require Coq.Init.Logic.\nDefinition witness : True := I.\nPrint Assumptions witness.\n' > "$T/plainrocq/w.v"
printf 'From Coq Require Import List.\nLemma foo : True. Proof. exact I. Qed.\n' > "$T/coqfrom/c.v"
printf 'Require Import Setoid.\n' > "$T/coqqual/q.v"
printf '// Definition of the interface\n// Theorem 1 states the bound.\n/* Require the clock */\nmodule top(input a);\nendmodule\n' > "$T/ver1/t.v"
printf 'Definition of the interface.\nLemma named below holds.\nTheorem one.\nmodule x();\nendmodule\n' > "$T/ver2/t.v"
echo 'module M where' > "$T/agda/M.agda"
echo '---- MODULE M ----' > "$T/tla/M.tla"
echo 'theorem t : True := trivial' > "$T/lean/T.lean"
mkdir -p "$T/lakelean/sub"; echo 'package p' > "$T/lakelean/lakefile.lean"; echo 'theorem t : True := trivial' > "$T/lakelean/sub/T.lean"
mkdir -p "$T/builddir/_build"; echo 'module Q where' > "$T/builddir/_build/Q.agda"
want() { # want <name> <detector> <dir> <yes|no>
  local got=no
  if "$2" "$T/$3"; then got=yes; fi
  if [ "$got" = "$4" ]; then printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); else printf '  FAIL %s: want %s, got %s\n' "$1" "$4" "$got"; FAIL=$((FAIL+1)); fi
}
want "plain Require, Definition and Print Assumptions in a path with a space" has_rocq plainrocq yes
want "From ... Require and a Lemma with Qed" has_rocq coqfrom yes
want "a lone Require Import" has_rocq coqqual yes
want "Verilog with prose comments is not Coq" has_rocq ver1 no
want "Verilog with Coq-looking prose and endmodule is not Coq" has_rocq ver2 no
want "an empty tree is not Coq" has_rocq empty no
want "a .agda file" has_agda agda yes
want "an .agda file only under _build is not counted" has_agda builddir no
want "a .tla file" has_tla tla yes
want "a standalone .lean file" has_lean lean yes
want "a .lean file inside a Lake project is not counted" has_lean lakelean no
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
