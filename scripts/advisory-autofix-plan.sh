#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# advisory-autofix-plan.sh — turn `cargo deny --format json check advisories`
# output (read on stdin; cargo-deny writes it to stderr) into a bump plan.
#
# One TSV line per failing advisory:
#   <action> <TAB> <advisory-id> <TAB> <crate> <TAB> <locked-version> <TAB> <target-or-"-"> <TAB> <reason>
# action is `bump` (target = the LOWEST patched version that is semver-
# compatible with the locked one, for `cargo update -p crate@locked --precise
# target`) or `issue` (nothing automatic is possible; reason says why:
# no patched version, patched only across a major, or an unparseable solution).
#
# WHY THE SOLUTION NOTE. cargo-deny's JSON carries the patched ranges only as
# the free-text note "Solution: Upgrade to >=A, <B OR >=C (try `cargo update
# -p x`)" or "No safe upgrade is available!". This parser is therefore
# deliberately conservative: anything it does not understand becomes an
# `issue`, never a guessed bump. The format is pinned by recorded real output
# in tests/fixtures/advisory-autofix/.
#
# Only error-level advisory diagnostics are planned (the ones that turn
# `cargo deny check advisories` red); warnings are the owner's deny.toml
# policy and are left alone.
set -euo pipefail
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

# compat <locked> <target>: is <target> reachable by `cargo update` (same
# semver-compatible lineage as <locked>)?
compat() {
  local l="${1%%[-+]*}" t="${2%%[-+]*}" la lb lc ta tb tc
  IFS=. read -r la lb lc <<<"$l"; IFS=. read -r ta tb tc <<<"$t"
  if [ "${la:-0}" != 0 ]; then [ "$la" = "${ta:-}" ]
  elif [ "${lb:-0}" != 0 ]; then [ "${ta:-}" = 0 ] && [ "$lb" = "${tb:-}" ]
  else [ "${ta:-}" = 0 ] && [ "${tb:-}" = 0 ] && [ "${lc:-0}" = "${tc:-}" ]; fi
}
lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }

jq -cR 'fromjson? | select(.type == "diagnostic" and .fields.severity == "error" and (.fields.advisory != null))
  | {id: .fields.advisory.id, crate: .fields.advisory.package,
     version: (.fields.graphs[0].Krate.version // ""),
     solution: ((.fields.notes // []) | map(select(startswith("Solution:"))) | first // "")}' |
sort -u |
while IFS= read -r row; do
  id=$(jq -r .id <<<"$row"); crate=$(jq -r .crate <<<"$row")
  ver=$(jq -r .version <<<"$row"); sol=$(jq -r .solution <<<"$row")
  if [ -z "$ver" ] || [ -z "$crate" ]; then
    printf 'issue\t%s\t%s\t%s\t-\tcould not read the affected crate/version from the audit output\n' "$id" "${crate:--}" "${ver:--}"; continue
  fi
  case "$sol" in
    "") printf 'issue\t%s\t%s\t%s\t-\tno solution given in the audit output (no patched version published)\n' "$id" "$crate" "$ver"; continue ;;
    *"No safe upgrade"*) printf 'issue\t%s\t%s\t%s\t-\tno patched version exists\n' "$id" "$crate" "$ver"; continue ;;
  esac
  req="${sol#Solution: Upgrade to }"; req="${req%% (try*}"
  best=""; strict=0
  while IFS= read -r alt; do
    lower=""
    IFS=',' read -ra cmps <<<"$alt"
    for c in "${cmps[@]}"; do
      c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"
      case "$c" in
        '>='[0-9]*) lower="${c#>=}" ;;
        '>'[0-9]*) strict=1 ;;
      esac
    done
    [ -n "$lower" ] || continue
    lt "$ver" "$lower" || continue
    compat "$ver" "$lower" || continue
    if [ -z "$best" ] || lt "$lower" "$best"; then best="$lower"; fi
  done < <(sed 's/ OR /\n/g' <<<"$req")
  if [ -n "$best" ]; then
    printf 'bump\t%s\t%s\t%s\t%s\tlowest patched version compatible with %s\n' "$id" "$crate" "$ver" "$best" "$ver"
  elif [ "$strict" = 1 ]; then
    printf 'issue\t%s\t%s\t%s\t-\tpatched range uses a strict lower bound (%s); the lowest patched version cannot be derived\n' "$id" "$crate" "$ver" "$req"
  else
    printf 'issue\t%s\t%s\t%s\t-\tno patched version is semver-compatible with %s (needs a manifest change or a major bump): %s\n' "$id" "$crate" "$ver" "$ver" "$req"
  fi
done
