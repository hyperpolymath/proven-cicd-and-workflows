#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the TLA+ model-check gate. TLC runs the caller's configs; the ones
# that must pass have to pass, and the ones that must be refuted have to be
# refuted by the invariant named for them. Generalised from
# hvn-dehallucinator's scripts/check-tla.sh; the default inputs reproduce it.
#
# A finite model check is TESTED at its bounds, not proven. This gate says the
# listed configs behaved as the caller declared at those bounds, nothing more.
#
#   TLA_GATE_PHASE=detect
#       Prints `key=value` facts: tla_files (.tla files in the tree, build
#       directories pruned), configs (MUST_PASS plus MUST_REFUTE entries), units
#       (configs; 0 when the tree has no .tla file). Exit 1 when .tla files
#       exist and the spec or a listed config is missing, or no config is listed.
#       Only the listed configs are checked: a helper .tla file elsewhere in the
#       tree is allowed, as in hvn-dehallucinator (tests/difftest/TraceCheck.tla).
#
#   TLA_GATE_PHASE=prove
#       1. Toolchain: Java 21 from the package openjdk-21-jre-headless (the
#          runtime's digest is printed, not pinned: the archive ships security
#          rebuilds), and tla2tools.jar v1.7.4 at the pinned SHA-256. The jar is
#          fetched from the tlaplus release if it is not already at TLA_JAR; a
#          mismatch deletes it and is exit 2: no check was performed.
#       2. Planted controls through the SAME judgement the caller's configs get:
#          a model that holds must be judged "passes"; a model that violates an
#          invariant must be judged "refuted by that invariant", must NOT be
#          judged "passes", and must NOT be judged refuted by a different name;
#          a model that holds must NOT be judged refuted. A judge that cannot
#          say no voids every verdict it gives: exit 2.
#       3. MUST_PASS: each config must exit 0 and report "Model checking
#          completed. No error has been found."
#       4. MUST_REFUTE (<config>:<Invariant>): each config must exit non-zero
#          and report "Invariant <Invariant> is violated." A must-refute config
#          that passes fails the gate, as does one refuted by another invariant,
#          a parse error or a deadlock.
#
# Exit codes: 0 silent, 1 defect, 2 NO CHECK WAS PERFORMED. 2 is never a pass.
#
# Env: WORKING_DIRECTORY (default "."), SPEC_DIR (default
#      verification/proofs/tlaplus), SPEC (default Engine.tla), MUST_PASS
#      (default Engine.cfg), MUST_REFUTE (default
#      "Original.cfg:Guarantee OtherTarget.cfg:GuaranteeBound"), WORKERS
#      (default 1), JAVA (default java), TLA_JAR (default
#      $RUNNER_TEMP/tla2tools-v1.7.4.jar, else /tmp).
set -uo pipefail

TLA_VERSION="v1.7.4"
TLA_SHA256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
TLA_URL="https://github.com/tlaplus/tlaplus/releases/download/$TLA_VERSION/tla2tools.jar"
PIN_JAVA_PACKAGE="openjdk-21-jre-headless"
PIN_JAVA_MAJOR="21"

phase="${TLA_GATE_PHASE:?TLA_GATE_PHASE is required: detect|prove}"
dir="${WORKING_DIRECTORY:-.}"
spec_dir="${SPEC_DIR-verification/proofs/tlaplus}"
spec="${SPEC-Engine.tla}"
must_pass_in="${MUST_PASS-Engine.cfg}"
must_refute_in="${MUST_REFUTE-Original.cfg:Guarantee OtherTarget.cfg:GuaranteeBound}"
workers="${WORKERS:-1}"
java_bin="${JAVA:-java}"
jar="${TLA_JAR:-${RUNNER_TEMP:-/tmp}/tla2tools-$TLA_VERSION.jar}"

die2() { echo "::error::tla-check[$phase]: $* — NO CHECK WAS PERFORMED." >&2; exit 2; }
err()  { echo "::error::tla-check[$phase]: $*" >&2; }

cd "$dir" 2>/dev/null || die2 "cannot enter $dir"

trim_slashes() { local p="$1"; p="${p#./}"; while [ "${p%/}" != "$p" ]; do p="${p%/}"; done; printf '%s' "$p"; }
spec_dir="$(trim_slashes "$spec_dir")"
[ -n "$spec_dir" ] || spec_dir=.

[[ "$workers" =~ ^([0-9]+|auto)$ ]] || die2 "workers '$workers' is not a number or 'auto'"
[[ "$spec" =~ ^[A-Za-z0-9_.-]+\.tla$ ]] || die2 "spec '$spec' is not a plain .tla file name"

# Whitespace-separated lists become arrays without globbing.
read -r -a pass_list <<< "${must_pass_in//$'\n'/ }"
read -r -a refute_list <<< "${must_refute_in//$'\n'/ }"
for c in ${pass_list[@]+"${pass_list[@]}"}; do
  [[ "$c" =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*\.cfg$ && "$c" != *..* ]] || die2 "must_pass entry '$c' is not a config file name (<name>.cfg)"
