#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the Lean axiom gate for standalone (non-Lake) files. lean compiles
# the listed files to .olean; a checker program of the gate's own then re-checks
# each compiled module out of process. Generalised from the Lean leg of
# hvn-dehallucinator's scripts/check-recheck-legs.sh (standards PROOF-POLICY
# section 2); the default file list reproduces that leg.
#
# Trust model. The verdict is made on the COMPILED artefact, never from text the
# caller's file can print. A .lean file runs code at compile time: `#eval` can
# print any line, and `elab_rules` or `macro_rules` can rewrite `#print axioms`
# itself, so lean's messages and the file's own prints are not evidence and are
# not read. Declarations can also be added without the kernel
# (`set_option debug.skipKernelTC true`). So the gate's own checker
# (Checker.lean, embedded below, written to a fresh directory after the compile):
#   a. loads the compiled module with importModules, with no initializer enabled,
#      and replays every constant of it through the kernel
#      (Lean.Environment.replay, as lean4checker does): a declaration added
#      without the kernel is rejected;
#   b. collects the axioms reachable from every AUTHORED safe constant of the
#      module (Lean.CollectAxioms), module-wide: a theorem needs no #print axioms
#      to be covered. Unsafe and partial constants, which replay also skips,
#      include the compiler's own auxiliary axioms and are not roots. A constant
#      is not authored only when the checker has verified that it IS the lemma
#      Lean generates for a constructor of this module: `<ctor>.injEq`, where
#      <ctor> is a constructor of an inductive type declared in this module, and
#      its universe parameters, type and proof term are identical (Expr.eqv) to
#      what Lean's own mkInjectiveTheorems produces, regenerated in the checker.
#      Name shape alone is not enough. Such constants are not roots, but their
#      axioms count whenever an authored constant uses them. Only this family is
#      excluded: it is the generated lemma that carries propext in practice
#      (hvn-dehallucinator: 14 of them). `<ctor>.inj` carried no axiom there and
#      stays a root. Any axiom not in ALLOWED_AXIOMS fails;
#      sorryAx is never allowable;
#   c. resolves each required name to a constant of the module, exactly or as a
#      component suffix (the bare name under any namespace).
# The gate judges by the checker's EXIT CODE (0 pass, 1 verdict failure, anything
# else: no check was performed). What stays trusted: the pinned lean binary and
# the Lean library it ships, importModules not running initializers, the kernel,
# and the runner. Code the file runs at compile time can touch the filesystem;
# that is outside this gate's model.
#
# How this differs from proof-runner-check: that action runs `lake build` on a
# Lake project (a lakefile.lean or lakefile.toml) with whatever Lean is on PATH.
# It proves the project builds, and it does not look at axioms: a `sorry` is a
# warning and `lake build` still exits 0. This gate takes plain files that no
# Lake project owns, runs the pinned Lean 4.15.0 on each, and judges the compiled
# module. Detect ignores .lean files inside a Lake project. The two gates do not
# overlap, and neither stands in for the other.
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
#          lean-4.15.0-linux.tar.zst, against its SHA-256). A mismatch is exit 2.
#       2. Planted controls through the SAME judgement the caller's files get.
#          Accepted: an axiom-free theorem, and one with no #print axioms at all.
#          Refused: a sorry, Classical.choice, a declared axiom, an axiom used
#          only by an unprinted theorem, an ill-typed file, a `#eval` that prints
#          the clean line over an axiom, an `elab_rules` override of
#          `#print axioms`, and a declaration added with
#          `debug.skipKernelTC`. A required name that does not exist must fail
#          to resolve even where `#eval` printed a line naming it. A judge that
#          cannot say no voids every verdict it gives: exit 2.
#       3. Each listed file is compiled standalone, as module GateMod<N> in a
#          scratch directory, with `lean -R . -o GateMod<N>.olean` (imports are
#          limited to the toolchain's own libraries), then judged as above.
#       4. REQUIRED_THEOREMS (optional, whitespace-separated names; a dotted name
#          is qualified): each must resolve to a constant of a listed module.
#          Existence is all this checks; axioms are judged module-wide.
#
# Exit codes: 0 silent, 1 defect, 2 NO CHECK WAS PERFORMED. 2 is never a pass.
#
# Env: WORKING_DIRECTORY (default "."), FILES (default
#      verification/proofs/lean4/Haruspex.lean), REQUIRED_THEOREMS (default
#      none), ALLOWED_AXIOMS (whitespace-separated, default none; sorryAx is
#      refused), LEAN_BIN (default lean on PATH; the pin applies to what it
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
allowed_in="${ALLOWED_AXIOMS-}"
lean_bin="${LEAN_BIN:-lean}"

