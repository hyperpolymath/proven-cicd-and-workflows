#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
#
# Install the language gates into every local estate clone that needs them,
# as THIN CALLERS of this repository's reusable workflows, pinned at this
# clone's origin/main. Per repository, by what the tree contains:
#
#   Cargo.toml (outside target/)        -> rust-ci.yml (REPLACES a caller of
#                                          standards' rust-ci-reusable, the
#                                          2026-09-29 red) + creusot-gate.yml
#   .gpr with .ads/.adb SPARK_Mode On   -> spark-gate.yml
#   relational Scheme (run*/fresh/conde
#   over a miniKanren) or a Rust kanren
#   crate                               -> kanren-gate.yml
#   .agda file                          -> agda-gate.yml
#   Coq .v file (Coq sentences: Require,
#   Definition, Lemma, Qed. ..; a file
#   with endmodule is Verilog)          -> rocq-gate.yml
#   .lean file outside any Lake project -> lean-axioms-gate.yml
#   .tla file                           -> tla-gate.yml
#
# The four prover gates (agda, rocq, lean-axioms, tla) default to the layout of
# hvn-dehallucinator. A caller written for another layout must set the inputs
# its template lists; until it does, the detect job fails loudly rather than
# stay green over sources it cannot find.
#
# Each caller is de-onboarded from actions.lock (scripts/deonboard-workflow.sh,
# needs mikefarah yq v4), and templates/track-estate-audit.yml is (re)written
# so the weekly bot moves every cicd-suite pin. Files are written, not
# committed: review and commit per repository.
#
#   CICD_SUITE=/path/to/cicd-suite HYPER_REPOS=/path/to/clones ./rollout_language_gates.sh
set -euo pipefail

suite="${CICD_SUITE:-/home/hyperpolymath/developer/hyper-repos/cicd-suite}"
repos="${HYPER_REPOS:-/home/hyperpolymath/developer/hyper-repos}"

git -C "$suite" fetch --quiet origin main
sha=$(git -C "$suite" rev-parse origin/main)
for wf in rust-ci creusot-gate spark-gate kanren-gate agda-gate rocq-gate lean-axioms-gate tla-gate; do
  if ! git -C "$suite" show "$sha:.github/workflows/$wf.yml" 2>/dev/null | grep -qE '^[[:space:]]+workflow_call:'; then
    echo "cicd-suite ${sha:0:7}: .github/workflows/$wf.yml has no workflow_call trigger; refusing to roll out." >&2
    exit 1
  fi
done
echo "Installing language-gate callers (cicd-suite ${sha:0:7}) into $repos/* ..."

install_caller() { # <repo> <template> <workflow name>
  local repo="$1" tpl="$2" name="$3"
  mkdir -p "$repo/.github/workflows"
  sed "s/__CICD_SUITE_SHA__/$sha/" "$suite/templates/$tpl" > "$repo/.github/workflows/$name"
  "$suite/scripts/deonboard-workflow.sh" "$repo" ".github/workflows/$name"
  echo "   wrote .github/workflows/$name"
}

has_cargo()  { find "$1" -name Cargo.toml -not -path '*/target/*' -not -path '*/.git/*' | grep -q .; }
has_spark()  { find "$1" -name '*.gpr' -not -path '*/.git/*' | grep -q . \
               && grep -rlE --include='*.ads' --include='*.adb' 'SPARK_Mode[[:space:]]*(=>|\()[[:space:]]*On' "$1" 2>/dev/null | grep -q .; }
has_kanren() { grep -rlE --include='*.scm' --include='*.ss' --include='*.sls' --include='*.sld' --include='*.rkt' \
                 '\((run\*?[[:space:]]|fresh[[:space:]]*\(|conde[[:space:]])' "$1" 2>/dev/null \
                 | xargs -r grep -liE 'minikanren|mini-kanren|microkanren|mk\.scm' 2>/dev/null | grep -q . \
               || grep -rlE --include=Cargo.toml '^[[:space:]]*(canrun|ukanren|kanren|mukanren|minikanren)[[:space:]]*=' "$1" 2>/dev/null | grep -q .; }

