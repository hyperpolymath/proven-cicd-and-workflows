#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# smoke: the umbrella's own entry points start and give the right answers on
# this repository (fast, under 30 s).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
GATE=$(bash scripts/proven-gate-bin.sh) || { echo "smoke: proven-gate does not build"; exit 1; }
fail=0
"$GATE" detect . > "${TMPDIR:-/tmp}/proven-smoke-plan.json" 2>/dev/null; rc=$?
[[ $rc -eq 0 ]] || { echo "smoke: this repository's own plan is not ok (rc $rc)"; "$GATE" detect . | jq -r '.errors[]'; fail=1; }
[[ $(jq '.jobs|length' "${TMPDIR:-/tmp}/proven-smoke-plan.json") -gt 0 ]] || { echo "smoke: the plan holds no jobs"; fail=1; }
"$GATE" integrity .github/workflows/proven-self.yml || fail=1
"$GATE" bench-gate 1 --history 1 >/dev/null || fail=1
(( fail == 0 )) && echo "ok - smoke: plan, integrity and bench gate all passed"; exit "$fail"
