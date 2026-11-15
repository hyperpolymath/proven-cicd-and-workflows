#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
# Silence / firing / void controls for the final summary check.
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)/scripts/required-job-verdict.sh
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
export REQUIRED_JOB_IDS= {
  local want=$1 label=$2 data=$3
  local got=0
  REQUIRED_RESULTS="$data" bash --noprofile --norc -e -o pipefail "$script" > "$temp/output" 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL: %s returned %s expected %s\n' "$label" "$got" "$want" >&2
    cat "$temp/output" >&2
    exit 1
  fi
  printf 'ok: %s (exit %s)\n' "$label" "$want"
}
check 0 'silence: two real required successes' $'native=success\npolicy=success'
check 1 'firing: required native test failed' $'native=failure\npolicy=success'
check 1 'firing: required policy failed' $'native=success\npolicy=failure'
check 2 'void: required check skipped' $'native=success\npolicy=skipped'
check 2 'void: required check cancelled' $'native=cancelled\npolicy=success'
check 2 'void: no mandatory jobs' ''
check 2 'void: duplicate required observation' $'native=success\nnative=success'
check 2 'void: unknown status' $'native=success\npolicy=unknown'
check 2 'void: still pending' $'native=success\npolicy=pending'
check 2 'void: malformed observation' 'native success'
check 2 'void: missing expected policy job observation' 'native=success'
check 2 'void: unexpected extra named job'  'ok: verdict cannot make a missing, failed or skipped required job green'
native\npolicy'
check() {
  local want=$1 label=$2 data=$3
  local got=0
  REQUIRED_RESULTS="$data" bash --noprofile --norc -e -o pipefail "$script" > "$temp/output" 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL: %s returned %s expected %s\n' "$label" "$got" "$want" >&2
    cat "$temp/output" >&2
    exit 1
  fi
  printf 'ok: %s (exit %s)\n' "$label" "$want"
}
check 0 'silence: two real required successes' $'native=success\npolicy=success'
check 1 'firing: required native test failed' $'native=failure\npolicy=success'
check 1 'firing: required policy failed' $'native=success\npolicy=failure'
check 2 'void: required check skipped' $'native=success\npolicy=skipped'
check 2 'void: required check cancelled' $'native=cancelled\npolicy=success'
check 2 'void: no mandatory jobs' ''
check 2 'void: duplicate required observation' $'native=success\nnative=success'
check 2 'void: unknown status' $'native=success\npolicy=unknown'
check 2 'void: still pending' $'native=success\npolicy=pending'
check 2 'void: malformed observation' 'native success'
echo 'ok: verdict cannot make a missing, failed or skipped required job green'
native=success\npolicy=success\nrogue=success'
check 2 'void: mismatched required job IDs'  'ok: verdict cannot make a missing, failed or skipped required job green'
native\npolicy'
check() {
  local want=$1 label=$2 data=$3
  local got=0
  REQUIRED_RESULTS="$data" bash --noprofile --norc -e -o pipefail "$script" > "$temp/output" 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL: %s returned %s expected %s\n' "$label" "$got" "$want" >&2
    cat "$temp/output" >&2
    exit 1
  fi
  printf 'ok: %s (exit %s)\n' "$label" "$want"
}
check 0 'silence: two real required successes' $'native=success\npolicy=success'
check 1 'firing: required native test failed' $'native=failure\npolicy=success'
check 1 'firing: required policy failed' $'native=success\npolicy=failure'
check 2 'void: required check skipped' $'native=success\npolicy=skipped'
check 2 'void: required check cancelled' $'native=cancelled\npolicy=success'
check 2 'void: no mandatory jobs' ''
check 2 'void: duplicate required observation' $'native=success\nnative=success'
check 2 'void: unknown status' $'native=success\npolicy=unknown'
check 2 'void: still pending' $'native=success\npolicy=pending'
check 2 'void: malformed observation' 'native success'
echo 'ok: verdict cannot make a missing, failed or skipped required job green'
native=success\n_policy=success'
REQUIRED_JOB_IDS= 'ok: verdict cannot make a missing, failed or skipped required job green'
native\npolicy'
check() {
  local want=$1 label=$2 data=$3
  local got=0
  REQUIRED_RESULTS="$data" bash --noprofile --norc -e -o pipefail "$script" > "$temp/output" 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL: %s returned %s expected %s\n' "$label" "$got" "$want" >&2
    cat "$temp/output" >&2
    exit 1
  fi
  printf 'ok: %s (exit %s)\n' "$label" "$want"
}
check 0 'silence: two real required successes' $'native=success\npolicy=success'
check 1 'firing: required native test failed' $'native=failure\npolicy=success'
check 1 'firing: required policy failed' $'native=success\npolicy=failure'
check 2 'void: required check skipped' $'native=success\npolicy=skipped'
check 2 'void: required check cancelled' $'native=cancelled\npolicy=success'
check 2 'void: no mandatory jobs' ''
check 2 'void: duplicate required observation' $'native=success\nnative=success'
check 2 'void: unknown status' $'native=success\npolicy=unknown'
check 2 'void: still pending' $'native=success\npolicy=pending'
check 2 'void: malformed observation' 'native success'
echo 'ok: verdict cannot make a missing, failed or skipped required job green'
native\n_policy' check 0 'silence: underscore-prefixed job identity'  'ok: verdict cannot make a missing, failed or skipped required job green'
native\npolicy'
check() {
  local want=$1 label=$2 data=$3
  local got=0
  REQUIRED_RESULTS="$data" bash --noprofile --norc -e -o pipefail "$script" > "$temp/output" 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL: %s returned %s expected %s\n' "$label" "$got" "$want" >&2
    cat "$temp/output" >&2
    exit 1
  fi
  printf 'ok: %s (exit %s)\n' "$label" "$want"
}
check 0 'silence: two real required successes' $'native=success\npolicy=success'
check 1 'firing: required native test failed' $'native=failure\npolicy=success'
check 1 'firing: required policy failed' $'native=success\npolicy=failure'
check 2 'void: required check skipped' $'native=success\npolicy=skipped'
check 2 'void: required check cancelled' $'native=cancelled\npolicy=success'
check 2 'void: no mandatory jobs' ''
check 2 'void: duplicate required observation' $'native=success\nnative=success'
check 2 'void: unknown status' $'native=success\npolicy=unknown'
check 2 'void: still pending' $'native=success\npolicy=pending'
check 2 'void: malformed observation' 'native success'
echo 'ok: verdict cannot make a missing, failed or skipped required job green'
native=success\n_policy=success'
check 2 'void: required identity manifest missing'  'ok: verdict cannot make a missing, failed or skipped required job green'
native\npolicy'
check() {
  local want=$1 label=$2 data=$3
  local got=0
  REQUIRED_RESULTS="$data" bash --noprofile --norc -e -o pipefail "$script" > "$temp/output" 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL: %s returned %s expected %s\n' "$label" "$got" "$want" >&2
    cat "$temp/output" >&2
    exit 1
  fi
  printf 'ok: %s (exit %s)\n' "$label" "$want"
}
check 0 'silence: two real required successes' $'native=success\npolicy=success'
check 1 'firing: required native test failed' $'native=failure\npolicy=success'
check 1 'firing: required policy failed' $'native=success\npolicy=failure'
check 2 'void: required check skipped' $'native=success\npolicy=skipped'
check 2 'void: required check cancelled' $'native=cancelled\npolicy=success'
check 2 'void: no mandatory jobs' ''
check 2 'void: duplicate required observation' $'native=success\nnative=success'
check 2 'void: unknown status' $'native=success\npolicy=unknown'
check 2 'void: still pending' $'native=success\npolicy=pending'
check 2 'void: malformed observation' 'native success'
echo 'ok: verdict cannot make a missing, failed or skipped required job green'
native=success\npolicy=success'
echo 'ok: verdict cannot make a missing, failed or skipped required job green'
native\npolicy'
check() {
  local want=$1 label=$2 data=$3
  local got=0
  REQUIRED_RESULTS="$data" bash --noprofile --norc -e -o pipefail "$script" > "$temp/output" 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    printf 'FAIL: %s returned %s expected %s\n' "$label" "$got" "$want" >&2
    cat "$temp/output" >&2
    exit 1
  fi
  printf 'ok: %s (exit %s)\n' "$label" "$want"
}
check 0 'silence: two real required successes' $'native=success\npolicy=success'
check 1 'firing: required native test failed' $'native=failure\npolicy=success'
check 1 'firing: required policy failed' $'native=success\npolicy=failure'
check 2 'void: required check skipped' $'native=success\npolicy=skipped'
check 2 'void: required check cancelled' $'native=cancelled\npolicy=success'
check 2 'void: no mandatory jobs' ''
check 2 'void: duplicate required observation' $'native=success\nnative=success'
check 2 'void: unknown status' $'native=success\npolicy=unknown'
check 2 'void: still pending' $'native=success\npolicy=pending'
check 2 'void: malformed observation' 'native success'
echo 'ok: verdict cannot make a missing, failed or skipped required job green'
