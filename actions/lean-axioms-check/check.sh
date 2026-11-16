#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the Lean axiom gate for standalone (non-Lake) files. lean compiles
# the listed files, and every `#print axioms` must say the theorem depends on no
# axioms. Generalised from the Lean leg of hvn-dehallucinator's
# scripts/check-recheck-legs.sh (standards PROOF-POLICY section 2); the default
# file list reproduces that leg.
#
# How this differs from proof-runner-check: that action runs `lake build` on a
# Lake project (a lakefile.lean or lakefile.toml) with whatever Lean is on PATH.
# It proves the project builds, and it does not look at axioms: a `sorry` is a
# warning and `lake build` still exits 0. This gate takes plain files that no
# Lake project owns, runs the pinned Lean 4.15.0 on each, and judges the axiom
# report of every printed theorem. Detect ignores .lean files inside a Lake
# project. The two gates do not overlap, and neither stands in for the other.
#
#   LEAN_GATE_PHASE=detect
#       Prints `key=value` facts: lean_files (.lean files in the tree outside
#       any Lake project; build directories pruned), listed (files named in
#       FILES), units (what prove will check; 0 when the tree has no such file
#       and nothing listed exists). Exit 1 when such files exist and FILES
#       names none, or names a file that does not exist.
#
#   LEAN_GATE_PHASE=prove
#       1. Toolchain: lean must be the pinned build (Lean 4.15.0; bin/lean at
#          the pinned SHA-256; the workflow also checks the release archive,
#          lean-4.15.0-linux.tar.zst, against its SHA-256). A mismatch is
#          exit 2: no check was performed.
#       2. Planted controls through the SAME judgement the caller's files get:
#          an axiom-free theorem must be accepted; a sorry, a use of
#          Classical.choice (with propext and Quot.sound), a declared axiom,
#          an ill-typed file and a file with no #print axioms must each be
#          refused. A judge that cannot say no voids every verdict: exit 2.
#       3. Each listed file is compiled standalone with `lean <file>` (imports
#          are limited to the toolchain's own libraries). lean must succeed; the
#          file must contain at least one `#print axioms`; no report may say
#          "depends on axioms" (this catches sorryAx, Classical.choice, propext,
#          Quot.sound and any declared axiom), no `declaration uses 'sorry'`
#          warning may appear, and the number of "does not depend on any axioms"
#          reports must equal the number of prints.
#       4. REQUIRED_THEOREMS (optional, whitespace-separated names): each must
#          appear in some `#print axioms` of a listed file, so a deleted print
#          cannot hide a theorem.
#
# Not covered, by design: a theorem with no #print axioms is not examined.
# Name every theorem that matters in REQUIRED_THEOREMS.
#
# Exit codes: 0 silent, 1 defect, 2 NO CHECK WAS PERFORMED. 2 is never a pass.
#
# Env: WORKING_DIRECTORY (default "."), FILES (default
#      verification/proofs/lean4/Haruspex.lean), REQUIRED_THEOREMS (default
#      none), LEAN_BIN (default lean on PATH; the pin applies to what it
#      resolves to).
set -uo pipefail

PIN_ARCHIVE="lean-4.15.0-linux.tar.zst"
PIN_ARCHIVE_SHA256="af71a2569a9f68337de2434829b3008cd8e32c436e9cb6bd8c84a2c2ba3585c9"
PIN_SHA256="eacf754d25ae86ea076882a34b9444f2485659d9df4266b821443b28ca95a215"
PIN_VERSION_PREFIX="Lean (version 4.15.0, "

phase="${LEAN_GATE_PHASE:?LEAN_GATE_PHASE is required: detect|prove}"
dir="${WORKING_DIRECTORY:-.}"
files_in="${FILES-verification/proofs/lean4/Haruspex.lean}"
required_in="${REQUIRED_THEOREMS-}"
lean_bin="${LEAN_BIN:-lean}"

die2() { echo "::error::lean-axioms-check[$phase]: $* — NO CHECK WAS PERFORMED." >&2; exit 2; }
err()  { echo "::error::lean-axioms-check[$phase]: $*" >&2; }