# Trees the prover gates never look in: fetched dependencies and build output.
prune_find() { find "$1" \( -name .git -o -name _build -o -name build -o -name target -o -name node_modules -o -name .cicd-suite -o -name .lake \) -prune -o "${@:2}"; }
has_agda() { [ -n "$(prune_find "$1" -type f -name '*.agda' -print | head -n 1)" ]; }
# Coq-specific sentences only, so prose in a Verilog comment ("Definition of the
# interface") does not match; and a file with `endmodule` is Verilog, whatever
# its comments say.
coq_marker='^[[:space:]]*(Require[[:space:]]+(Import|Export)[[:space:]]|Require[[:space:]]+[A-Za-z_][A-Za-z0-9_'"'"']*(\.[A-Za-z0-9_'"'"']+)+\.[[:space:]]*$|From[[:space:]]+[A-Za-z0-9_.]+[[:space:]]+Require[[:space:]]|(Definition|Lemma|Theorem|Fixpoint|Inductive)[[:space:]]+[A-Za-z_][A-Za-z0-9_'"'"']*[[:space:]]*(:|:=|\()|Print[[:space:]]+Assumptions[[:space:]]+[A-Za-z_][A-Za-z0-9_.'"'"']*[[:space:]]*\.|Qed\.[[:space:]]*$|Proof\.)'
has_rocq() {
  local f
  while IFS= read -r -d '' f; do
    grep -qE '^[[:space:]]*endmodule' "$f" 2>/dev/null && continue
    grep -qE "$coq_marker" "$f" 2>/dev/null && return 0
  done < <(prune_find "$1" -type f -name '*.v' -print0)
  return 1
}
has_tla()   { [ -n "$(prune_find "$1" -type f -name '*.tla' -print | head -n 1)" ]; }
# A .lean file counts when no lakefile sits in its directory or above it: Lake
# projects are proof-runner-check's, not lean-axioms-gate's.
has_lean() {
  local root="$1" f d
  while IFS= read -r f; do
    d="$(dirname "$f")"
    while :; do
      if [ -f "$d/lakefile.lean" ] || [ -f "$d/lakefile.toml" ]; then break; fi
      if [ "$d" = "$root" ] || [ "$d" = / ] || [ "$d" = . ]; then return 0; fi
      d="$(dirname "$d")"
    done
  done < <(prune_find "$root" -type f -name '*.lean' -print)
  return 1
}

for repo in "$repos"/*; do
  [ -d "$repo/.git" ] || continue
  [ "$(basename "$repo")" != "cicd-suite" ] || continue
  echo "== $repo"
  any=0
  if has_cargo "$repo"; then
    install_caller "$repo" rust-ci-caller.yml rust-ci.yml
    install_caller "$repo" creusot-gate-caller.yml creusot-gate.yml
    any=1
  fi
  if has_spark "$repo"; then install_caller "$repo" spark-gate-caller.yml spark-gate.yml; any=1; fi
  if has_kanren "$repo"; then install_caller "$repo" kanren-gate-caller.yml kanren-gate.yml; any=1; fi
  if has_agda "$repo"; then install_caller "$repo" agda-gate-caller.yml agda-gate.yml; any=1; fi
  if has_rocq "$repo"; then install_caller "$repo" rocq-gate-caller.yml rocq-gate.yml; any=1; fi
  if has_lean "$repo"; then install_caller "$repo" lean-axioms-gate-caller.yml lean-axioms-gate.yml; any=1; fi
  if has_tla "$repo"; then install_caller "$repo" tla-gate-caller.yml tla-gate.yml; any=1; fi
  if [ "$any" -eq 1 ]; then
    cp "$suite/templates/track-estate-audit.yml" "$repo/.github/workflows/track-estate-audit.yml"
    echo "   wrote .github/workflows/track-estate-audit.yml (tracks every cicd-suite pin)"
  else
    echo "   nothing to gate"
  fi
done

echo "Rollout complete. Commit per repository after review."
