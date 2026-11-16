#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the Rocq (Coq) gate. coqc compiles the listed files; coqchk, a
# separate program, re-checks the compiled .vo files and reports every axiom,
# admitted lemma and disabled check in them. Generalised from the Rocq leg of
# hvn-dehallucinator's scripts/check-recheck-legs.sh (standards PROOF-POLICY
# section 2); the default file list reproduces that leg.
#
# Trust model. The verdict is made OUT OF PROCESS on the compiled artefact, never
# from text the caller's file can print. A .v file can run commands at compile
# time and can rename or hide anything coqc prints (a Notation can make `Check`
# print the exact line "Closed under the global context"), so coqc's output and
# the file's `Print Assumptions` lines are not evidence and are not read. coqchk's
# own summary is read instead. What stays trusted: the pinned coqc and coqchk
# binaries, and the runner. Code the file runs at compile time can touch the
# filesystem; that is outside this gate's model.
#
#   ROCQ_GATE_PHASE=detect
#       Prints `key=value` facts: rocq_files (.v files in the tree, build
#       directories pruned), listed (files named in FILES), units (what prove
#       will check; 0 when the tree has no .v file and nothing listed exists).
#       Exit 1 when .v files exist and FILES names none, or names a file that
#       does not exist: the gate will not stay green over a list it cannot read.
#
#   ROCQ_GATE_PHASE=prove
#       1. Toolchain: coqc and coqchk must be the pinned build (Coq 8.18.0, the
#          Ubuntu 24.04 package coq 8.18.0+dfsg-1build2, /usr/bin/coqc and
#          /usr/bin/coqchk at their pinned SHA-256). A mismatch is exit 2.
#       2. Planted controls through the SAME judgement the caller's files get.
#          Accepted: a closed theorem, and one with no Print Assumptions at all.
#          Refused: an Axiom, an Admitted lemma, a Parameter, an ill-typed file,
#          `Unset Guard Checking` with a non-terminating fixpoint, `Unset
#          Universe Checking` (type-in-type), `Unset Positivity Checking`, and a
#          Notation forge that makes `Check` print the closed-context line over a
#          real Axiom. A judge that cannot say no voids every verdict: exit 2.
#       3. The listed files, in order, in a scratch directory (no .vo or .glob
#          litter in the tree; a dependency must be listed before its dependents):
#          coqc must compile each; then `coqchk -o` re-checks every module and its
#          whole Require closure, and its CONTEXT SUMMARY must list no axiom (an
#          Admitted lemma is one), no constant relying on type-in-type or on
#          unsafe (co)fixpoints, and no inductive whose positivity is assumed.
#          Module-wide: a theorem needs no `Print Assumptions` to be covered. The
#          summary is parsed strictly; a summary that is not in the expected shape
#          is exit 2. Axioms of the Require closure count, used or not.
#       4. ALLOWED_AXIOMS (whitespace-separated full names as coqchk prints them,
#          default none) are not counted as axioms.
#       5. REQUIRED_THEOREMS (whitespace-separated names, default none): each
#          must resolve to a constant of a listed module. The gate compiles a file
#          of its own (`Require M.` and `Definition __gate_req := @M.<name>.`) and
#          judges by the EXIT CODE alone. A name resolving to an abbreviation
#          counts as existing. Existence is all this checks; axioms are judged by
#          coqchk for the whole module.
#
# Exit codes: 0 silent, 1 defect, 2 NO CHECK WAS PERFORMED. 2 is never a pass.
#
# Env: WORKING_DIRECTORY (default "."), FILES (default
#      verification/proofs/coq/Haruspex.v), REQUIRED_THEOREMS (default none),
#      ALLOWED_AXIOMS (default none), COQC_BIN (default /usr/bin/coqc) and
#      COQCHK_BIN (default /usr/bin/coqchk); each pin applies to what the path
#      resolves to.
set -uo pipefail

