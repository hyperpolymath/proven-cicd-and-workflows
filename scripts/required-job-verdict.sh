#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
# Fail-closed final verdict over declared GitHub needs.<job>.result values.
# A green summary must never conceal a failed/skipped/cancelled predecessor.
# 0 all mandatory entries success, 1 known failure, 2 NOT RUN/incomplete input.
# The caller must populate REQUIRED_RESULTS from GitHub needs context; this
# script does not independently authenticate a self-reported string.
set -euo pipefail
void() { printf 'NOT RUN: %s\n' "$*" >&2; exit 2; }
[[ -n ${REQUIRED_RESULTS:-} ]] || void 'required job population empty'
declare -A seen=()
count=0
failed=0
not_run=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  [[ "$line" =~ ^([a-zA-Z][a-zA-Z0-9_.-]*)=([a-z_]+)$ ]] ||
    void "malformed mandatory job observation: $line"
  name=${BASH_REMATCH[1]}
  result=${BASH_REMATCH[2]}
  [[ ! ${seen[$name]+present} ]] || void "duplicate job observation: $name"
  seen[$name]=1
  count=$((count + 1))
  case $result in
    success) printf 'ok: required %s completed successfully\n' "$name" ;;
    failure) printf 'FAILED: required %s failed\n' "$name" >&2; failed=$((failed + 1)) ;;
    skipped|cancelled) printf 'NOT RUN: required %s was %s\n' "$name" "$result" >&2; not_run=$((not_run + 1)) ;;
    *) void "unknown/nonterminal result '$result' for required $name" ;;
  esac
done <<< "$REQUIRED_RESULTS"
[[ "$count" -gt 0 ]] || void 'zero mandatory jobs'
[[ "$not_run" -eq 0 ]] || void "$not_run of $count mandatory jobs skipped/cancelled"
[[ "$failed" -eq 0 ]] || { printf 'FAIL: %s of %s mandatory jobs failed\n' "$failed" "$count" >&2; exit 1; }
printf 'PASS: %s explicitly named mandatory job results are success\n' "$count"
