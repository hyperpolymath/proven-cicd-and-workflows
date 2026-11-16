#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the Rocq (Coq) recheck gate. coqc compiles the listed files, and
# every `Print Assumptions` must say the theorem is closed. Generalised from
# the Rocq leg of hvn-dehallucinator's scripts/check-recheck-legs.sh (standards
# PROOF-POLICY section 2); the default file list reproduces that leg.
#
#   ROCQ_GATE_PHASE=detect
#       Prints `key=value` facts: rocq_files (.v files in the tree, build
#       directories pruned), listed (files named in FILES), units (what prove
#       will check; 0 when the tree has no .v file and nothing listed exists).
#       Exit 1 when .v files exist and FILES names none, or names a file that
#       does not exist: the gate will not stay green over a list it cannot read.
#
#   ROCQ_GATE_PHASE=prove
#       1. Toolchain: coqc must be the pinned build (Coq 8.18.0, the Ubuntu
#          24.04 package coq 8.18.0+dfsg-1build2, /usr/bin/coqc at the pinned
#          SHA-256). A mismatch is exit 2: no check was performed.
#       2. Planted controls through the SAME judgement the caller's files get:
#          a closed theorem must be accepted; one resting on an Axiom, an
#          Admitted one, an ill-typed one and a file with no Print Assumptions
#          must each be refused. A judge that cannot say no voids every verdict
#          it gives: exit 2.
#       3. Each listed file, in order, in a scratch directory (no .vo or .glob
#          litter in the tree; a dependency must be listed before its
#          dependents): coqc must compile it; it must contain at least one
#          `Print Assumptions`; the number of "Closed under the global context"
#          reports must equal the number of prints (a compile cut short, or a
#          killed one, prints fewer); no report may list Axioms, Opaque
#          constants or Section Variables.
#       4. REQUIRED_THEOREMS (optional, whitespace-separated names): each must
#          appear in some `Print Assumptions` of a listed file, so a deleted
#          print cannot hide a theorem.
#
# Not covered, by design: a theorem with no Print Assumptions is not examined.
# Name every theorem that matters in REQUIRED_THEOREMS.
#
# Exit codes: 0 silent, 1 defect, 2 NO CHECK WAS PERFORMED. 2 is never a pass.
#
# Env: WORKING_DIRECTORY (default "."), FILES (default
#      verification/proofs/coq/Haruspex.v), REQUIRED_THEOREMS (default none),
#      COQC_BIN (default /usr/bin/coqc; the pin applies to what it resolves to).
set -uo pipefail

PIN_PACKAGE="coq"
PIN_PACKAGE_VERSION="8.18.0+dfsg-1build2"
PIN_SHA256="f14ab0c140bdfdb31c7e7e1f20379703973376480a4eea2d43d0fa56ddae03ec"
PIN_VERSION_LINE="The Coq Proof Assistant, version 8.18.0"

phase="${ROCQ_GATE_PHASE:?ROCQ_GATE_PHASE is required: detect|prove}"
dir="${WORKING_DIRECTORY:-.}"
files_in="${FILES-verification/proofs/coq/Haruspex.v}"
required_in="${REQUIRED_THEOREMS-}"
coqc_bin="${COQC_BIN:-/usr/bin/coqc}"

die2() { echo "::error::rocq-check[$phase]: $* — NO CHECK WAS PERFORMED." >&2; exit 2; }
err()  { echo "::error::rocq-check[$phase]: $*" >&2; }

cd "$dir" 2>/dev/null || die2 "cannot enter $dir"

