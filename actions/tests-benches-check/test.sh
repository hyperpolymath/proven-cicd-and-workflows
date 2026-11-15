#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Shell-adapter controls. The validator below is deliberately a *test double*:
# this checks the action's routing of outcomes, not Proven-Tests proof validity.
# The normative Rust validator has its OWN adversarial/contract tests upstream.
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v jq >/dev/null || { echo "NO CHECK: jq missing" >&2; exit 2; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
script=actions/tests-benches-check/check.sh

cat > "$work/validator" <<'VALIDATOR'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = emit ] || exit 2
[ -f "$2" ] || exit 2
mode="$(jq -r '.mode' "$2")"
case "$mode" in
  valid)
    printf '{"passed":2,"failed":0,"errors":0,"total":2,"covered_cells":1,"cat_aspect_cells":238}\n' > "$3"
    ;;
  failing)
    printf '{"passed":1,"failed":1,"errors":0,"total":2,"covered_cells":1,"cat_aspect_cells":238}\n' > "$3"
    ;;
  zero)
    printf '{"passed":0,"failed":0,"errors":0,"total":0,"covered_cells":0,"cat_aspect_cells":238}\n' > "$3"
    ;;
  invalid)
    exit 1
    ;;
  void)
    exit 2
    ;;
  inconsistent)
    printf '{"passed":3,"failed":0,"errors":0,"total":1,"covered_cells":1,"cat_aspect_cells":238}\n' > "$3"
    ;;
  *) exit 2 ;;
esac
VALIDATOR
chmod +x "$work/validator"

case_run() {
  local name="$1" expected_rc="$2" expected_status="$3" required="$4" report="$5" validator="$6"
  local rc=0
  : > "$work/out"
  : > "$work/summary"
  TEST_BENCH_REPORT="$report" TEST_BENCH_VALIDATOR="$validator" TEST_BENCH_REQUIRED="$required" \
    GITHUB_OUTPUT="$work/out" GITHUB_STEP_SUMMARY="$work/summary" \
    bash "$script" > "$work/log" 2>&1 || rc=$?
  if [[ "$rc" -ne "$expected_rc" ]] || ! grep -qx "status=$expected_status" "$work/out"; then
    printf 'FAIL %s: rc=%s (wanted %s), outputs:\n' "$name" "$rc" "$expected_rc" >&2
    cat "$work/out" "$work/log" >&2
    exit 1
  fi
  printf 'PASS %s (%s, exit %s)\n' "$name" "$expected_status" "$rc"
}

case_run "absent advisory" 0 not_assessed false "" ""
case_run "absent required" 2 not_assessed true "" ""
case_run "missing file" 2 not_run true "$work/missing.json" "$work/validator"
printf '{"mode":"valid"}\n' > "$work/report.json"
case_run "missing validator" 2 not_run true "$work/report.json" "$work/missing"
case_run "valid strict" 0 validated_report true "$work/report.json" "$work/validator"
grep -qx "passed=2" "$work/out"
grep -qx "covered_cells=1" "$work/out"
for mode in failing zero invalid void inconsistent; do
  printf '{"mode":"%s"}\n' "$mode" > "$work/report.json"
  case "$mode" in
    failing) case_run "subject failed" 1 failed true "$work/report.json" "$work/validator" ;;
    zero) case_run "no executed tests" 1 insufficient true "$work/report.json" "$work/validator" ;;
    invalid) case_run "validator rejected" 1 invalid true "$work/report.json" "$work/validator" ;;
    void) case_run "validator did not run" 2 not_run true "$work/report.json" "$work/validator" ;;
    inconsistent) case_run "counter lie" 1 invalid true "$work/report.json" "$work/validator" ;;
  esac
done
printf '{"mode":"failing"}\n' > "$work/report.json"
case_run "failing advisory remains advisory" 0 failed false "$work/report.json" "$work/validator"
echo "Observer shell controls all exercised"