PIN_PACKAGE="coq"
PIN_PACKAGE_VERSION="8.18.0+dfsg-1build2"
PIN_SHA256="f14ab0c140bdfdb31c7e7e1f20379703973376480a4eea2d43d0fa56ddae03ec"
PIN_VERSION_LINE="The Coq Proof Assistant, version 8.18.0"
PIN_CHK_SHA256="788a7a87e176bfd4a8820f76871efaa087a052d68447d8f129bcdf15c6c7ac87"
PIN_CHK_VERSION_LINE="The Coq Proof Checker, version 8.18.0"

phase="${ROCQ_GATE_PHASE:?ROCQ_GATE_PHASE is required: detect|prove}"
dir="${WORKING_DIRECTORY:-.}"
files_in="${FILES-verification/proofs/coq/Haruspex.v}"
required_in="${REQUIRED_THEOREMS-}"
allowed_in="${ALLOWED_AXIOMS-}"
coqc_bin="${COQC_BIN:-/usr/bin/coqc}"
coqchk_bin="${COQCHK_BIN:-/usr/bin/coqchk}"

die2() { echo "::error::rocq-check[$phase]: $* — NO CHECK WAS PERFORMED." >&2; exit 2; }
err()  { echo "::error::rocq-check[$phase]: $*" >&2; }

cd "$dir" 2>/dev/null || die2 "cannot enter $dir"

