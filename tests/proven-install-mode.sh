#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Conformance test for the INSTALL MODE contract in docs/proven/INSTALL-MODE.adoc.
#
# Install mode is the applier's content-only rewrite of a stamped copy: BEHIND
# becomes CURRENT, or an absent copy is installed. This repository does not ship
# the applier (it lives in standards, see ARCHITECTURE.adoc "Propagation"). So
# this test does not run it. It does two things that need no applier:
#
#   1. Classification. A known-answer table for the states the census and the
#      rewrite must tell apart (CURRENT, BEHIND, DRIFT, AHEAD, UNPUBLISHED,
#      LEGACY, UNSTAMPED, ABSENT, wrong artifact), computed from the real
#      scripts/proven-stamp.sh and a manifest in the real format.
#   2. The rewrite contract, as a MODEL: a small reference implementation of
#      the rewrite, written here, plus a checker of the contract's invariants.
#      The model shows the contract can be met with this repository's stamp and
#      manifest, and the checker is shown able to fail: every mutant of the model
#      (drops the local region, leaves the old suite pin, rewrites a drifted,
#      AHEAD or LEGACY copy, writes a second file, keeps the old stamp)
#      must be caught by at least one invariant.
#
# The model is not the applier and not a template for it. A real applier is
# held to the same invariants by its own self-test in standards; whether it
# is, is a gap recorded in INSTALL-MODE.adoc, not something proved here.
# Exit: 0 conforms, 1 broken, 2 not run (no jq).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "proven-install-mode: jq missing; NOT RUN" >&2; exit 2; }
stampsh=$root/scripts/proven-stamp.sh
art=proven-lock-gate
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "ok: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

hex40() { printf '%s' "$1" | sha256sum | cut -c1-40; }
SUITE_SHA=$(hex40 suite-commit-x)
OLD_PIN=$(hex40 consumer-old-pin)
OLD_CHECKOUT=$(hex40 consumer-old-checkout)

# ---- helpers that read stamps and the manifest (the census side) ------------
stamp_of() {
  local l1 l2; l1=$(sed -n 1p "$1"); l2=$(sed -n 2p "$1")
  if [[ $l1 == '# proven-cicd: '* ]]; then printf '%s\n' "$l1"
  elif [[ $l1 == '# SPDX-License-Identifier: '* && $l2 == '# proven-cicd: '* ]]; then printf '%s\n' "$l2"; fi
}
mf() { jq -r --arg a "$art" ".artifacts[] | select(.artifact == \$a) | $2" "$1/proven/manifest.json"; }