read -r -a listed <<< "${files_in//$'\n'/ }"
read -r -a required <<< "${required_in//$'\n'/ }"
for i in "${!listed[@]}"; do listed[i]="${listed[$i]#./}"; done
for n in ${required[@]+"${required[@]}"}; do
  [[ "$n" =~ ^[A-Za-z0-9_\']+$ ]] || die2 "required theorem name '$n' is not a plain identifier (letters, digits, _ and ')"
done

all_v() {
  find . \( -name .git -o -name _build -o -name build -o -name .cicd-suite -o -name node_modules \) -prune -o \
    -type f -name '*.v' -print | sed 's#^\./##' | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------
if [ "$phase" = detect ]; then
  files="$(all_v)"
  nfiles=0; [ -n "$files" ] && nfiles="$(printf '%s\n' "$files" | grep -c . || true)"
  nlisted="${#listed[@]}"
  missing=""
  for f in ${listed[@]+"${listed[@]}"}; do [ -f "$f" ] || missing="${missing}${f}"$'\n'; done
  nmissing=0; [ -n "$missing" ] && nmissing="$(printf '%s' "$missing" | grep -c . || true)"
  present=$((nlisted - nmissing))
  printf 'rocq_files=%s\n' "$nfiles"
  printf 'listed=%s\n' "$nlisted"
  if [ "$nfiles" -eq 0 ] && [ "$present" -eq 0 ]; then
    printf 'units=0\n'; exit 0
  fi
  printf 'units=%s\n' "$nlisted"
  if [ "$nlisted" -eq 0 ]; then
    err "$nfiles .v file(s) in the tree but the files input names none — the gate has nothing to check. List the files whose theorems must be closed."
    exit 1
  fi
  if [ "$nmissing" -gt 0 ]; then
    err "listed file(s) do not exist — the gate would check less than it claims. Fix the files input:"
    printf '%s' "$missing" | sed 's/^/  missing: /' >&2
    exit 1
  fi
  exit 0
fi

[ "$phase" = prove ] || { echo "::error::rocq-check: unknown phase '$phase' (detect|prove)" >&2; exit 2; }

# ---------------------------------------------------------------------------
# prove
# ---------------------------------------------------------------------------
[ "${#listed[@]}" -gt 0 ] || die2 "the files input names no file. The prove job must only run when detect reported units > 0"

assert_toolchain() {
  local bin real got pkg
  bin="$(command -v "$coqc_bin" 2>/dev/null)" || die2 "'$coqc_bin' not found; the Rocq gate cannot be skipped"
  real="$(readlink -f "$bin")" || die2 "cannot resolve $bin"
  got="$(sha256sum "$real" | cut -d' ' -f1)" || die2 "cannot hash $real"
  [ "$got" = "$PIN_SHA256" ] || die2 "$real has sha256 $got, pinned $PIN_SHA256 (Coq 8.18.0, $PIN_PACKAGE $PIN_PACKAGE_VERSION). The toolchain is not the pinned one"
  command -v dpkg-query >/dev/null 2>&1 || die2 "dpkg-query is unavailable; the pinned package $PIN_PACKAGE $PIN_PACKAGE_VERSION cannot be confirmed"
  pkg="$(dpkg-query -W -f='${Version}' "$PIN_PACKAGE" 2>/dev/null || true)"
  [ "$pkg" = "$PIN_PACKAGE_VERSION" ] || die2 "package $PIN_PACKAGE is '${pkg:-absent}', pinned $PIN_PACKAGE_VERSION"
  got="$("$bin" --version 2>/dev/null | head -n 1 || true)"
  [ "$got" = "$PIN_VERSION_LINE" ] || die2 "coqc --version is '$got', pinned '$PIN_VERSION_LINE'"
  echo "toolchain: $real sha256:$PIN_SHA256 ($PIN_VERSION_LINE, $PIN_PACKAGE $pkg)"
  coqc_bin="$bin"
}
assert_toolchain

work="$(mktemp -d)" || die2 "cannot create a temp directory"
trap 'rm -rf "$work"' EXIT

DEFECT=""
# judge <source-file> <scratch-dir>: 0 when the file compiles and every
# Print Assumptions in it is closed; 1 with DEFECT set otherwise. The one
# judgement used for both the planted controls and the caller's files.
judge() {
  local src="$1" scratch="$2" base prints closed log rc
  DEFECT=""
  base="$(basename -- "$src")"
  mkdir -p "$scratch"
  cp -- "$src" "$scratch/$base"
  log="$scratch/$base.log"
  rc=0
  (cd "$scratch" && "$coqc_bin" "$base") > "$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then DEFECT="coqc failed on $src (exit $rc)"; return 1; fi
  prints="$(grep -o 'Print Assumptions' "$src" | wc -l | tr -d ' ' || true)"
  closed="$(grep -c '^Closed under the global context$' "$log" || true)"
  if grep -Eq '^(Axioms|Opaque constants|Section Variables):' "$log"; then
    DEFECT="a theorem in $src rests on an assumption"; return 1
  fi
  if [ "${prints:-0}" -eq 0 ]; then DEFECT="no Print Assumptions in $src"; return 1; fi
  if [ "$closed" != "$prints" ]; then DEFECT="$closed of $prints reports in $src are closed"; return 1; fi
  return 0
}

# ---- planted controls ------------------------------------------------------
ctl="$work/controls"; mkdir -p "$ctl"
printf 'Lemma planted_true : True.\nProof. exact I. Qed.\nPrint Assumptions planted_true.\n' > "$ctl/True.v"
printf 'Axiom cheat : False.\nLemma planted_axiom : False.\nProof. exact cheat. Qed.\nPrint Assumptions planted_axiom.\n' > "$ctl/Axiom.v"
printf 'Lemma planted_admitted : False.\nProof. Admitted.\nPrint Assumptions planted_admitted.\n' > "$ctl/Admitted.v"
printf 'Lemma planted_ill_typed : False.\nProof. exact I. Qed.\nPrint Assumptions planted_ill_typed.\n' > "$ctl/IllTyped.v"
printf 'Lemma planted_unprinted : True.\nProof. exact I. Qed.\n' > "$ctl/Unprinted.v"

echo "::group::planted control: a closed theorem must be accepted"
if ! judge "$ctl/True.v" "$work/s-true"; then
  echo "::endgroup::"; cat "$work/s-true/True.v.log" 2>/dev/null
  die2 "the planted CLOSED theorem was refused ($DEFECT). The toolchain is broken, so a red on the caller's files would be misattributed"
fi
echo "::endgroup::"
echo "planted control: closed theorem accepted — the oracle can say yes."
for c in Axiom Admitted IllTyped Unprinted; do
  if judge "$ctl/$c.v" "$work/s-$c"; then
    die2 "the planted $c control was ACCEPTED. This gate cannot say no; every verdict it gives is VOID"
  fi
  echo "planted control: $c refused ($DEFECT) — the oracle can say no."
done

# ---- the caller's files ----------------------------------------------------
fail=0
for f in "${listed[@]}"; do
  printf '  %-60s ' "$f"
  if [ ! -f "$f" ]; then echo "MISSING"; err "listed file '$f' does not exist"; fail=1; continue; fi
  if judge "$f" "$work/files"; then
    n="$(grep -o 'Print Assumptions' "$f" | wc -l | tr -d ' ' || true)"
    echo "PASS ($n closed)"
  else
    echo "FAIL"
    sed 's/^/        /' "$work/files/$(basename -- "$f").log" | head -n 40
    err "$DEFECT"
    fail=1
  fi
done

# ---- required theorems -----------------------------------------------------
nreq=0
for name in ${required[@]+"${required[@]}"}; do
  found=0
  for f in "${listed[@]}"; do
    [ -f "$f" ] || continue
    if grep -Eq "Print Assumptions[[:space:]]+([A-Za-z0-9_']+\.)*${name}[[:space:]]*\.([[:space:]]|\$)" "$f"; then found=1; break; fi
  done
  if [ "$found" -eq 0 ]; then err "no assumption report for required theorem '$name'"; fail=1; else nreq=$((nreq+1)); fi
done

[ "$fail" -eq 0 ] || exit 1
echo "rocq-check[prove]: ${#listed[@]} file(s) compile; every Print Assumptions is closed; $nreq required theorem(s) reported."
exit 0