read -r -a listed <<< "${files_in//$'\n'/ }"
read -r -a required <<< "${required_in//$'\n'/ }"
read -r -a allowed <<< "${allowed_in//$'\n'/ }"
for i in "${!listed[@]}"; do listed[i]="${listed[$i]#./}"; done
for n in ${required[@]+"${required[@]}"} ${allowed[@]+"${allowed[@]}"}; do
  [[ "$n" =~ ^[A-Za-z_]([A-Za-z0-9_\'.]*[A-Za-z0-9_\'])?$ ]] || die2 "name '$n' is not an identifier (letters, digits, _ and ', with inner dots for a qualified name)"
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

assert_tool() { # <label> <path-var-name> <pinned sha> <version-line>; echoes the resolved path
  local label="$1" path="$2" pin="$3" want="$4" bin real got
  bin="$(command -v "$path" 2>/dev/null)" || die2 "'$path' not found; the Rocq gate cannot be skipped"
  real="$(readlink -f "$bin")" || die2 "cannot resolve $bin"
  got="$(sha256sum "$real" | cut -d' ' -f1)" || die2 "cannot hash $real"
  [ "$got" = "$pin" ] || die2 "$real has sha256 $got, pinned $pin (Coq 8.18.0, $PIN_PACKAGE $PIN_PACKAGE_VERSION). The $label is not the pinned one"
  got="$("$bin" --version 2>/dev/null | head -n 1 || true)"
  [ "$got" = "$want" ] || die2 "$label --version is '$got', pinned '$want'"
  echo "toolchain: $real sha256:$pin ($want)" >&2
  printf '%s' "$bin"
}
command -v dpkg-query >/dev/null 2>&1 || die2 "dpkg-query is unavailable; the pinned package $PIN_PACKAGE $PIN_PACKAGE_VERSION cannot be confirmed"
pkg="$(dpkg-query -W -f='${Version}' "$PIN_PACKAGE" 2>/dev/null || true)"
[ "$pkg" = "$PIN_PACKAGE_VERSION" ] || die2 "package $PIN_PACKAGE is '${pkg:-absent}', pinned $PIN_PACKAGE_VERSION"
coqc_bin="$(assert_tool coqc "$coqc_bin" "$PIN_SHA256" "$PIN_VERSION_LINE")" || exit 2
coqchk_bin="$(assert_tool coqchk "$coqchk_bin" "$PIN_CHK_SHA256" "$PIN_CHK_VERSION_LINE")" || exit 2

work="$(mktemp -d)" || die2 "cannot create a temp directory"
trap 'rm -rf "$work"' EXIT

DEFECT=""
DEFECT_KIND=""   # compile | check
# parse_summary <coqchk log> <out file>: write "<section><TAB><name>" rows. Exit 2
# when the log does not have the exact shape coqchk 8.18.0 prints: the verdict
# must never rest on text the gate did not understand.
parse_summary() {
  local log="$1" out="$2"
  awk -v out="$out" '
    BEGIN { insum = 0; sec = ""; seen["axioms"] = 0; seen["tit"] = 0; seen["unsafe"] = 0; seen["pos"] = 0; theory = 0; bad = 0 }
    /^CONTEXT SUMMARY$/ { insum = 1; next }
    !insum { next }
    /^=+$/ { next }
    /^[[:space:]]*$/ { next }
    /^\* Theory: Set is predicative$/ { theory = 1; next }
    /^\* Axioms:( <none>)?$/ { sec = "axioms"; seen[sec] = 1; next }
    /^\* Constants\/Inductives relying on type-in-type:( <none>)?$/ { sec = "tit"; seen[sec] = 1; next }
    /^\* Constants\/Inductives relying on unsafe \(co\)fixpoints:( <none>)?$/ { sec = "unsafe"; seen[sec] = 1; next }
    /^\* Inductives whose positivity is assumed:( <none>)?$/ { sec = "pos"; seen[sec] = 1; next }
    /^    [^[:space:]]+$/ { if (sec == "") bad = 1; else { sub(/^    /, ""); print sec "\t" $0 > out } next }
    { bad = 1 }
    END { if (!insum || !theory || bad || !seen["axioms"] || !seen["tit"] || !seen["unsafe"] || !seen["pos"]) exit 3 }
  ' "$log" || return 3
  [ -e "$out" ] || : > "$out"
}

# The axioms a judged set may use. The planted controls are judged with NONE,
# whatever the caller allows; the caller's files are judged with ALLOWED_AXIOMS.
JUDGE_ALLOWED=()
is_allowed() { local a; for a in ${JUDGE_ALLOWED[@]+"${JUDGE_ALLOWED[@]}"}; do [ "$a" = "$1" ] && return 0; done; return 1; }

# text_refusal <file>: print why the file uses a form that can hide something
# from coqchk's summary; print nothing when it does not. Refusing is the safe
# direction: no forgery can turn a refusal into a pass. The scan is of the raw
# text, comments included, so a mention in a comment is refused too (false
# refusals are accepted; false passes are not). Newlines count as spaces.
#   - a module type ascription (`Module M : S`, `Module M <: S`) and a functor
#     (`Module F (X : T)`): coqchk checks their bodies but its summary does not
#     report an axiom in an uninstantiated functor body, or an unsafe fixpoint
#     hidden by sealing;
#   - Unset Guard Checking, Unset Positivity Checking, Unset Universe Checking
#     and #[bypass_check(...)]: the unsealed forms are caught by coqchk, and a
#     hidden one must not be left to a summary that cannot see it;
#   - Load, Add LoadPath, Add ML Path, Declare ML Module: commands this scan
#     cannot see would run.
text_refusal() {
  local flat id="[A-Za-z_][^[:space:](:<.]*" pre="(^|[^A-Za-z0-9_'])"
  flat="$(tr '\n\r\t' '   ' < "$1")"
  if grep -Eq "${pre}Module[[:space:]]+((Import|Export)[[:space:]]+)?${id}[[:space:]]*\\(" <<< "$flat"; then
    echo "a functor (Module F (X : T)): its body is not covered by coqchk's summary. Refused fail-closed"; return 0
  fi
  if grep -Eq "${pre}Module[[:space:]]+((Import|Export)[[:space:]]+)?${id}[[:space:]]*(:|<:)" <<< "$flat"; then
    echo "a module type ascription (Module M : S / <: S): sealing hides the implementation from coqchk's summary. Refused fail-closed"; return 0
  fi
  if grep -Eq "${pre}(Unset[[:space:]]+(Guard|Positivity|Universe)[[:space:]]+Checking|bypass_check)" <<< "$flat"; then
    echo "Unset Guard/Positivity/Universe Checking or #[bypass_check]: refused fail-closed"; return 0
  fi
  if grep -Eq "${pre}(Load[[:space:]]|Add[[:space:]]+(Rec[[:space:]]+)?(LoadPath|ML[[:space:]]+Path)|Declare[[:space:]]+ML[[:space:]]+Module)" <<< "$flat"; then
    echo "Load, Add LoadPath, Add ML Path or Declare ML Module: code this scan cannot see would run. Refused fail-closed"; return 0
  fi
}

# judge_set <scratch> <file>...: 0 when every file compiles, coqchk accepts the
# modules, and its summary lists nothing disallowed; 1 with DEFECT and
# DEFECT_KIND set otherwise. The one judgement for the planted controls and for
# the caller's files. Nothing coqc prints is read.
judge_set() {
  local scratch="$1" f base mod rc mods=() seen=" " rows axioms tit unsafe pos a sec name why
  shift
  DEFECT=""; DEFECT_KIND=""
  mkdir -p "$scratch"
  for f in "$@"; do
    base="$(basename -- "$f")"; mod="${base%.v}"
    case "$seen" in *" $base "*) DEFECT="two listed files are named $base; their modules would collide"; DEFECT_KIND=compile; return 1 ;; esac
    seen="$seen$base "
    cp -- "$f" "$scratch/$base"
    rc=0
    (cd "$scratch" && "$coqc_bin" "$base") > "$scratch/$base.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then DEFECT="coqc failed on $f (exit $rc)"; DEFECT_KIND=compile; return 1; fi
    mods+=("$mod")
  done
  rc=0
  (cd "$scratch" && "$coqchk_bin" -o "${mods[@]}") > "$scratch/coqchk.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then DEFECT="coqchk rejected ${mods[*]} (exit $rc)"; DEFECT_KIND=check; return 1; fi
  rows="$scratch/summary.tsv"; rm -f "$rows"
  parse_summary "$scratch/coqchk.log" "$rows" || { sed 's/^/        /' "$scratch/coqchk.log" | tail -n 30 >&2; die2 "coqchk's summary is not in the expected shape"; }
  axioms=""; tit=""; unsafe=""; pos=""
  while IFS=$'\t' read -r sec name; do
    case "$sec" in
      axioms) if is_allowed "$name"; then continue; fi; axioms="$axioms $name" ;;
      tit) tit="$tit $name" ;;
      unsafe) unsafe="$unsafe $name" ;;
      pos) pos="$pos $name" ;;
    esac
  done < "$rows"
  DEFECT=""
  [ -z "$axioms" ] || DEFECT="$DEFECT coqchk reports axiom(s) (an Admitted lemma is one):$axioms;"
  [ -z "${tit:-}" ] || DEFECT="$DEFECT constants relying on type-in-type:${tit};"
  [ -z "${unsafe:-}" ] || DEFECT="$DEFECT constants relying on unsafe (co)fixpoints (guard checking was off):${unsafe};"
  [ -z "${pos:-}" ] || DEFECT="$DEFECT inductives whose positivity is assumed:${pos};"
  a="$DEFECT"
  if [ -n "$a" ]; then DEFECT="${a# }"; DEFECT_KIND=check; return 1; fi
  # coqchk's summary is built from the final environment. It does not see an
  # axiom inside a functor body that is never instantiated, nor an unsafe
  # fixpoint hidden by a sealed module (`Module M : S`). A text rule closes them
  # fail-closed: refusing can never turn into a pass.
  for f in "$@"; do
    why="$(text_refusal "$f")"
    if [ -n "$why" ]; then DEFECT="$f: $why"; DEFECT_KIND=text; return 1; fi
  done
  return 0
}

