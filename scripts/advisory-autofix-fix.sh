#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# advisory-autofix-fix.sh — audit every Cargo workspace in a tree and apply
# the lowest patched version for each fixable advisory.
#
# For each workspace dir (advisory-autofix-discover.sh):
#   1. audit it (cargo deny advisories);
#   2. plan (advisory-autofix-plan.sh): `bump` rows run
#        (cd <dir> && cargo update --manifest-path Cargo.toml -p <crate>@<locked> --precise <lowest patched>)
#      `issue` rows are recorded, nothing is changed for them;
#   3. audit again. Anything still failing is recorded as an issue row, so a
#      bump that did not cure the advisory is never presented as a fix.
#
# Writes the JSON report to $REPORT (default advisory-autofix-report.json):
#   { "workspaces": [ { "dir", "bumped": [{id,crate,from,to}],
#                       "issues": [{id,crate,version,reason}],
#                       "clean_after": bool } ], "changed": [ "<dir>/Cargo.lock" ] }
# and leaves the changed Cargo.lock files in the work tree. It never commits.
#
# Environment:
#   AUDIT_CMD   command run as `$AUDIT_CMD <dir>`; must behave like cargo-deny:
#               JSON diagnostics on stderr, exit 0 clean / non-zero failing.
#               Default: cargo deny --format json check advisories. A test
#               substitutes a stand-in oracle here (tests/advisory-autofix.sh).
#   DENY_ARGS   extra cargo-deny global options (default audit only). The default
#               audit and update run INSIDE each workspace directory, so that
#               workspace's own .cargo/config.toml, rust-toolchain and deny.toml
#               apply; paths in DENY_ARGS are therefore relative to the workspace.
#   REPORT      report path.
#   ADVISORY_AUTOFIX_EXCLUDE  see advisory-autofix-discover.sh.
#
# Exit 0: every workspace was audited (findings are in the report, not the
# exit code). Exit 2: an audit could not run (database fetch failed, no
# Cargo.toml beside a Cargo.lock, ...). That is "no check was performed", and
# a caller must treat it as red, never as clean.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="${REPORT:-advisory-autofix-report.json}"
case "$REPORT" in /*) ;; *) REPORT="$PWD/$REPORT" ;; esac

audit() { # <dir> -> stdout: diagnostics (jsonl); returns 0 clean, 1 failing, 2 could not run
  local dir="$1" out rc
  out="$(mktemp)"
  if [ -n "${AUDIT_CMD:-}" ]; then
    set +e; $AUDIT_CMD "$dir" 2>"$out" >/dev/null; rc=$?; set -e
  else
    set +e
    # shellcheck disable=SC2086
    ( cd "$dir" && cargo deny --log-level warn ${DENY_ARGS:-} --format json --manifest-path Cargo.toml check advisories ) 2>"$out" >/dev/null
    rc=$?; set -e
  fi
  cat "$out"
  local n
  n=$(bash "$here/advisory-autofix-plan.sh" <"$out" | grep -c . || true)
  rm -f "$out"
  if [ "$rc" -eq 0 ]; then return 0; fi
  # Non-zero with no advisory finding is not "failing advisories": the audit
  # itself broke (network, database, config). Report it as not performed.
  if [ "$n" -gt 0 ]; then return 1; fi
  return 2
}

mapfile -t dirs < <(bash "$here/advisory-autofix-discover.sh" .)
echo "advisory-autofix: ${#dirs[@]} Cargo workspace(s): ${dirs[*]:-none}" >&2
workspaces='[]'; changed='[]'; broke=0

ROUNDS="${ADVISORY_AUTOFIX_ROUNDS:-4}"

for dir in "${dirs[@]}"; do
  if [ ! -f "$dir/Cargo.toml" ]; then
    echo "::error::$dir/Cargo.lock has no Cargo.toml beside it; its advisories were NOT audited" >&2
    broke=1; continue
  fi
  before="$(sha256sum "$dir/Cargo.lock" | cut -d' ' -f1)"
  bumped='[]'; failed_specs=" "; failed_msgs='{}'
  clean=false; plan=""; unaudited=0
  # Plan, bump, re-audit, up to ROUNDS times. Several advisories on one crate
  # are cured by ONE update to the highest patched version among them (a
  # second `cargo update -p crate@<old>` would no longer match the lockfile).
  # A later round sees whatever the bump left failing, including a new
  # advisory at the new version.
  for ((round = 1; round <= ROUNDS; round++)); do
    set +e; audit_out="$(audit "$dir")"; rc=$?; set -e
    if [ "$rc" -eq 2 ]; then
      echo "::error::cargo-deny could not audit $dir (not an advisory finding); NO CHECK WAS PERFORMED there" >&2
      printf '%s\n' "$audit_out" | tail -n 5 >&2
      unaudited=1; break
    fi
    if [ "$rc" -eq 0 ]; then clean=true; plan=""; break; fi
    plan="$(bash "$here/advisory-autofix-plan.sh" <<<"$audit_out")"
    # one target per crate@locked: the highest, among rows not already failed
    mapfile -t specs < <(awk -F'\t' '$1=="bump"{print $3"@"$4}' <<<"$plan" | sort -u)
    did=0
    for spec in "${specs[@]}"; do
      [ -n "$spec" ] || continue
      case "$failed_specs" in *" $spec "*) continue ;; esac
      crate="${spec%@*}"; ver="${spec#*@}"
      target="$(awk -F'\t' -v c="$crate" -v v="$ver" '$1=="bump" && $3==c && $4==v {print $5}' <<<"$plan" | sort -V | tail -n1)"
      ids="$(awk -F'\t' -v c="$crate" -v v="$ver" '$1=="bump" && $3==c && $4==v {print $2}' <<<"$plan" | sort -u | tr '\n' ' ')"
      echo "advisory-autofix: $dir: cargo update -p $crate@$ver --precise $target ($ids)" >&2
      if err="$(cd "$dir" && cargo update --manifest-path Cargo.toml -p "$crate@$ver" --precise "$target" 2>&1)"; then
        did=1
        bumped="$(jq -c --arg id "${ids% }" --arg c "$crate" --arg f "$ver" --arg t "$target" '. + [{id:$id,crate:$c,from:$f,to:$t}]' <<<"$bumped")"
      else
        printf '%s\n' "$err" >&2
        failed_specs+="$spec "
        failed_msgs="$(jq -c --arg k "$spec" --arg r "cargo update --precise $target failed: $(tail -n 3 <<<"$err" | tr '\n' ' ')" '. + {($k):$r}' <<<"$failed_msgs")"
      fi
    done
    [ "$did" -eq 1 ] || break   # nothing more can be bumped: what remains is final
  done
  if [ "$unaudited" -eq 1 ]; then broke=1; continue; fi
  if [ "$clean" != true ]; then
    # Final state: one more audit, so the report describes the lockfile as left.
    set +e; audit_out="$(audit "$dir")"; rc=$?; set -e
    if [ "$rc" -eq 2 ]; then
      echo "::error::re-audit of $dir could not run; NO CHECK WAS PERFORMED after the bump" >&2; broke=1; continue
    elif [ "$rc" -eq 0 ]; then clean=true; plan=""
    else plan="$(bash "$here/advisory-autofix-plan.sh" <<<"$audit_out")"; fi
  fi
  # Issues are exactly what still fails now, each with an accurate reason.
  issues='[]'
  while IFS=$'\t' read -r action id crate ver _t reason; do
    [ -n "$id" ] || continue
    msg="$reason"
    spec="$crate@$ver"
    if [ "$action" = bump ]; then
      msg="$(jq -r --arg k "$spec" '.[$k] // empty' <<<"$failed_msgs")"
      [ -n "$msg" ] || msg="still failing after $ROUNDS planning round(s): a patched version exists but the bump did not cure it"
    fi
    issues="$(jq -c --arg id "$id" --arg c "$crate" --arg v "$ver" --arg r "$msg" '. + [{id:$id,crate:$c,version:$v,reason:$r}]' <<<"$issues")"
  done <<<"$plan"
  after="$(sha256sum "$dir/Cargo.lock" | cut -d' ' -f1)"
  [ "$before" = "$after" ] || changed="$(jq -c --arg p "$dir/Cargo.lock" '. + [$p]' <<<"$changed")"
  workspaces="$(jq -c --arg d "$dir" --argjson b "$bumped" --argjson i "$issues" --argjson c "$clean" '. + [{dir:$d,bumped:$b,issues:$i,clean_after:$c}]' <<<"$workspaces")"
done

jq -n --argjson w "$workspaces" --argjson c "$changed" '{workspaces:$w, changed:$c}' >"$REPORT"
echo "advisory-autofix: report at $REPORT" >&2
[ "$broke" -eq 0 ] || exit 2