cd "$dir" 2>/dev/null || die2 "cannot enter $dir"

read -r -a listed <<< "${files_in//$'\n'/ }"
read -r -a required <<< "${required_in//$'\n'/ }"
for i in "${!listed[@]}"; do listed[i]="${listed[$i]#./}"; done
for n in ${required[@]+"${required[@]}"}; do
  [[ "$n" =~ ^[A-Za-z0-9_\']+$ ]] || die2 "required theorem name '$n' is not a plain identifier (letters, digits, _ and ')"
done

# in_lake <file>: 0 when the file, or any directory above it up to the tree
# root, holds a lakefile.lean or lakefile.toml.
in_lake() {
  local d
  d="$(dirname -- "$1")"
  while :; do
    [ -f "$d/lakefile.lean" ] || [ -f "$d/lakefile.toml" ] && return 0
    [ "$d" = . ] && return 1
    d="$(dirname -- "$d")"
  done
}
standalone_lean() {
  local f
  find . \( -name .git -o -name .lake -o -name _build -o -name build -o -name .cicd-suite -o -name node_modules \) -prune -o \
    -type f -name '*.lean' -print | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r f; do
    in_lake "$f" || printf '%s\n' "$f"
  done
}

# ---------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------
if [ "$phase" = detect ]; then
  files="$(standalone_lean)"
  nfiles=0; [ -n "$files" ] && nfiles="$(printf '%s\n' "$files" | grep -c . || true)"
  nlisted="${#listed[@]}"
  missing=""
  for f in ${listed[@]+"${listed[@]}"}; do [ -f "$f" ] || missing="${missing}${f}"$'\n'; done
  nmissing=0; [ -n "$missing" ] && nmissing="$(printf '%s' "$missing" | grep -c . || true)"
  present=$((nlisted - nmissing))
  printf 'lean_files=%s\n' "$nfiles"
  printf 'listed=%s\n' "$nlisted"
  if [ "$nfiles" -eq 0 ] && [ "$present" -eq 0 ]; then
    printf 'units=0\n'; exit 0
  fi
  printf 'units=%s\n' "$nlisted"
  if [ "$nlisted" -eq 0 ]; then
    err "$nfiles standalone .lean file(s) in the tree but the files input names none — the gate has nothing to check. List the files whose theorems must be axiom-free."
    exit 1
  fi
  if [ "$nmissing" -gt 0 ]; then
    err "listed file(s) do not exist — the gate would check less than it claims. Fix the files input:"
    printf '%s' "$missing" | sed 's/^/  missing: /' >&2
    exit 1
  fi
  exit 0
fi

[ "$phase" = prove ] || { echo "::error::lean-axioms-check: unknown phase '$phase' (detect|prove)" >&2; exit 2; }

# ---------------------------------------------------------------------------
# prove
# ---------------------------------------------------------------------------
[ "${#listed[@]}" -gt 0 ] || die2 "the files input names no file. The prove job must only run when detect reported units > 0"

assert_toolchain() {
  local bin real got
  bin="$(command -v "$lean_bin" 2>/dev/null)" || die2 "'$lean_bin' not found; the Lean gate cannot be skipped"
  real="$(readlink -f "$bin")" || die2 "cannot resolve $bin"
  got="$(sha256sum "$real" | cut -d' ' -f1)" || die2 "cannot hash $real"
  [ "$got" = "$PIN_SHA256" ] || die2 "$real has sha256 $got, pinned $PIN_SHA256 (Lean 4.15.0, from $PIN_ARCHIVE sha256 $PIN_ARCHIVE_SHA256). The toolchain is not the pinned one"
  got="$("$bin" --version 2>/dev/null | head -n 1 || true)"
  case "$got" in
    "$PIN_VERSION_PREFIX"*) ;;
    *) die2 "lean --version is '$got', pinned '${PIN_VERSION_PREFIX}...'" ;;
  esac
  echo "toolchain: $real sha256:$PIN_SHA256 ($got)"
  lean_bin="$bin"
}
assert_toolchain

work="$(mktemp -d)" || die2 "cannot create a temp directory"
trap 'rm -rf "$work"' EXIT

