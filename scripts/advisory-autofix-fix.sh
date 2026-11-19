#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# advisory-autofix-fix.sh — audit every Cargo workspace in a tree and apply
# the lowest patched version for each fixable advisory.
#
# For each workspace dir (advisory-autofix-discover.sh):
#   1. audit it (cargo deny advisories);
#   2. plan (advisory-autofix-plan.sh): `bump` rows run
#        cargo update --manifest-path <dir>/Cargo.toml -p <crate>@<locked> --precise <lowest patched>
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
#   DENY_ARGS   extra cargo-deny global options (default AUDIT_CMD only).
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
    cargo deny --log-level warn ${DENY_ARGS:-} --format json --manifest-path "$dir/Cargo.toml" check advisories 2>"$out" >/dev/null
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

for dir in "${dirs[@]}"; do
  if [ ! -f "$dir/Cargo.toml" ]; then
    echo "::error::$dir/Cargo.lock has no Cargo.toml beside it; its advisories were NOT audited" >&2
    broke=1; continue
  fi
  before="$(sha256sum "$dir/Cargo.lock" | cut -d' ' -f1)"
  bumped='[]'; issues='[]'
  set +e; plan_in="$(audit "$dir")"; rc=$?; set -e
  if [ "$rc" -eq 2 ]; then
    echo "::error::cargo-deny could not audit $dir (not an advisory finding); NO CHECK WAS PERFORMED there" >&2
    printf '%s\n' "$plan_in" | tail -n 5 >&2
    broke=1; continue
  fi
  if [ "$rc" -eq 1 ]; then
    plan="$(bash "$here/advisory-autofix-plan.sh" <<<"$plan_in")"
    while IFS=$'\t' read -r action id crate ver target reason; do
      [ -n "$action" ] || continue
      if [ "$action" = bump ]; then
        echo "advisory-autofix: $dir: cargo update -p $crate@$ver --precise $target ($id)" >&2
        if err="$(cargo update --manifest-path "$dir/Cargo.toml" -p "$crate@$ver" --precise "$target" 2>&1)"; then
          bumped="$(jq -c --arg id "$id" --arg c "$crate" --arg f "$ver" --arg t "$target" '. + [{id:$id,crate:$c,from:$f,to:$t}]' <<<"$bumped")"
        else
          issues="$(jq -c --arg id "$id" --arg c "$crate" --arg v "$ver" --arg r "cargo update --precise $target failed: $(tail -n 3 <<<"$err" | tr '\n' ' ')" '. + [{id:$id,crate:$c,version:$v,reason:$r}]' <<<"$issues")"
        fi
      else
        issues="$(jq -c --arg id "$id" --arg c "$crate" --arg v "$ver" --arg r "$reason" '. + [{id:$id,crate:$c,version:$v,reason:$r}]' <<<"$issues")"
      fi
    done <<<"$plan"
  fi
  # Re-audit. Whatever still fails and is not already an issue is one now.
  set +e; after_in="$(audit "$dir")"; arc=$?; set -e
  clean=true
  if [ "$arc" -eq 2 ]; then
    echo "::error::re-audit of $dir could not run; NO CHECK WAS PERFORMED after the bump" >&2; broke=1; clean=false
  elif [ "$arc" -eq 1 ]; then
    clean=false
    while IFS=$'\t' read -r _a id crate ver _t reason; do
      [ -n "$id" ] || continue
      jq -e --arg id "$id" --arg c "$crate" 'map(select(.id==$id and .crate==$c)) | length > 0' <<<"$issues" >/dev/null && continue
      issues="$(jq -c --arg id "$id" --arg c "$crate" --arg v "$ver" --arg r "still failing after the bump: $reason" '. + [{id:$id,crate:$c,version:$v,reason:$r}]' <<<"$issues")"
    done < <(bash "$here/advisory-autofix-plan.sh" <<<"$after_in")
  fi
  after="$(sha256sum "$dir/Cargo.lock" | cut -d' ' -f1)"
  [ "$before" = "$after" ] || changed="$(jq -c --arg p "$dir/Cargo.lock" '. + [$p]' <<<"$changed")"
  workspaces="$(jq -c --arg d "$dir" --argjson b "$bumped" --argjson i "$issues" --argjson c "$clean" '. + [{dir:$d,bumped:$b,issues:$i,clean_after:$c}]' <<<"$workspaces")"
done

jq -n --argjson w "$workspaces" --argjson c "$changed" '{workspaces:$w, changed:$c}' >"$REPORT"
echo "advisory-autofix: report at $REPORT" >&2
[ "$broke" -eq 0 ] || exit 2