# classify SUITE CONSUMER: one token. Pure: reads, never writes.
classify() {
  local S=$1 C=$2 rel f st body name rest ver sha cur cursha lowest
  rel=$(mf "$S" .install_path); f=$C/$rel
  [[ -f $f ]] || { echo ABSENT; return; }
  st=$(stamp_of "$f"); [[ -n $st ]] || { echo UNSTAMPED; return; }
  body=${st#\# proven-cicd: }; name=${body%%@*}; rest=${body#*@}; ver=${rest%% *}; sha=${rest##*sha256:}
  [[ $name == "$art" ]] || { echo OTHER-ARTIFACT; return; }
  "$stampsh" check "$f" >/dev/null 2>&1 || { echo DRIFT; return; }
  # A legacy-layout copy (stamp on line 1) hashes a different region from the
  # published bodies, so its stamp can never match the manifest's history. It
  # cannot be told from a forged one: a state of its own, never rewritten here.
  [[ $(sed -n 1p "$f") == '# proven-cicd: '* ]] && { echo LEGACY; return; }
  cur=$(mf "$S" .version); cursha=$(mf "$S" .sha256)
  if [[ $ver == "$cur" ]]; then [[ $sha == "$cursha" ]] && echo CURRENT || echo UNPUBLISHED; return; fi
  lowest=$(printf '%s\n%s\n' "$ver" "$cur" | sort -V | head -n 1)
  if [[ $lowest == "$ver" ]]; then
    if [[ -n $(mf "$S" ".history[] | select(.version == \"$ver\" and .sha256 == \"$sha\") | .version") ]]; then echo BEHIND
    else echo UNPUBLISHED; fi
  else echo AHEAD; fi
}

# ---- the model of the rewrite -----------------------------------------------
locals_of() { awk '/^[[:space:]]*# proven-cicd:local-next[[:space:]]*$/ { n = 1; next } n { print; n = 0 }' "$1"; }
markers_of() { grep -cE '^[[:space:]]*# proven-cicd:local-next[[:space:]]*$' "$1" || true; }

# refresh SUITE CONSUMER SUITE_SHA: prints REFRESHED, NOOP or REFUSED:<class>.
# MUT names a deliberate defect, for the controls only.
refresh() {
  local S=$1 C=$2 X=$3 cls rel tpl f tmp lf
  cls=$(classify "$S" "$C")
  case $cls in
    BEHIND|ABSENT) ;;
    CURRENT) echo NOOP; return 0 ;;
    DRIFT)  [[ ${MUT:-} == rewrite-drift ]] || { echo "REFUSED:$cls"; return 3; } ;;
    AHEAD)  [[ ${MUT:-} == rewrite-ahead ]] || { echo "REFUSED:$cls"; return 3; } ;;
    LEGACY) [[ ${MUT:-} == rewrite-legacy ]] || { echo "REFUSED:$cls"; return 3; } ;;
    *) echo "REFUSED:$cls"; return 3 ;;
  esac
  rel=$(mf "$S" .install_path); tpl=$S/$(mf "$S" .template); f=$C/$rel
  tmp=$(mktemp "$work/rf.XXXXXX"); lf=$(mktemp "$work/lf.XXXXXX")
  if [[ $cls == ABSENT ]]; then cp "$tpl" "$tmp"
  else
    locals_of "$f" > "$lf"
    [[ $(wc -l < "$lf") -eq $(markers_of "$tpl") ]] || { echo "REFUSED:LOCAL-SHAPE"; return 3; }
    if [[ ${MUT:-} == drop-locals ]]; then cp "$tpl" "$tmp"
    else
      awk -v lf="$lf" 'BEGIN { while ((getline l < lf) > 0) L[++n] = l }
           /^[[:space:]]*# proven-cicd:local-next[[:space:]]*$/ { print; getline; print L[++i]; next }
           { print }' "$tpl" > "$tmp"
    fi
  fi
  if [[ ${MUT:-} != keep-old-pin ]]; then
    sed -i -E "s/^([[:space:]]*PROVEN_SHA: \")[0-9a-f]{40}(\")/\1$X\2/" "$tmp"
  fi
  if [[ ${MUT:-} == keep-old-stamp && $cls != ABSENT ]]; then
    { sed -n 1,2p "$f"; tail -n +3 "$tmp"; } > "$tmp.k"; mv "$tmp.k" "$tmp"
  fi
  mkdir -p "$(dirname "$f")"; cat "$tmp" > "$f"; rm -f "$tmp" "$lf"
  [[ ${MUT:-} == write-extra ]] && echo extra > "$C/EXTRA"
  echo REFRESHED
}

