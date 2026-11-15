#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Read-only observer. The Proven-Tests Rust validator is a separate,
# independently pinned executable; this action does not reimplement proof
# checks and does not claim that a JSON document authenticates its producer.
set -uo pipefail

report=${TEST_BENCH_REPORT:-}
validator=${TEST_BENCH_VALIDATOR:-}
required=${TEST_BENCH_REQUIRED:-false}

record() {
  local status="$1" message="$2"
  printf 'test-evidence: %s: %s\n' "$status" "$message"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'status=%s\n' "$status" >> "$GITHUB_OUTPUT"
  fi
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf 'Test evidence: **%s** — %s\n' "$status" "$message" >> "$GITHUB_STEP_SUMMARY"
  fi
}

case "$required" in
  true|false) ;;
  *) record not_run "require-evidence must be true or false"; exit 2 ;;
esac

if [[ -z "$report" ]]; then
  record not_assessed "No Proven-Tests run report supplied; no tests or benchmarks measured"
  if [[ "$required" == true ]]; then exit 2; fi
  exit 0
fi

if [[ ! -r "$report" || ! -f "$report" ]]; then
  record not_run "Requested run report is missing or unreadable"
  exit 2
fi

if [[ -z "$validator" || ! -f "$validator" || ! -x "$validator" ]]; then
  record not_run "A runnable, pinned Proven-Tests validator is required when reporting evidence"
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  record not_run "jq is unavailable to read the validator's derived summary"
  exit 2
fi

derived="$(mktemp)" || { record not_run "Cannot allocate derived summary"; exit 2; }
trap 'rm -f "$derived"' EXIT
rc=0
"$validator" emit "$report" "$derived" || rc=$?
if [[ "$rc" != 0 ]]; then
  if [[ "$rc" == 1 ]]; then
    record invalid "Proven-Tests validator rejected the submitted document"
    exit 1
  fi
  record not_run "Proven-Tests validator did not complete (exit $rc)"
  exit 2
fi

# Interpret the independently derived counters, not fields copied from the
# submitted report. Schema and tier correctness belong to proven-evidence.
if ! jq -e '
  (.passed | type == "number") and
  (.failed | type == "number") and
  (.errors | type == "number") and
  (.total | type == "number") and
  (.covered_cells | type == "number") and
  (.cat_aspect_cells | type == "number") and
  ([.passed, .failed, .errors, .total, .covered_cells, .cat_aspect_cells]
    | all(. >= 0 and . == floor)) and
  (.total >= .passed + .failed + .errors) and
  (.covered_cells <= .cat_aspect_cells)
' "$derived" >/dev/null 2>&1; then
  record invalid "Validator emitted malformed or inconsistent derived counters"
  exit 1
fi

passed="$(jq -r '.passed' "$derived")"
failed="$(jq -r '.failed' "$derived")"
errors="$(jq -r '.errors' "$derived")"
total="$(jq -r '.total' "$derived")"
cells="$(jq -r '.covered_cells' "$derived")"
denom="$(jq -r '.cat_aspect_cells' "$derived")"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'passed=%s\ncovered_cells=%s\n' "$passed" "$cells" >> "$GITHUB_OUTPUT"
fi

if (( total == 0 || passed == 0 )); then
  record insufficient "Document validated but no passing executed tests ($passed/$total); benchmarks not assessed"
  if [[ "$required" == true ]]; then exit 1; fi
  exit 0
fi
if (( failed > 0 || errors > 0 )); then
  record failed "Document validates, but $failed failures and $errors errors remain ($passed/$total passed); benchmarks not assessed"
  if [[ "$required" == true ]]; then exit 1; fi
  exit 0
fi

record validated_report "Derived $passed/$total passing tests, $cells/$denom occupied taxonomy cells; execution provenance and benchmarks are separately unassessed"
exit 0