die2() { echo "::error::lean-axioms-check[$phase]: $* — NO CHECK WAS PERFORMED." >&2; exit 2; }
err()  { echo "::error::lean-axioms-check[$phase]: $*" >&2; }

cd "$dir" 2>/dev/null || die2 "cannot enter $dir"

read -r -a listed <<< "${files_in//$'\n'/ }"
read -r -a required <<< "${required_in//$'\n'/ }"
read -r -a allowed <<< "${allowed_in//$'\n'/ }"
for i in "${!listed[@]}"; do listed[i]="${listed[$i]#./}"; done
for n in ${required[@]+"${required[@]}"} ${allowed[@]+"${allowed[@]}"}; do
  [[ "$n" =~ ^[A-Za-z_]([A-Za-z0-9_\'.]*[A-Za-z0-9_\'])?$ ]] || die2 "name '$n' is not an identifier (ASCII letters, digits, _ and ', with inner dots for a qualified name)"
done
allowed_csv=""
for n in ${allowed[@]+"${allowed[@]}"}; do
  [ "$n" != sorryAx ] || die2 "sorryAx is never allowable"
done
for n in ${allowed[@]+"${allowed[@]}"}; do allowed_csv="${allowed_csv:+$allowed_csv,}$n"; done

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
# The gate's own checker. Written to a fresh directory AFTER the caller's file
# has been compiled, and run with `lean --run`. It imports only Lean.
write_checker() { # <dir>
  mkdir -p "$1"
  cat > "$1/Checker.lean" <<'LEAN'
import Lean
open Lean

/-- Exit codes: 0 pass, 1 verdict failure, 3 the checker could not run. -/
def verdict (ok : Bool) (msg : String) : IO UInt32 := do
  IO.println s!"gate-checker: {if ok then "ok" else "FAIL"} {msg}"
  return (if ok then 0 else 1)

def endsWith (n suffix : Name) : Bool :=
  let sr := suffix.components.reverse
  n.components.reverse.take sr.length == sr

def loadModule (modStr : String) : IO ModuleData := do
  -- The search path comes from the running (verified) lean binary, never from a
  -- `lean` found on PATH.
  initSearchPath (← getBuildDir)
  let (md, _) ← readModuleData (← findOLean modStr.toName)
  return md

/-- The `C.inj` and `C.injEq` constants of the module whose prefix `C` is a
constructor of an inductive type declared in the same module. Name shape only:
each is verified below before it is treated as generated. Both are taken out of
the environment the generator runs in (it would refuse to redeclare them); only
`injEq` is ever excused as a root. -/
def injCandidates (consts : Std.HashMap Name ConstantInfo) : Array Name :=
  consts.fold (init := #[]) fun acc n ci =>
    match n with
    | .str p s =>
      if (s == "inj" || s == "injEq") && ci.isTheorem && !ci.isUnsafe then
        match consts[p]? with
        | some (.ctorInfo cv) =>
          match consts[cv.induct]? with
          | some (.inductInfo _) => acc.push n
          | _ => acc
        | _ => acc
      else acc
    | _ => acc

/-- Candidates and every constant of the module that uses one, transitively. -/
def dependents (consts : Std.HashMap Name ConstantInfo) (cands : Array Name) : NameSet := Id.run do
  let mut dep : NameSet := cands.foldl (·.insert ·) {}
  let mut changed := true
  while changed do
    changed := false
    for (n, ci) in consts.toList do
      unless dep.contains n do
        if ci.getUsedConstantsAsSet.any dep.contains then
          dep := dep.insert n
          changed := true
  return dep

/-- Run `act` on a fresh OS thread. The kernel's heartbeat counter is per thread
and is not reset between declarations, so one long replay can exhaust it for the
next. -/
def onFreshThread (act : IO α) : IO α := do
  let t ← IO.asTask act Task.Priority.dedicated
  match t.get with
  | .ok a => pure a
  | .error e => throw e

/-- Replay the module's constants through the kernel in two passes, so that
Lean's own injectivity theorems can be regenerated in between. Pass one replays
every constant that does not (transitively) use a candidate `inj`/`injEq`
theorem and regenerates Lean's own theorems for every inductive type of the
module in that environment. Pass two replays the rest on top. Returns the final
environment and the environment holding the regenerated theorems. -/
def replayAndRegenerate (base : Environment) (consts : Std.HashMap Name ConstantInfo)
    (dep : NameSet) : IO (Environment × Environment) := do
  let mut keep : Std.HashMap Name ConstantInfo := {}
  let mut rest : Std.HashMap Name ConstantInfo := {}
  for (n, ci) in consts.toList do
    if dep.contains n then rest := rest.insert n ci else keep := keep.insert n ci
  let (env0, env1) ← onFreshThread do
    let env0 ← base.replay keep
    let mut st : Core.State := { env := env0 }
    for (n, ci) in keep.toList do
      if let .inductInfo _ := ci then
        -- The heartbeat budget counts from now, as in a fresh command.
        let ctx : Core.Context :=
          { fileName := "<gate>", fileMap := default, initHeartbeats := (← IO.getNumHeartbeats) }
        let ((), st') ← (Lean.Meta.mkInjectiveTheorems n |>.run').toIO ctx st
        st := st'
    return (env0, st.env)
  let env ← onFreshThread (env0.replay rest)
  return (env, env1)

/-- Replay every constant of the module through the kernel; then every axiom
reachable from any AUTHORED constant of the module must be allowed. A constant is
not authored when it is the very lemma Lean generates for a constructor of the
module: same name shape, same universe parameters, same type and same proof term
as Lean's own generator produces. Its axioms still count whenever any authored
constant uses it. -/
def check (modStr allowedStr : String) : IO UInt32 := do
  let allowed : List Name := (allowedStr.splitOn ",").filter (· ≠ "") |>.map String.toName
  if allowed.contains `sorryAx then
    return (← verdict false "sorryAx is never allowable")
  let md ← loadModule modStr
  -- No initializer is run: enableInitializersExecution is never called.
  let base ← importModules md.imports {} 0
  let mut consts : Std.HashMap Name ConstantInfo := {}
  for n in md.constNames, ci in md.constants do consts := consts.insert n ci
  let cands := injCandidates consts
  let (env, env1) ← try
      if cands.isEmpty then
        let e ← onFreshThread (base.replay consts)
        pure (e, e)
      else replayAndRegenerate base consts (dependents consts cands)
    catch e =>
      return (← verdict false s!"kernel replay rejected the module (or regenerating Lean's injectivity theorems failed): {e}")
  IO.println s!"gate-checker: replayed {consts.size} constants of {modStr} through the kernel"
  -- Which injectivity theorems are Lean's own?
  let mut generated : NameSet := {}
  if !cands.isEmpty then
    for c in cands do
      match consts[c]?, env1.find? c with
      | some ci, some ci1 =>
        if ci.levelParams == ci1.levelParams && ci.type.eqv ci1.type
            && ci.value!.eqv ci1.value! then
          if c.getString! == "injEq" then
            generated := generated.insert c
            IO.println s!"gate-checker: generated {c} (identical to Lean's own); not an authored root"
          else
            IO.println s!"gate-checker: generated {c} (identical to Lean's own); kept as a root"
        else
          IO.println s!"gate-checker: {c} differs from what Lean generates; treated as authored"
      | _, _ => IO.println s!"gate-checker: {c} is not generated by Lean here; treated as authored"
  -- Roots: authored constants the kernel checked. Unsafe and partial constants are
  -- skipped by replay and cannot be used by a safe one; they include the
  -- compiler's own auxiliary constants (_cstage1, _elambda_N), which are axioms.
  let roots := (md.constNames.zip md.constants).filter
    (fun (n, ci) => !ci.isUnsafe && !ci.isPartial && !generated.contains n) |>.map (·.1)
  let ((), st) := ((roots.forM CollectAxioms.collect).run env).run {}
  for a in st.axioms do
    IO.println s!"gate-checker: axiom {a}{if allowed.contains a then " (allowed)" else ""}"
  let bad := st.axioms.filter (!allowed.contains ·)
  if !bad.isEmpty then
    return (← verdict false s!"module uses axiom(s) not allowed: {bad.toList}")
  verdict true s!"{consts.size} constants replayed, no disallowed axiom ({generated.size} generated injectivity theorem(s) not counted as roots)"

/-- Every name must resolve to a constant of the module (exact, or a component suffix). -/
def resolve (modStr : String) (names : List String) : IO UInt32 := do
  let md ← loadModule modStr
  for r in names do
    unless md.constNames.any (endsWith · r.toName) do
      return (← verdict false s!"required name '{r}' resolves to no constant of {modStr}")
  verdict true s!"{names.length} required name(s) resolve in {modStr}"

def main (args : List String) : IO UInt32 := do
  try
    match args with
    | ["check", modStr, allowedStr] => check modStr allowedStr
    | "resolve" :: modStr :: names => resolve modStr names
    | _ => IO.println "gate-checker: ERROR usage"; return (3 : UInt32)
  catch e =>
    IO.println s!"gate-checker: ERROR {e}"
    return (3 : UInt32)
LEAN
}


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
DEFECT_KIND=""   # compile | check
# The axioms a judged module may use. The planted controls are judged with NONE,
# whatever the caller allows; the caller's files are judged with ALLOWED_AXIOMS.
JUDGE_ALLOWED=""
JUDGE_SHOW=0   # 1: print which constants the checker excused or flagged
CHK_LOG=""
# run_checker <scratch> <args...>: run the gate's own checker, in a fresh
# directory written after the caller's code has run. Prints its output. Returns
# its exit code: 0 pass, 1 verdict failure; any other code is exit 2 here.
run_checker() {
  local scratch="$1" rc=0
  shift
  rm -rf "$scratch/checker"; write_checker "$scratch/checker"
  CHK_LOG="$scratch/checker.log"
  (cd "$scratch/checker" && LEAN_PATH="$scratch" "$lean_bin" --run Checker.lean "$@") > "$CHK_LOG" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    sed 's/^/        /' "$CHK_LOG" | tail -n 20 >&2
    die2 "the checker could not run (exit $rc)"
  fi
  return "$rc"
}

# judge_set <scratch> <file>...: 0 when every file compiles and the checker
# passes every compiled module; 1 with DEFECT and DEFECT_KIND set otherwise. The
# one judgement for the planted controls and for the caller's files. Nothing
# lean prints while compiling is read.
judge_set() {
  local scratch="$1" f i=0 rc
  shift
  DEFECT=""; DEFECT_KIND=""
  mkdir -p "$scratch"
  for f in "$@"; do
    cp -- "$f" "$scratch/GateMod$i.lean"
    rc=0
    (cd "$scratch" && "$lean_bin" -R . -o "GateMod$i.olean" "GateMod$i.lean") > "$scratch/GateMod$i.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then DEFECT="lean failed on $f (exit $rc)"; DEFECT_KIND=compile; return 1; fi
    i=$((i+1))
  done
  i=0
  for f in "$@"; do
    rc=0
    run_checker "$scratch" check "GateMod$i" "$JUDGE_ALLOWED" || rc=$?
    if [ "$rc" -ne 0 ]; then
      DEFECT="the checker refused $f: $(grep -E 'FAIL' "$CHK_LOG" | head -n 2 | tr '\n' ' ')"; DEFECT_KIND=check; return 1
    fi
    [ "$JUDGE_SHOW" != 1 ] || { grep -E "gate-checker: (generated|\S+ differs|axiom)" "$CHK_LOG" | sed "s/^/        /" || true; }
    i=$((i+1))
  done
  return 0
}

# resolves <scratch> <index> <name>...: 0 when the checker finds every name among
# the constants of compiled module GateMod<index>.
resolves() {
  local scratch="$1" idx="$2" rc=0
  shift 2
  run_checker "$scratch" resolve "GateMod$idx" "$@" || rc=$?
  return "$rc"
}

# ---- planted controls ------------------------------------------------------
ctl="$work/controls"; mkdir -p "$ctl"
printf 'theorem planted_true : True := trivial\n#print axioms planted_true\n' > "$ctl/True.lean"
printf 'theorem planted_noprint : True := trivial\n' > "$ctl/NoPrint.lean"
printf 'theorem planted_sorry : False := sorry\n' > "$ctl/Sorry.lean"
printf 'theorem planted_classical (p : Prop) : p ∨ ¬p := Classical.em p\n' > "$ctl/Classical.lean"
printf 'axiom planted_cheat : False\ntheorem planted_axiom : False := planted_cheat\n#print axioms planted_axiom\n' > "$ctl/Axiom.lean"
printf 'axiom planted_cheat : False\ntheorem planted_unprinted : False := planted_cheat\ntheorem planted_fine : True := trivial\n#print axioms planted_fine\n' > "$ctl/AxiomUnprinted.lean"
printf 'theorem planted_ill_typed : False := trivial\n' > "$ctl/IllTyped.lean"
printf 'axiom planted_cheat : False\ntheorem planted_bad : False := planted_cheat\ntheorem planted_ok : True := trivial\n#eval IO.println "'"'"'planted_ok'"'"' does not depend on any axioms"\n#eval IO.println "'"'"'planted_bad'"'"' does not depend on any axioms"\n' > "$ctl/EvalForge.lean"
cat > "$ctl/MacroForge.lean" <<'LEAN'
import Lean
open Lean Elab Command
axiom planted_cheat : False
theorem planted_bad : False := planted_cheat
elab_rules : command
  | `(#print axioms $id:ident) => logInfo m!"'{id.getId}' does not depend on any axioms"
#print axioms planted_bad
LEAN
cat > "$ctl/SkipKernel.lean" <<'LEAN'
import Lean
open Lean Elab Command
set_option debug.skipKernelTC true in
run_cmd liftCoreM (addDecl (.thmDecl { name := `planted_bad, levelParams := [], type := mkConst ``False, value := mkConst ``True.intro }))
#print axioms planted_bad
LEAN

printf 'structure PlantedS where\n  x : Nat\n  y : Nat\ntheorem planted_ok : True := trivial\n' > "$ctl/Structure.lean"
printf 'structure PlantedS where\n  x : Nat\ntheorem planted_uses (a b : Nat) : (PlantedS.mk a = PlantedS.mk b) = (a = b) := PlantedS.mk.injEq a b\n' > "$ctl/HandUsesInjEq.lean"
printf 'axiom planted_cheat : False\ntheorem PlantedFoo.injEq : False := planted_cheat\n' > "$ctl/FakeInjEq.lean"
printf 'set_option genInjectivity false in\nstructure PlantedS where\n  x : Nat\ntheorem PlantedS.mk.injEq : 1 = 1 := by have _ := Classical.em True; rfl\n' > "$ctl/GenOffInjEq.lean"
printf 'set_option genInjectivity false in\nstructure PlantedS where\n  x : Nat\ntheorem PlantedS.mk.injEq (x x_1 : Nat) : (PlantedS.mk x = PlantedS.mk x_1) = (x = x_1) := by\n  have _ := Classical.em True\n  exact propext ⟨fun h => by cases h; rfl, fun h => by subst h; rfl⟩\n' > "$ctl/SameTypeInjEq.lean"
JUDGE_ALLOWED=""
echo "::group::planted control: axiom-free modules must be accepted"
for c in True NoPrint Structure; do
  if ! judge_set "$work/s-$c" "$ctl/$c.lean"; then
    echo "::endgroup::"
    die2 "the planted $c control was refused ($DEFECT). The toolchain is broken, so a red on the caller's files would be misattributed"
  fi
done
echo "::endgroup::"
echo "planted control: an axiom-free theorem, with and without a #print axioms, accepted (a structure, whose generated injectivity theorems use propext, included) — the oracle can say yes."
for c in Sorry:check Classical:check Axiom:check AxiomUnprinted:check IllTyped:compile EvalForge:check MacroForge:check SkipKernel:check HandUsesInjEq:check FakeInjEq:check GenOffInjEq:check SameTypeInjEq:check; do
  name="${c%%:*}"; kind="${c##*:}"
  if judge_set "$work/s-$name" "$ctl/$name.lean"; then
    die2 "the planted $name control was ACCEPTED. This gate cannot say no; every verdict it gives is VOID"
  fi
  [ "$DEFECT_KIND" = "$kind" ] || die2 "the planted $name control was refused at the wrong stage ($DEFECT_KIND, expected $kind): $DEFECT"
  echo "planted control: $name refused ($DEFECT) — the oracle can say no."
done
echo "::group::planted control: the gate's own name resolution"
resolves "$work/s-True" 0 planted_true \
  || { echo "::endgroup::"; die2 "the checker could not resolve the planted constant planted_true"; }
if resolves "$work/s-EvalForge" 0 planted_ok planted_undefined_name; then
  echo "::endgroup::"; die2 "the checker resolved a name that does not exist while #eval printed lines about other names. Resolution cannot say no; every verdict is VOID"
fi
echo "::endgroup::"
echo "planted control: a name that exists resolves and one that does not is refused — resolution can say no."

# ---- the caller's files -------------------------------------------------
JUDGE_ALLOWED="$allowed_csv"
JUDGE_SHOW=1
fail=0
missing=0
for f in "${listed[@]}"; do
  [ -f "$f" ] || { err "listed file '$f' does not exist"; fail=1; missing=1; }
done
if [ "$missing" -eq 0 ]; then
  if judge_set "$work/files" "${listed[@]}"; then
    printf '  %-60s checker: kernel replay ok, no disallowed axiom\n' "${listed[*]}"
  else
    { sed 's/^/        /' "$work/files/checker.log" 2>/dev/null | head -n 40; } || true
    err "$DEFECT"
    fail=1
  fi
fi

# ---- required theorems -----------------------------------------------------
nreq=0
if [ "$fail" -eq 0 ] && [ "${#required[@]}" -gt 0 ]; then
  remaining=("${required[@]}")
  for idx in "${!listed[@]}"; do
    [ "${#remaining[@]}" -gt 0 ] || break
    if resolves "$work/files" "$idx" "${remaining[@]}"; then
      nreq=$((nreq + ${#remaining[@]})); remaining=(); break
    fi
    still=()
    for q in "${remaining[@]}"; do
      if resolves "$work/files" "$idx" "$q"; then nreq=$((nreq + 1)); else still+=("$q"); fi
    done
    remaining=()
    for q in ${still[@]+"${still[@]}"}; do remaining+=("$q"); done
  done
  for q in ${remaining[@]+"${remaining[@]}"}; do
    err "no axiom report for required theorem '$q': it resolves to no constant of a listed module"; fail=1
  done
fi

[ "$fail" -eq 0 ] || exit 1
echo "lean-axioms-check[prove]: ${#listed[@]} file(s) compile; the checker replays them through the kernel and finds no disallowed axiom; $nreq required theorem(s) resolved."
exit 0