# ---- fixtures ----------------------------------------------------------------
# build_suite DIR: the real template, and a manifest in the real format whose
# history holds an older published version (0.0.1) under the current one.
build_suite() {
  local S=$1 cur cursha oldsha
  mkdir -p "$S/proven" "$S/templates"
  cp "$root/templates/$art.yml" "$S/templates/$art.yml"
  cur=$(jq -r --arg a "$art" '.artifacts[]|select(.artifact==$a)|.version' "$root/proven/manifest.json")
  cursha=$("$stampsh" hash "$S/templates/$art.yml")
  mkdir -p "$S/old"; sed '3i # an older body' "$S/templates/$art.yml" | sed -E "2s/@[0-9.]+ /@0.0.1 /" > "$S/old/$art.yml"
  "$stampsh" stamp "$S/old/$art.yml" >/dev/null; oldsha=$("$stampsh" hash "$S/old/$art.yml")
  jq --arg a "$art" --arg cur "$cur" --arg cs "$cursha" --arg os "$oldsha" \
     '.artifacts |= map(select(.artifact == $a) | .version = $cur | .sha256 = $cs
        | .history = [{version:"0.0.1", sha256:$os}, {version:$cur, sha256:$cs}])' \
     "$root/proven/manifest.json" > "$S/proven/manifest.json"
}
# put_copy SUITE CONSUMER KIND: a consumer copy with LOCAL values of its own.
put_copy() {
  local S=$1 C=$2 kind=$3 f src
  f=$C/.github/workflows/$art.yml; mkdir -p "$C/.github/workflows"; echo keep > "$C/README"
  case $kind in
    current) src=$S/templates/$art.yml ;;
    *) src=$S/old/$art.yml ;;
  esac
  sed -E "s/^([[:space:]]*PROVEN_SHA: \")[0-9a-f]{40}(\")/\1$OLD_PIN\2/; s#(actions/checkout@)[0-9a-f]{40}#\1$OLD_CHECKOUT#" "$src" > "$f"
  case $kind in
    drift) sed -i '3i # a hand edit' "$f" ;;
    forged) sed -i -E '2s/@[0-9.]+ /@0.0.0 /; 3i # forged' "$f"; "$stampsh" stamp "$f" >/dev/null ;;
    wrong-hash) sed -i '3i # same version, other body' "$f"; "$stampsh" stamp "$f" >/dev/null ;;
    ahead) sed -i -E '2s/@[0-9.]+ /@9.9.9 /' "$f"; "$stampsh" stamp "$f" >/dev/null ;;
    unstamped) sed -i '2d' "$f" ;;
    other) sed -i -E '2s/proven-cicd: [A-Za-z0-9._-]+@/proven-cicd: other-artifact@/' "$f"; "$stampsh" stamp "$f" >/dev/null ;;
    legacy)
      sed -i '1d' "$f"
      "$stampsh" hash "$f" > "$work/legacy.h"
      sed -i -E "1s/sha256:[0-9a-f]{64}/sha256:$(cat "$work/legacy.h")/" "$f" ;;
  esac
}
tree_sum() { (cd "$1" && find . -type f ! -path "./$2" -print0 | sort -z | xargs -0 sha256sum | sha256sum); }

# ---- 1. classification: known answers ---------------------------------------
S=$work/suite; build_suite "$S"
expect_class() {
  local kind=$1 want=$2 C got
  C=$(mktemp -d "$work/c.XXXXXX"); put_copy "$S" "$C" "$kind"; got=$(classify "$S" "$C")
  [[ $got == "$want" ]] && ok "classify $kind -> $want" || bad "classify $kind: want $want, got $got"
}
expect_class current CURRENT
expect_class behind BEHIND
expect_class legacy LEGACY
expect_class drift DRIFT
expect_class forged UNPUBLISHED
expect_class wrong-hash UNPUBLISHED
expect_class ahead AHEAD
expect_class unstamped UNSTAMPED
expect_class other OTHER-ARTIFACT
C=$(mktemp -d "$work/c.XXXXXX"); [[ $(classify "$S" "$C") == ABSENT ]] && ok "classify no file -> ABSENT" || bad "ABSENT"