done
refute_cfg=(); refute_inv=()
for e in ${refute_list[@]+"${refute_list[@]}"}; do
  [[ "$e" =~ ^([A-Za-z0-9_][A-Za-z0-9_./-]*\.cfg):([A-Za-z0-9_]+)$ && "${BASH_REMATCH[1]}" != *..* ]] \
    || die2 "must_refute entry '$e' is not <config>.cfg:<Invariant>"
  refute_cfg+=("${BASH_REMATCH[1]}"); refute_inv+=("${BASH_REMATCH[2]}")
done
nconfigs=$(( ${#pass_list[@]} + ${#refute_cfg[@]} ))

all_tla() {
  find . \( -name .git -o -name _build -o -name build -o -name .cicd-suite -o -name node_modules \) -prune -o \
    -type f -name '*.tla' -print | sed 's#^\./##' | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------
if [ "$phase" = detect ]; then
  files="$(all_tla)"
  nfiles=0; [ -n "$files" ] && nfiles="$(printf '%s\n' "$files" | grep -c . || true)"
  printf 'tla_files=%s\n' "$nfiles"
  printf 'configs=%s\n' "$nconfigs"
  if [ "$nfiles" -eq 0 ]; then printf 'units=0\n'; exit 0; fi
  printf 'units=%s\n' "$nconfigs"
  bad=0
  [ -f "$spec_dir/$spec" ] || { err "spec '$spec_dir/$spec' does not exist. Set spec_dir and spec."; bad=1; }
  if [ "$nconfigs" -eq 0 ]; then err "$nfiles .tla file(s) in the tree but no config is listed in must_pass or must_refute — nothing would be checked."; bad=1; fi
  for c in ${pass_list[@]+"${pass_list[@]}"} ${refute_cfg[@]+"${refute_cfg[@]}"}; do
    [ -f "$spec_dir/$c" ] || { err "listed config '$spec_dir/$c' does not exist"; bad=1; }
  done
  [ "$bad" -eq 0 ] || exit 1
  exit 0
fi

[ "$phase" = prove ] || { echo "::error::tla-check: unknown phase '$phase' (detect|prove)" >&2; exit 2; }

# ---------------------------------------------------------------------------
# prove
# ---------------------------------------------------------------------------
[ "$nconfigs" -gt 0 ] || die2 "no config is listed. The prove job must only run when detect reported units > 0"

assert_toolchain() {
  local pkg bin major real got
  command -v dpkg-query >/dev/null 2>&1 || die2 "dpkg-query is unavailable; the package $PIN_JAVA_PACKAGE cannot be confirmed"
  pkg="$(dpkg-query -W -f='${Version}' "$PIN_JAVA_PACKAGE" 2>/dev/null || true)"
  [ -n "$pkg" ] || die2 "package $PIN_JAVA_PACKAGE is not installed"
  bin="$(command -v "$java_bin" 2>/dev/null)" || die2 "'$java_bin' not found; the TLA+ gate cannot be skipped"
  major="$("$bin" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -n 1 || true)"
  [ "$major" = "$PIN_JAVA_MAJOR" ] || die2 "$bin is Java '${major:-?}', pinned $PIN_JAVA_MAJOR"
  real="$(readlink -f "$bin")" || die2 "cannot resolve $bin"
  echo "toolchain: $real Java $major, package $PIN_JAVA_PACKAGE $pkg, sha256:$(sha256sum "$real" | cut -d' ' -f1) (printed, not pinned: the archive ships security rebuilds)"
  java_bin="$bin"

  if [ ! -f "$jar" ]; then
    command -v curl >/dev/null 2>&1 || die2 "curl is unavailable and $jar is absent"
    mkdir -p "$(dirname -- "$jar")"
    curl -sSfL --proto '=https' --proto-redir '=https' --retry 3 -o "$jar.part" "$TLA_URL" || { rm -f "$jar.part"; die2 "cannot fetch $TLA_URL"; }
    mv "$jar.part" "$jar"
  fi
  got="$(sha256sum "$jar" | cut -d' ' -f1)" || die2 "cannot hash $jar"
  if [ "$got" != "$TLA_SHA256" ]; then
    rm -f "$jar"
    die2 "$jar has sha256 $got, pinned $TLA_SHA256 (tla2tools.jar $TLA_VERSION); removed, not run"
  fi
  echo "toolchain: tla2tools $TLA_VERSION @ sha256:$TLA_SHA256"
  jar="$(cd "$(dirname -- "$jar")" && pwd)/$(basename -- "$jar")"
}
assert_toolchain

work="$(mktemp -d)" || die2 "cannot create a temp directory"
trap 'rm -rf "$work"' EXIT

# run_tlc <spec-dir> <spec.tla> <config> <log>: model-check; print TLC's exit
# code on stdout. TLC's own output goes to <log>.
run_tlc() {
  local sdir="$1" sp="$2" cfg="$3" log="$4" rc=0
  (cd "$sdir" && "$java_bin" -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
     -config "$cfg" -workers "$workers" -metadir "$work/meta/$(printf '%s' "$sdir/$cfg" | tr '/' '_')" "$sp") > "$log" 2>&1 || rc=$?
  echo "$rc"
}
# The two judgements, used for the planted controls and for the caller's configs.
judge_pass() { # <rc> <log>
  [ "$1" -eq 0 ] && grep -q 'Model checking completed. No error has been found.' "$2"
}
judge_refuted() { # <rc> <log> <invariant>
  [ "$1" -ne 0 ] && grep -Fq "Invariant $3 is violated." "$2"
}

# ---- planted controls ------------------------------------------------------
ctl="$work/controls"; mkdir -p "$ctl"
cat > "$ctl/PlantedHolds.tla" <<'TLA'
---- MODULE PlantedHolds ----
EXTENDS Naturals
VARIABLE x
Init == x = 0
Next == x' = IF x < 3 THEN x + 1 ELSE x
Spec == Init /\ [][Next]_x
Inv == x \in 0..3
====
TLA
cat > "$ctl/PlantedViolated.tla" <<'TLA'
---- MODULE PlantedViolated ----
EXTENDS Naturals
VARIABLE x
Init == x = 0
Next == x' = IF x < 5 THEN x + 1 ELSE x
Spec == Init /\ [][Next]_x
Inv == x < 3
====
TLA
printf 'SPECIFICATION Spec\nINVARIANT Inv\n' > "$ctl/PlantedHolds.cfg"
printf 'SPECIFICATION Spec\nINVARIANT Inv\n' > "$ctl/PlantedViolated.cfg"

echo "::group::planted controls: TLC on a model that holds and on one that does not"
rc_holds="$(run_tlc "$ctl" PlantedHolds.tla PlantedHolds.cfg "$work/holds.log")"
rc_viol="$(run_tlc "$ctl" PlantedViolated.tla PlantedViolated.cfg "$work/violated.log")"
cat "$work/holds.log" "$work/violated.log"
echo "::endgroup::"
judge_pass "$rc_holds" "$work/holds.log" \
  || die2 "TLC did not pass the planted model that HOLDS (exit $rc_holds). The toolchain is broken, so a red on the caller's configs would be misattributed"
echo "planted control: a model that holds is judged to pass — the oracle can say yes."
judge_refuted "$rc_viol" "$work/violated.log" Inv \
  || die2 "TLC did not report 'Invariant Inv is violated.' for the planted model that VIOLATES it (exit $rc_viol). This oracle cannot refute; every verdict it gives is VOID"
echo "planted control: a model that violates Inv is refuted by Inv — the oracle can say no."
if judge_pass "$rc_viol" "$work/violated.log"; then
  die2 "the judge passed the planted VIOLATED model. This gate cannot say no; every verdict it gives is VOID"
fi
if judge_refuted "$rc_viol" "$work/violated.log" NotTheInvariant; then
  die2 "the judge accepted a refutation by an invariant that was not violated. This gate cannot tell invariants apart; every verdict it gives is VOID"
fi
if judge_refuted "$rc_holds" "$work/holds.log" Inv; then
  die2 "the judge called the planted HOLDING model refuted. This gate cannot tell a pass from a refutation; every verdict it gives is VOID"
fi
echo "planted control: the judge refuses a violated model as a pass, a wrong invariant name, and a holding model as a refutation."

# ---- the caller's configs --------------------------------------------------
fail=0
echo
for c in ${pass_list[@]+"${pass_list[@]}"}; do
  echo "=== $c: must pass ==="
  log="$work/pass-$(printf '%s' "$c" | tr '/' '_').log"
  rc="$(run_tlc "$spec_dir" "$spec" "$c" "$log")"
  grep -E 'states generated|depth of the complete' "$log" | sed 's/^/  /' || true
  if judge_pass "$rc" "$log"; then
    echo "  PASS: no error found"
  else
    cat "$log"
    err "$c: TLC found an error, or did not complete (exit $rc); it must pass"
    fail=1
  fi
done
for i in "${!refute_cfg[@]}"; do
  c="${refute_cfg[$i]}"; inv="${refute_inv[$i]}"
  echo "=== $c: must be refuted by $inv ==="
  log="$work/refute-$(printf '%s' "$c" | tr '/' '_').log"
  rc="$(run_tlc "$spec_dir" "$spec" "$c" "$log")"
  if judge_refuted "$rc" "$log" "$inv"; then
    sed -n '/The behavior up to this point is:/,/^$/p' "$log" | sed 's/^/  /' | head -n 24
    echo "  PASS: Invariant $inv violated, as it must be"
  else
    cat "$log"
    if [ "$rc" -eq 0 ]; then
      err "$c: the model PASSED but must be refuted by $inv — the model cannot tell the cases apart"
    else
      err "$c: not refuted by $inv (exit $rc) — it failed some other way, or the invariant named is not the one violated"
    fi
    fail=1
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo
echo "tla-check[prove]: ${#pass_list[@]} config(s) pass, ${#refute_cfg[@]} refuted by the invariant named, at the declared bounds (tested, not proven)."
exit 0
