#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# p2p: the seam between the planner and the runner. A plan produced by
# proven-gate detect is executed by proven-run.sh exactly as the workflow does,
# on a throwaway repository: a passing command passes, a failing one fails,
# and a plan with a missing runner is refused before anything runs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE=$(bash "$ROOT/scripts/proven-gate-bin.sh") || { echo "p2p: proven-gate does not build"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
mkdir -p "$W/r" && ( cd "$W/r" && git init -q . )
printf 'schema = "proven/manifest/v1"\n[categories.unit.shell]\ncommand = "echo ok: unit seam"\n[categories.smoke.shell]\ncommand = "echo ok: smoke seam"\n[categories.build.shell]\ncommand = "true"\n[categories.p2p.shell]\ncommand = "false"\n' > "$W/r/.proven.toml"
echo 'echo' > "$W/r/a.sh"; ( cd "$W/r" && git add -A )
plan=$("$GATE" detect "$W/r") || { echo "p2p: plan refused"; exit 1; }
passed=0 failed=0
while IFS=$'\t' read -r cat lang dir cmd; do
  if bash "$ROOT/scripts/proven-run.sh" "$cat" "$lang" "$W/r/$dir" "$cmd" >/dev/null 2>&1; then passed=$((passed+1)); else failed=$((failed+1)); fi
done < <(jq -r '.jobs[]|[.category,.lang,.dir,.command]|@tsv' <<<"$plan")
[[ $passed -eq 3 && $failed -eq 1 ]] || { echo "p2p: expected 3 pass, 1 fail; got $passed, $failed"; fail=1; }
# node prep is lockfile-aware and fails closed without a lockfile; a bun.lock needs BUN_VERSION
mkdir -p "$W/n"
bash "$ROOT/scripts/proven-run.sh" unit node "$W/n" "echo ok: x" >/dev/null 2>&1 && { echo "p2p: node with no lockfile passed"; fail=1; }
: > "$W/n/bun.lock"
( unset BUN_VERSION; PATH=/usr/bin:/bin bash "$ROOT/scripts/proven-run.sh" unit node "$W/n" "echo ok: x" >/dev/null 2>&1 ) && { echo "p2p: bun lane ran without BUN_VERSION or bun"; fail=1; }
# zero-test parsers beyond the original five: a silent zig or shell run is not a pass, a counted one is
bash "$ROOT/scripts/proven-run.sh" unit zig "$W/r" "echo hi" >/dev/null 2>&1 && { echo "p2p: a zig run with no test count passed"; fail=1; }
bash "$ROOT/scripts/proven-run.sh" unit zig "$W/r" "echo All 3 tests passed." >/dev/null 2>&1 || { echo "p2p: a counted zig run failed"; fail=1; }
bash "$ROOT/scripts/proven-run.sh" unit all "$W/r" "echo hi" >/dev/null 2>&1 && { echo "p2p: a repo-wide run with no test count passed"; fail=1; }
bash "$ROOT/scripts/proven-run.sh" unit all "$W/r" "echo 1..4" >/dev/null 2>&1 || { echo "p2p: a counted repo-wide run failed"; fail=1; }
printf 'schema = "proven/manifest/v1"\n' > "$W/r/.proven.toml"
"$GATE" detect "$W/r" >/dev/null 2>&1 && { echo "p2p: a plan with no runners was accepted"; fail=1; }
(( fail == 0 )) && echo "ok - p2p: every seam check passed"; exit "$fail"
