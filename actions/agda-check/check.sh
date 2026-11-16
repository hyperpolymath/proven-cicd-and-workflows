#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check.sh — the Agda kernel gate. Agda really checks every listed module, and
# its verdict is the gate's verdict. Generalised from hvn-dehallucinator's
# scripts/check-agda-kernel.sh and scripts/check-proofs.sh agda; the default
# inputs reproduce that repository's behaviour.
#
# The one invocation (standards PROOF-POLICY section 2.1), never loosened:
#   agda --safe --without-K --cubical-compatible --no-libraries
#        --ignore-interfaces --double-check
#
#   AGDA_GATE_PHASE=detect
#       Prints `key=value` facts: agda_files (every .agda file in the tree,
#       build directories pruned), manifest_entries, units (files in the proof
#       and reject directories, plus manifest entries). Fails (exit 1) when
#       .agda files exist but the MANIFEST does not, and when a .agda file lies
#       outside the proof directory, the reject directory and the include
#       directories: the gate will not stay green over sources it does not cover.
#
#   AGDA_GATE_PHASE=prove
#       1. Toolchain: the agda binary must be the pinned one (Agda 2.6.3, the
#          Ubuntu 24.04 package agda-bin 2.6.3-1build1, /usr/bin/agda at the
#          pinned SHA-256). A mismatch is exit 2: no check was performed.
#       2. Planted controls, before anything of the caller's is judged:
#          a known-true module must be accepted, a known-false one must be
#          refused with a type error on its marked line, and a module with a
#          postulate must be refused under --safe. A prover that cannot say no
#          voids every verdict it gives: exit 2.
#       3. Optional pinned siblings: SIBLINGS_SCRIPT, supplied by the caller,
#          runs first. The gate cannot verify what it fetches; the caller's
#          script must pin commits and fail on a mismatch.
#       4. The positive set: every module the MANIFEST lists as `gated` must
#          check; every `quarantine` module must keep failing (a quarantined
#          module that starts to check fails the gate, so the list cannot rot);
#          every .agda file under PROOF_DIR must be listed, and every entry
#          must exist.
#       5. The reject directory (REJECT_DIR, optional): every fixture must be
#          refused with a type error at the one line it marks `-- refused here`.
#          Fixtures are found recursively; each is checked with its own directory
#          as an include root, so a nested fixture declares `module Name` for
#          Name.agda. A scope error, an unsolved meta, a parse error or a missing marker is
#          a broken fixture, not a rejection, and fails the gate.
#
# MANIFEST line: <source-root>|<module-relative-to-source-root>|gated|quarantine|<note>
# Blank lines and lines starting with # are ignored. Any other status is an error.
#
# Exit codes: 0 silent, 1 defect, 2 NO CHECK WAS PERFORMED. 2 is never a pass.
#
# Env: WORKING_DIRECTORY (default "."), MANIFEST, PROOF_DIR, INCLUDE_DIRS
#      (whitespace-separated), SIBLINGS_SCRIPT, SIBLINGS_INCLUDE_GLOB,
#      REJECT_DIR (empty = no reject check), AGDA_BIN (default /usr/bin/agda;
#      the pin applies to whatever this resolves to).
set -uo pipefail

PIN_PACKAGE="agda-bin"
PIN_PACKAGE_VERSION="2.6.3-1build1"
PIN_SHA256="852806142a15951f667df303c73cfce5f4123218ce6e1f1b29acaddc242af00d"
PIN_VERSION_LINE="Agda version 2.6.3"

phase="${AGDA_GATE_PHASE:?AGDA_GATE_PHASE is required: detect|prove}"
dir="${WORKING_DIRECTORY:-.}"
manifest="${MANIFEST-verification/proofs/agda/MANIFEST}"
proof_dir="${PROOF_DIR-verification/proofs/agda}"
include_dirs="${INCLUDE_DIRS-verification/proofs/agda}"
siblings_script="${SIBLINGS_SCRIPT-scripts/fetch-siblings.sh}"
siblings_glob="${SIBLINGS_INCLUDE_GLOB-_build/dependencies/*/src}"
reject_dir="${REJECT_DIR-tests/reject}"
agda_bin="${AGDA_BIN:-/usr/bin/agda}"