DEFECT=""
# judge <file> <log>: 0 when the file compiles and every #print axioms in it
# reports no axioms; 1 with DEFECT set otherwise. The one judgement used for
# both the planted controls and the caller's files.
judge() {
  local src="$1" log="$2" prints clean rc
  DEFECT=""
  rc=0
  "$lean_bin" "$src" > "$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then DEFECT="lean failed on $src (exit $rc)"; return 1; fi
  if grep -q "declaration uses 'sorry'" "$log"; then DEFECT="$src contains a sorry"; return 1; fi
  if grep -q 'depends on axioms' "$log"; then
    DEFECT="a theorem in $src rests on an axiom ($(grep 'depends on axioms' "$log" | head -n 3 | tr '\n' ' '))"; return 1
  fi
  prints="$(grep -o '#print axioms' "$src" | wc -l | tr -d ' ' || true)"
  clean="$(grep -c "does not depend on any axioms$" "$log" || true)"
  if [ "${prints:-0}" -eq 0 ]; then DEFECT="no #print axioms in $src"; return 1; fi
  if [ "$clean" != "$prints" ]; then DEFECT="$clean of $prints reports in $src are axiom-free"; return 1; fi
  return 0
}

# ---- planted controls ------------------------------------------------------
ctl="$work/controls"; mkdir -p "$ctl"
printf 'theorem planted_true : True := trivial\n#print axioms planted_true\n' > "$ctl/True.lean"
printf 'theorem planted_sorry : False := sorry\n#print axioms planted_sorry\n' > "$ctl/Sorry.lean"
printf 'theorem planted_classical (p : Prop) : p ∨ ¬p := Classical.em p\n#print axioms planted_classical\n' > "$ctl/Classical.lean"
printf 'axiom planted_cheat : False\ntheorem planted_axiom : False := planted_cheat\n#print axioms planted_axiom\n' > "$ctl/Axiom.lean"
printf 'theorem planted_ill_typed : False := trivial\n#print axioms planted_ill_typed\n' > "$ctl/IllTyped.lean"
printf 'theorem planted_unprinted : True := trivial\n' > "$ctl/Unprinted.lean"

echo "::group::planted control: an axiom-free theorem must be accepted"
if ! judge "$ctl/True.lean" "$work/true.log"; then
  echo "::endgroup::"; cat "$work/true.log"
  die2 "the planted AXIOM-FREE theorem was refused ($DEFECT). The toolchain is broken, so a red on the caller's files would be misattributed"
fi
echo "::endgroup::"
echo "planted control: axiom-free theorem accepted — the oracle can say yes."
for c in Sorry Classical Axiom IllTyped Unprinted; do
  if judge "$ctl/$c.lean" "$work/$c.log"; then
    die2 "the planted $c control was ACCEPTED. This gate cannot say no; every verdict it gives is VOID"
  fi
  echo "planted control: $c refused ($DEFECT) — the oracle can say no."
done

# ---- the caller's files ----------------------------------------------------
fail=0
for f in "${listed[@]}"; do
  printf '  %-60s ' "$f"
  if [ ! -f "$f" ]; then echo "MISSING"; err "listed file '$f' does not exist"; fail=1; continue; fi
  log="$work/file-$(printf '%s' "$f" | tr '/' '_').log"
  if judge "$f" "$log"; then
    n="$(grep -o '#print axioms' "$f" | wc -l | tr -d ' ' || true)"
    echo "PASS ($n axiom-free)"
  else
    echo "FAIL"
    sed 's/^/        /' "$log" | head -n 40
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
    if grep -Eq "#print axioms[[:space:]]+([^[:space:]]*\.)?${name}([[:space:]]|\$)" "$f"; then found=1; break; fi
  done
  if [ "$found" -eq 0 ]; then err "no axiom report for required theorem '$name'"; fail=1; else nreq=$((nreq+1)); fi
done

[ "$fail" -eq 0 ] || exit 1
echo "lean-axioms-check[prove]: ${#listed[@]} file(s) compile; every #print axioms is axiom-free; $nreq required theorem(s) reported."
exit 0