# resolves <scratch> <module> <name>...: 0 when the gate's own file, which only
# requires the module and takes `@Module.name` of each name, compiles. Judged by
# exit code alone.
# The probe module gets a name no listed file has, so it can never overwrite a
# listed module's source or its compiled artefacts, nor import itself.
probe_mod="GateProbe"
for f in "${listed[@]}"; do
  while [ "$(basename -- "$f" .v)" = "$probe_mod" ]; do probe_mod="${probe_mod}X"; done
done
# Names the planted controls use are checked too, below.
resolves() {
  local scratch="$1" mod="$2" n i=0
  shift 2
  { printf 'Require %s.\n' "$mod"; for n in "$@"; do printf 'Definition __gate_req_%s := @%s.%s.\n' "$i" "$mod" "$n"; i=$((i+1)); done; } > "$scratch/$probe_mod.v"
  (cd "$scratch" && "$coqc_bin" "$probe_mod.v") > "$scratch/$probe_mod.log" 2>&1
}

# ---- planted controls ------------------------------------------------------
ctl="$work/controls"; mkdir -p "$ctl"
# A Notation that makes `Check` print the line coqc prints for a closed theorem.
# Appended to the forbidden files below, so that text alone would call them closed.
forge="Notation \"'Closed' 'under' 'the' 'global' 'context'\" := tt.
Check (Closed under the global context)."
printf 'Lemma planted_true : True.\nProof. exact I. Qed.\nPrint Assumptions planted_true.\n' > "$ctl/True.v"
printf 'Lemma planted_noprint : True.\nProof. exact I. Qed.\n' > "$ctl/NoPrint.v"
printf 'Axiom cheat : False.\nLemma planted_axiom : False.\nProof. exact cheat. Qed.\n' > "$ctl/Axiom.v"
printf 'Lemma planted_admitted : False.\nProof. Admitted.\nLemma planted_other : True.\nProof. exact I. Qed.\nPrint Assumptions planted_other.\n' > "$ctl/Admitted.v"
printf 'Parameter planted_param : nat.\nLemma planted_uses : planted_param = planted_param.\nProof. reflexivity. Qed.\n' > "$ctl/Parameter.v"
printf 'Lemma planted_ill_typed : False.\nProof. exact I. Qed.\n' > "$ctl/IllTyped.v"
printf 'Unset Guard Checking.\nFixpoint planted_loop (n : nat) : False := planted_loop n.\nLemma planted_guard : False.\nProof. exact (planted_loop 0). Qed.\n' > "$ctl/GuardOff.v"
printf '%s\n' "$forge" >> "$ctl/GuardOff.v"
printf 'Unset Universe Checking.\nDefinition planted_tit : Type := Type.\n' > "$ctl/TypeInType.v"
printf '%s\n' "$forge" >> "$ctl/TypeInType.v"
printf 'Unset Positivity Checking.\nInductive planted_pos : Type := planted_mk : (planted_pos -> False) -> planted_pos.\n' > "$ctl/PositivityOff.v"
printf '%s\n' "$forge" >> "$ctl/PositivityOff.v"
printf '%s\n' 'Axiom cheat : False.' 'Lemma planted_forged : False. Proof. exact cheat. Qed.' \
  "Notation \"'Closed' 'under' 'the' 'global' 'context'\" := tt." 'Check (Closed under the global context).' > "$ctl/NotationForge.v"