# Whitespace-separated lists become arrays without globbing.
read -r -a include_list <<< "${include_dirs//$'\n'/ }"

# Agda aborts when it must print non-ASCII names under a non-UTF-8 locale.
export LC_ALL=C.UTF-8 LANG=C.UTF-8

die2() { echo "::error::agda-check[$phase]: $* — NO CHECK WAS PERFORMED." >&2; exit 2; }
err()  { echo "::error::agda-check[$phase]: $*" >&2; }

cd "$dir" 2>/dev/null || die2 "cannot enter $dir"
root="$PWD"

trim_slashes() { local p="$1"; p="${p#./}"; while [ "${p%/}" != "$p" ]; do p="${p%/}"; done; printf '%s' "$p"; }
manifest="$(trim_slashes "$manifest")"
proof_dir="$(trim_slashes "$proof_dir")"
reject_dir="$(trim_slashes "$reject_dir")"

# Every .agda file in the tree, newest-first irrelevant, build outputs pruned.
all_agda() {
  find . \( -name .git -o -name _build -o -name build -o -name .cicd-suite -o -name node_modules \) -prune -o \
    -type f -name '*.agda' -print | sed 's#^\./##' | LC_ALL=C sort
}
under() { # <path> <dir> -> 0 when path is inside dir; "." is the tree root
  [ -n "$2" ] || return 1
  [ "$2" = . ] && return 0
  case "$1" in "$2"/*) return 0 ;; *) return 1 ;; esac
}
manifest_rows() { # prints "root|rel|status|note" for each non-comment, non-blank line
  [ -f "$manifest" ] || return 0
  local line trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in ''|'#'*) continue ;; esac
    printf '%s\n' "$line"
  done < "$manifest"
}

# ---------------------------------------------------------------------------
# Toolchain: the pinned Agda, or no check at all.
# ---------------------------------------------------------------------------
assert_toolchain() {
  local bin real got pkg
  bin="$(command -v "$agda_bin" 2>/dev/null)" || die2 "'$agda_bin' not found; the Agda kernel gate cannot be skipped"
  real="$(readlink -f "$bin")" || die2 "cannot resolve $bin"
  got="$(sha256sum "$real" | cut -d' ' -f1)" || die2 "cannot hash $real"
  [ "$got" = "$PIN_SHA256" ] || die2 "$real has sha256 $got, pinned $PIN_SHA256 (Agda 2.6.3, $PIN_PACKAGE $PIN_PACKAGE_VERSION). The toolchain is not the pinned one"
  command -v dpkg-query >/dev/null 2>&1 || die2 "dpkg-query is unavailable; the pinned package $PIN_PACKAGE $PIN_PACKAGE_VERSION cannot be confirmed"
  pkg="$(dpkg-query -W -f='${Version}' "$PIN_PACKAGE" 2>/dev/null || true)"
  [ "$pkg" = "$PIN_PACKAGE_VERSION" ] || die2 "package $PIN_PACKAGE is '${pkg:-absent}', pinned $PIN_PACKAGE_VERSION"
  got="$("$bin" --version 2>/dev/null | head -n 1 || true)"
  [ "$got" = "$PIN_VERSION_LINE" ] || die2 "agda --version is '$got', pinned '$PIN_VERSION_LINE'"
  echo "toolchain: $real sha256:$PIN_SHA256 ($PIN_VERSION_LINE, $PIN_PACKAGE $pkg)"
  agda_bin="$bin"
}

flags=(--safe --without-K --cubical-compatible --no-libraries --ignore-interfaces --double-check)

# refusal_defect <fixture> <log>: print why the log is not a type-error refusal
# on the fixture's single marked line; print nothing when it is.
refusal_defect() {
  local file="$1" log="$2" name want got nmarks
  name="$(basename -- "$file" .agda)"
  if ! grep -Eq "/$name\.agda:[0-9]+,[0-9]+" "$log" ||
     ! grep -q 'when checking that' "$log" ||
     grep -Eq 'Not in scope|Failed to find|Unsolved|Parse error' "$log"; then
    echo "unexpected failure while checking $name (not a type error at its declaration)"; return 0
  fi
  want="$(grep -n -- '-- refused here' "$file" | cut -d: -f1 || true)"
  nmarks="$(printf '%s\n' "$want" | grep -c . || true)"
  if [ "$nmarks" -ne 1 ]; then
    echo "$name must mark exactly one line '-- refused here' (found $nmarks)"; return 0
  fi
  got="$(grep -Eo "/$name\.agda:[0-9]+" "$log" | head -n 1 | sed 's#.*:##' || true)"
  if [ "$got" != "$want" ]; then
    echo "$name was refused at line ${got:-?}, not at its marked line $want"; return 0
  fi
  return 0
}

# ---------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------
if [ "$phase" = detect ]; then
  files="$(all_agda)"
  nfiles=0; [ -n "$files" ] && nfiles="$(printf '%s\n' "$files" | grep -c . || true)"
  nentries="$(manifest_rows | grep -c . || true)"
  covered=0; strays=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if under "$f" "$proof_dir" || under "$f" "$reject_dir"; then covered=$((covered+1)); continue; fi
    inc=0
    for d in "${include_list[@]}"; do
      d="$(trim_slashes "$d")"
      if [ "$d" = . ] || under "$f" "$d"; then inc=1; break; fi
    done
    [ "$inc" -eq 1 ] || strays="${strays}${f}"$'\n'
  done <<< "$files"
  printf 'agda_files=%s\n' "$nfiles"
  printf 'manifest_entries=%s\n' "$nentries"
  printf 'units=%s\n' "$((covered + nentries))"
  if [ -n "$strays" ]; then
    err ".agda file(s) outside proof_dir '$proof_dir', reject_dir '$reject_dir' and include_dirs — the gate would stay green over sources it does not cover. Set the inputs, or move or remove the file(s):"
    printf '%s' "$strays" | sed 's/^/  stray: /' >&2
    exit 1
  fi
  if [ "$covered" -gt 0 ] && [ ! -f "$manifest" ]; then
    err "$covered .agda file(s) under '$proof_dir'/'$reject_dir' but no MANIFEST at '$manifest'. List each module as gated or quarantine."
    exit 1
  fi
  exit 0
fi

[ "$phase" = prove ] || { echo "::error::agda-check: unknown phase '$phase' (detect|prove)" >&2; exit 2; }

# ---------------------------------------------------------------------------
# prove
# ---------------------------------------------------------------------------
units_present=0
[ -n "$(all_agda)" ] && units_present=1
[ -n "$(manifest_rows)" ] && units_present=1
[ "$units_present" -eq 1 ] || die2 "no .agda file and no MANIFEST entry in this tree. The prove job must only run when detect reported units > 0"

assert_toolchain

work="$(mktemp -d)" || die2 "cannot create a temp directory"
trap 'rm -rf "$work"' EXIT

# ---- planted controls ------------------------------------------------------
ctl="$work/controls"; mkdir -p "$ctl"
cat > "$ctl/PlantedTrue.agda" <<'AGDA'
module PlantedTrue where

data Nat : Set where
  zero : Nat
  suc  : Nat → Nat

data _≡_ {A : Set} (x : A) : A → Set where
  refl : x ≡ x

one-is-one : suc zero ≡ suc zero
one-is-one = refl
AGDA
cat > "$ctl/PlantedFalse.agda" <<'AGDA'
module PlantedFalse where

data Nat : Set where
  zero : Nat
  suc  : Nat → Nat

data _≡_ {A : Set} (x : A) : A → Set where
  refl : x ≡ x

one-is-zero : suc zero ≡ zero
one-is-zero = refl   -- refused here
AGDA
cat > "$ctl/PlantedPostulate.agda" <<'AGDA'
module PlantedPostulate where

data ⊥ : Set where

postulate cheat : ⊥
AGDA

echo "::group::planted control: a true module must check"
if ! (cd "$ctl" && "$agda_bin" "${flags[@]}" -i . PlantedTrue.agda); then
  echo "::endgroup::"
  die2 "agda could not check the planted TRUE module. The toolchain is broken, so a red on the caller's modules would be misattributed"
fi
echo "::endgroup::"
echo "planted control: true module accepted — the oracle can say yes."

echo "::group::planted control: a false module must be refused with a type error on its marked line"
rc=0
(cd "$ctl" && "$agda_bin" "${flags[@]}" -i . PlantedFalse.agda) > "$work/false.log" 2>&1 || rc=$?
cat "$work/false.log"
echo "::endgroup::"
if [ "$rc" -eq 0 ]; then
  die2 "agda ACCEPTED the planted FALSE module (suc zero ≡ zero by refl). This prover cannot fail; every verdict it gives is VOID"
fi
why="$(refusal_defect "$ctl/PlantedFalse.agda" "$work/false.log")"
[ -z "$why" ] || die2 "the planted FALSE module was refused, but not as a type error on its marked line ($why)"
echo "planted control: false module refused on its marked line — the oracle can say no."

echo "::group::planted control: --safe must refuse a postulate"
rc=0
(cd "$ctl" && "$agda_bin" "${flags[@]}" -i . PlantedPostulate.agda) > "$work/postulate.log" 2>&1 || rc=$?
cat "$work/postulate.log"
echo "::endgroup::"
if [ "$rc" -eq 0 ] || ! grep -q 'Cannot postulate cheat with safe flag' "$work/postulate.log"; then
  die2 "agda did not refuse a postulate under --safe. The kernel flags are not in force; every verdict is VOID"
fi
echo "planted control: postulate refused under --safe — the kernel flags are in force."

# ---- includes (absolute: modules are checked from their own source root) ----
includes=()
for d in "${include_list[@]}"; do
  d="$(trim_slashes "$d")"
  [ -d "$d" ] || die2 "include directory '$d' does not exist"
  includes+=(-i "$root/$d")
done
# shellcheck disable=SC2086 # the glob patterns are expanded here on purpose
glob_dirs() { local g; for g in $siblings_glob; do [ -d "$g" ] && printf '%s\n' "$g"; done; return 0; }

# ---- siblings --------------------------------------------------------------
if [ -n "$siblings_script" ]; then
  [ -f "$siblings_script" ] || die2 "siblings_script '$siblings_script' does not exist. Set siblings_script: '' if the tree has no pinned siblings"
  echo "::group::siblings: bash $siblings_script"
  if ! bash "$siblings_script"; then
    echo "::endgroup::"
    die2 "siblings_script '$siblings_script' failed; the pinned dependencies are not in place"
  fi
  echo "::endgroup::"
fi
while IFS= read -r d; do
  [ -n "$d" ] || continue
  includes+=(-i "$root/$(trim_slashes "$d")")
done < <(glob_dirs)

fail=0

# ---- the positive set ------------------------------------------------------
echo
echo "=== MANIFEST: $manifest ==="
if [ ! -f "$manifest" ]; then
  err "no MANIFEST at '$manifest' but .agda files exist. List each module as gated or quarantine."
  exit 1
fi
listed="$work/listed"; : > "$listed"
gated=0; quarantined=0; unexpected=0
while IFS='|' read -r mroot mrel mstatus mnote; do
  mstatus="${mstatus//[[:space:]]/}"
  case "$mstatus" in
    gated|quarantine) ;;
    *) err "$manifest: '$mroot|$mrel' has status '$mstatus'; it must be 'gated' or 'quarantine' (a typo must not quarantine a module silently)"; fail=1; continue ;;
  esac
  mroot="$(trim_slashes "$mroot")"; [ -n "$mroot" ] || mroot=.
  # One normal form for listed and discovered paths: no leading "./", and a
  # root of "." contributes nothing.
  if [ "$mroot" = . ] || [ -z "$mroot" ]; then printf '%s\n' "${mrel#./}" >> "$listed"; else printf '%s/%s\n' "$mroot" "${mrel#./}" >> "$listed"; fi
  printf '  %-34s %-24s ' "$mroot" "$mrel"
  if [ ! -f "$mroot/$mrel" ]; then
    echo "MISSING"; err "$manifest lists '$mroot/$mrel', which does not exist (stale entry)"; fail=1; continue
  fi
  rc=0
  out="$(cd "$mroot" && "$agda_bin" "${flags[@]}" -i . "${includes[@]}" "$mrel" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ "$mstatus" = gated ]; then
      echo "PASS"; gated=$((gated+1))
    else
      echo "PASS -- UNEXPECTED (quarantined module now checks)"
      echo "        Promote '$mrel' to 'gated' in $manifest."
      unexpected=$((unexpected+1))
    fi
  else
    if [ "$mstatus" = gated ]; then
      echo "FAIL"
      printf '%s\n' "$out" | sed 's/^/        /'
      err "gated module '$mroot/$mrel' does not check"
      fail=1
    else
      echo "fail (quarantined, expected)"
      quarantined=$((quarantined+1))
      [ -z "${mnote// }" ] || echo "        reason:$mnote"
    fi
  fi
done < <(manifest_rows)

# ---- coverage: every .agda file under proof_dir must be listed --------------
echo
echo "=== manifest coverage ($proof_dir) ==="
found="$work/found"
all_agda | while IFS= read -r f; do
  under "$f" "$proof_dir" || continue
  under "$f" "$reject_dir" && continue
  printf '%s\n' "$f"
done | LC_ALL=C sort -u > "$found"
LC_ALL=C sort -u "$listed" -o "$listed"
unlisted="$(comm -13 "$listed" "$found" || true)"
if [ -n "$unlisted" ]; then
  err ".agda file(s) on disk but absent from $manifest; new proofs are gated by default, so list each as gated or quarantine:"
  printf '%s\n' "$unlisted" | sed 's/^/  unlisted: /' >&2
  fail=1
else
  echo "  all $(grep -c . "$found" || true) .agda file(s) under '$proof_dir' accounted for"
fi

# ---- the reject directory --------------------------------------------------
nrejects=0
if [ -n "$reject_dir" ]; then
  echo
  echo "=== expected rejections ($reject_dir) ==="
  rejects=()
  if [ -d "$reject_dir" ]; then
    while IFS= read -r f; do rejects+=("$f"); done < <(find "$reject_dir" -type f -name '*.agda' | LC_ALL=C sort)
  fi
  if [ "${#rejects[@]}" -eq 0 ]; then
    err "no expected-rejection modules under '$reject_dir'. Set reject_dir: '' if the tree has none; an empty set proves nothing."
    fail=1
  fi
  for file in "${rejects[@]}"; do
    name="$(basename -- "$file" .agda)"
    log="$work/reject-$(printf '%s' "$file" | tr '/' '_').log"
    if "$agda_bin" "${flags[@]}" "${includes[@]}" -i "$root/$(dirname -- "$file")" "$file" > "$log" 2>&1; then
      cat "$log"; err "invalid proof accepted: $name"; fail=1; continue
    fi
    why="$(refusal_defect "$file" "$log")"
    if [ -n "$why" ]; then
      cat "$log"; err "$why"; fail=1; continue
    fi
    echo "  PASS: refused $name at $(grep -Eo "/$name\.agda:[0-9]+,[0-9-]+" "$log" | head -n 1 | sed 's#^/##'), its marked line"
    nrejects=$((nrejects+1))
  done
fi

echo
if [ "$fail" -ne 0 ] || [ "$unexpected" -gt 0 ]; then
  err "RESULT: FAIL"
  exit 1
fi
echo "agda-check[prove]: $gated gated module(s) check, $quarantined quarantined still fail, $nrejects expected rejection(s) refused, under the kernel flags."
exit 0
