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
[[ -n ${REQUIRED_JOB_IDS:-} ]] || void 'mandatory job identity set is absent'
declare -A expected=()
expected_count=0
while IFS= read -r name || [[ -n "$name" ]]; do
  [[ -n $name ]] || continue
  [[ $name =~ ^[_a-zA-Z][_a-zA-Z0-9.-]*$ ]] ||
    void "malformed expected job identity: $name"
  [[ ! ${expected[$name]+present} ]] || void "duplicate expected job: $name"
  expected[$name]=1
  expected_count=$((expected_count + 1))
done <<< "$REQUIRED_JOB_IDS"
[[ $expected_count -gt 0 ]] || void 'zero expected mandatory jobs'
declare -A seen=()
count=0
failed=0
not_run=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  [[ "$line" =~ ^([_a-zA-Z][_a-zA-Z0-9.-]*)=([a-z_]+)$ ]] ||
    void "malformed mandatory job observation: $line"
  name=${BASH_REMATCH[1]}
  result=${BASH_REMATCH[2]}
  [[ ${expected[$name]+present} ]] || void "unexpected mandatory job observation: $name"
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
for name in "${!expected[@]}"; do
  [[ ${seen[$name]+present} ]] || void "missing mandatory job observation: $name"
done
[[ "$count" -eq "$expected_count" ]] || void "job cardinality mismatch: observed $count expected $expected_count"
# A known substantive failure takes precedence over other jobs being
# skipped or cancelled; the overall verdict must not erase the failure.
[[ "$failed" -eq 0 ]] || { printf 'FAIL: %s of %s mandatory jobs failed\n' "$failed" "$count" >&2; exit 1; }
[[ "$not_run" -eq 0 ]] || void "$not_run of $count mandatory jobs skipped/cancelled"
printf 'PASS: %s explicitly named mandatory job results are success\n' "$count"