printf '%s\n' 'Module Type PlantedS.' '  Parameter planted_bad : False.' 'End PlantedS.' 'Module PlantedM : PlantedS.' \
  '  Unset Guard Checking.' '  Fixpoint planted_loop (n : nat) : False := planted_loop n.' '  Set Guard Checking.' \
  '  Lemma planted_bad : False. Proof. exact (planted_loop 0). Qed.' 'End PlantedM.' > "$ctl/Sealed.v"
printf '%s\n' 'Module Type PlantedE. End PlantedE.' 'Module PlantedF (X : PlantedE).' '  Axiom planted_cheat : False.' 'End PlantedF.' \
  'Lemma planted_ok : True. Proof. exact I. Qed.' > "$ctl/Functor.v"

JUDGE_ALLOWED=()
echo "::group::planted control: closed theorems must be accepted"
for c in True NoPrint; do
  if ! judge_set "$work/s-$c" "$ctl/$c.v"; then
    echo "::endgroup::"
    die2 "the planted $c control was refused ($DEFECT). The toolchain is broken, so a red on the caller's files would be misattributed"
  fi
done
echo "::endgroup::"
echo "planted control: a closed theorem, with and without a Print Assumptions, accepted — the oracle can say yes."
for c in Axiom:check Admitted:check Parameter:check IllTyped:compile GuardOff:check TypeInType:check PositivityOff:check NotationForge:check Sealed:text Functor:text; do
  name="${c%%:*}"; kind="${c##*:}"
  if judge_set "$work/s-$name" "$ctl/$name.v"; then
    die2 "the planted $name control was ACCEPTED. This gate cannot say no; every verdict it gives is VOID"
  fi
  [ "$DEFECT_KIND" = "$kind" ] || die2 "the planted $name control was refused at the wrong stage ($DEFECT_KIND, expected $kind): $DEFECT"
  echo "planted control: $name refused ($DEFECT) — the oracle can say no."