# ---- 2. the rewrite: invariants, then mutants --------------------------------
# run_contract: builds fresh fixtures and checks every invariant of the contract.
# Prints one line per violated invariant, so that a mutant is caught by name.
run_contract() {
  local S C rel before_locals after_locals out before after f v
  S=$(mktemp -d "$work/s.XXXXXX"); build_suite "$S"; rel=$(mf "$S" .install_path)

  # I1-I7: a BEHIND copy (current layout) and a legacy BEHIND copy.
  for kind in behind; do
    C=$(mktemp -d "$work/c.XXXXXX"); put_copy "$S" "$C" "$kind"; f=$C/$rel
    locals_of "$f" | grep -v PROVEN_SHA > "$work/before.l" || true
    before=$(tree_sum "$C" "$rel")
    out=$(refresh "$S" "$C" "$SUITE_SHA" || true)
    [[ $out == REFRESHED ]] || echo "I0($kind): BEHIND not refreshed ($out)"
    [[ $(classify "$S" "$C") == CURRENT ]] || echo "I1($kind): result is not CURRENT"
    "$stampsh" check "$f" >/dev/null 2>&1 || echo "I2($kind): stamp does not match body"
    [[ $(stamp_of "$f") == "# proven-cicd: $art@$(mf "$S" .version) sha256:$(mf "$S" .sha256)" ]] || echo "I3($kind): stamp is not the manifest's current"
    locals_of "$f" | grep -v PROVEN_SHA > "$work/after.l" || true
    cmp -s "$work/before.l" "$work/after.l" || echo "I4($kind): local region not preserved"
    grep -qx "[[:space:]]*PROVEN_SHA: \"$SUITE_SHA\"" "$f" || echo "I5($kind): suite pin not moved to the installed commit"
    [[ $(tree_sum "$C" "$rel") == "$before" ]] || echo "I6($kind): a path other than install_path changed"
    [[ $(sed -n 1p "$f") == '# SPDX-License-Identifier: '* && $(sed -n 2p "$f") == '# proven-cicd: '* ]] || echo "I7($kind): stamp not under the SPDX line"
    cp "$f" "$work/once"; out=$(refresh "$S" "$C" "$SUITE_SHA" || true)
    { [[ $out == NOOP ]] && cmp -s "$f" "$work/once"; } || echo "I8($kind): second run is not a no-op"
  done

  # I9: an ABSENT copy is installed from the template at install_path.
  C=$(mktemp -d "$work/c.XXXXXX"); echo keep > "$C/README"; f=$C/$rel
  out=$(refresh "$S" "$C" "$SUITE_SHA" || true)
  { [[ $out == REFRESHED && $(classify "$S" "$C") == CURRENT ]] && grep -q "PROVEN_SHA: \"$SUITE_SHA\"" "$f"; } || echo "I9: ABSENT not installed CURRENT with the new pin"

  # I10-I12: copies the rewrite must not touch, each left byte for byte.
  for kind in drift ahead forged wrong-hash unstamped other legacy; do
    C=$(mktemp -d "$work/c.XXXXXX"); put_copy "$S" "$C" "$kind"; f=$C/$rel; cp "$f" "$work/untouched"
    out=$(refresh "$S" "$C" "$SUITE_SHA" || true)
    { [[ $out == REFUSED:* ]] && cmp -s "$f" "$work/untouched"; } || echo "I10($kind): not refused and left untouched ($out)"
  done
  # I11: a copy with a missing local-region marker is refused (LOCAL-SHAPE).
  C=$(mktemp -d "$work/c.XXXXXX"); put_copy "$S" "$C" behind; f=$C/$rel
  grep -v 'proven-cicd:local-next' "$f" > "$work/nomark"; cat "$work/nomark" > "$f"
  "$stampsh" stamp "$f" >/dev/null 2>&1 || true
  out=$(refresh "$S" "$C" "$SUITE_SHA" || true)
  [[ $out == REFUSED:* ]] || echo "I11: copy with no local markers was rewritten ($out)"
  return 0
}

violations=$(run_contract)
if [[ -z $violations ]]; then ok "model: every invariant holds (BEHIND, ABSENT, refusals incl. LEGACY)"
else bad "model violates the contract"; echo "$violations" >&2; fi

# Controls: each mutant of the model must be caught by a named invariant.
control() {
  local mut=$1 want=$2 got
  got=$(MUT=$mut run_contract)
  if grep -q "^$want" <<<"$got"; then ok "control $mut caught by $want"
  else bad "control $mut not caught by $want (got: ${got:-nothing})"; fi
}
control drop-locals I4
control keep-old-pin I5
control keep-old-stamp I3
control write-extra I6
control rewrite-drift I10
control rewrite-ahead I10
control rewrite-legacy I10

# The controls must be real mutants of a passing baseline, not noise.
[[ -z $violations ]] || bad "controls ran against a failing baseline"

echo "proven-install-mode: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