done

echo "::group::planted control: the gate's own existence check"
resolves "$work/s-True" True planted_true \
  || { echo "::endgroup::"; die2 "the gate's own file could not resolve the planted constant True.planted_true"; }
if resolves "$work/s-True" True gate_no_such_name; then
  echo "::endgroup::"; die2 "the gate's own file resolved a name that does not exist. Existence is judged by exit code; this check cannot say no"
fi
echo "::endgroup::"
echo "planted control: a name that exists resolves and one that does not is refused — the existence check can say no."
# ---- the caller's files -------------------------------------------------
JUDGE_ALLOWED=(${allowed[@]+"${allowed[@]}"})
fail=0
missing=0
for f in "${listed[@]}"; do
  [ -f "$f" ] || { err "listed file '$f' does not exist"; fail=1; missing=1; }
done
if [ "$missing" -eq 0 ]; then
  if judge_set "$work/files" "${listed[@]}"; then
    printf '  %-60s coqchk: no axiom, no disabled check\n' "${listed[*]}"
  else
    { sed 's/^/        /' "$work/files/coqchk.log" 2>/dev/null | sed -n '/CONTEXT SUMMARY/,$p' | head -n 40; } || true
    err "$DEFECT"
    fail=1
  fi
fi

# ---- required theorems -----------------------------------------------------
nreq=0
if [ "$fail" -eq 0 ] && [ "${#required[@]}" -gt 0 ]; then
  remaining=("${required[@]}")
  for f in "${listed[@]}"; do
    [ "${#remaining[@]}" -gt 0 ] || break
    mod="$(basename -- "$f")"; mod="${mod%.v}"
    if resolves "$work/files" "$mod" "${remaining[@]}"; then
      nreq=$((nreq + ${#remaining[@]})); remaining=(); break
    fi
    still=()
    for q in "${remaining[@]}"; do
      if resolves "$work/files" "$mod" "$q"; then nreq=$((nreq + 1)); else still+=("$q"); fi
    done
    remaining=()
    for q in ${still[@]+"${still[@]}"}; do remaining+=("$q"); done
  done
  for q in ${remaining[@]+"${remaining[@]}"}; do
    err "no assumption report for required theorem '$q': it resolves to no constant of a listed module (the gate's own file did not compile)"; fail=1
  done
fi

[ "$fail" -eq 0 ] || exit 1
echo "rocq-check[prove]: ${#listed[@]} file(s) compile; coqchk accepts them with no axiom and no disabled check; $nreq required theorem(s) resolved."
exit 0
