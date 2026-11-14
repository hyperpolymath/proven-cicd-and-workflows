#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven-coverage-collect.sh detect WORKSPACE
# proven-coverage-collect.sh collect WORKSPACE [STAMPED_WORKFLOW]
#
# The consumer side of the proven coverage collector (increment three of
# Hypatia's proven-coverage design). The stamped workflow
# (templates/proven-coverage-collect.yml) fetches this repository at its pinned
# SHA, verifies the commit, and runs this script from that checkout.
#
# SHADOW ONLY. This script collects. It never judges a coverage number: Hypatia
# does that (`mix hypatia.coverage.report`). It exits 1 never. A language it
# cannot measure, a tool that fails and a test run that fails are each reported
# with a reason and the run still exits 0.
#
#   detect   print rust=, elixir= and js= (true|false), one per line, for
#            $GITHUB_OUTPUT. Cheap: Cargo.toml, mix.exs, package.json at the root.
#   collect  for each detected language, one raw run (all tests) and one proven
#            run (a subset), writing under WORKSPACE/.proven-coverage/:
#              .proven-coverage/<raw|proven>/llvm.json      Rust, cargo llvm-cov --json
#              .proven-coverage/<raw|proven>/elixir.lcov    Elixir, Mix :cover data as LCOV
#              .proven-coverage/<raw|proven>/js.lcov        JS, c8 lcovonly
#              <report>.meta.json              sidecar, schema
#                                              hypatia.proven-coverage.report-meta/1
#              .proven-coverage/collect-report.json         what was collected, and why not
#              .proven-coverage/summary.md                  the same, as a table
#            The summary is also appended to $GITHUB_STEP_SUMMARY when set.
#
# Environment. GITHUB_REPOSITORY and GITHUB_SHA are required (the sidecar is
# refused by Hypatia without them, and nothing is invented). GITHUB_RUN_ID is
# shared by the raw and proven runs; without it the run id is local-<sha>.
#   PROVEN_COV_RUST_TOOLCHAIN       default stable; `--branch` only when it starts with nightly
#   PROVEN_COV_RUST_PROVEN_FILTER   default prop_ (test-name substring of the proven run)
#   PROVEN_COV_JS_RAW_TESTS         default test/**/*.test.js (space separated globs for node --test)
#   PROVEN_COV_JS_PROVEN_TESTS      default test/**/props.test.js
#
# The last line printed is PROVEN_COVERAGE_CLASS=<class>:
#   collected            exit 0: every detected language was attempted; see the
#                        summary for any report that is missing and why
#   nothing_to_collect   exit 0: no Cargo.toml, mix.exs or package.json
#   not_run:<why>        exit 2: usage, jq, env or drift. The job fails: the
#                        collector itself could not run.
set -uo pipefail

suite=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-} workspace=${2:-} stamped=${3:-}
readonly artifact=proven-coverage-collect
readonly c8_version=10.1.3

finish() { local class=$1 code=$2; echo "PROVEN_COVERAGE_CLASS=$class"; exit "$code"; }

[[ -d $workspace ]] || { echo "usage: proven-coverage-collect.sh detect|collect WORKSPACE [STAMPED_WORKFLOW]" >&2; finish not_run:usage 2; }
workspace=$(cd "$workspace" && pwd)

has_rust() { [[ -f $workspace/Cargo.toml ]]; }
has_elixir() { [[ -f $workspace/mix.exs ]]; }
has_js() { [[ -f $workspace/package.json ]]; }

if [[ $mode == detect ]]; then
  for l in rust elixir js; do
    if "has_$l"; then echo "$l=true"; else echo "$l=false"; fi
  done
  exit 0
fi
[[ $mode == collect ]] || { echo "usage: proven-coverage-collect.sh detect|collect WORKSPACE [STAMPED_WORKFLOW]" >&2; finish not_run:usage 2; }

command -v jq >/dev/null || { echo "proven-coverage-collect: jq missing" >&2; finish not_run:toolchain 2; }
[[ -n ${GITHUB_REPOSITORY:-} && ${GITHUB_SHA:-} =~ ^[0-9a-fA-F]{40}$ ]] ||
  { echo "proven-coverage-collect: GITHUB_REPOSITORY and a 40-hex GITHUB_SHA are required" >&2; finish not_run:env 2; }
run_id=${GITHUB_RUN_ID:-local-$GITHUB_SHA}

# A copy whose body no longer matches its stamp is not the proven content.
if [[ -n $stamped ]]; then
  rc=0; bash "$suite/scripts/proven-stamp.sh" check "$workspace/$stamped" >&2 || rc=$?
  [[ $rc == 0 ]] || finish not_run:drift 2
fi
version=
[[ -n $stamped && -f $workspace/$stamped ]] &&
  version=$(head -n 1 "$workspace/$stamped" | sed -n 's/^# proven-cicd: [^@]*@\([^ ]*\) .*/\1/p')

cov=$workspace/.proven-coverage
# Only the collector-owned directory is removed; a consumer's own cov/ is never touched.
rm -rf -- "$cov"; mkdir -p "$cov/raw" "$cov/proven"
rows=$(mktemp); trap 'rm -f -- "$rows"' EXIT
log() { echo "proven-coverage-collect: $*" >&2; }

# sidecar REPORT ROLE TOOL TOOL_VERSION
sidecar() {
  local report=$1 role=$2 tool=$3 ver=$4
  jq -n --arg repo "$GITHUB_REPOSITORY" --arg commit "$GITHUB_SHA" --arg run "$run_id" \
    --arg role "$role" --arg tool "$tool" --arg ver "$ver" \
    '{schema: "hypatia.proven-coverage.report-meta/1", repo: $repo, commit: $commit,
      run_id: $run, role: $role, tool: $tool, tool_version: $ver}' > "$report.meta.json"
}
# row LANGUAGE STATUS RAW PROVEN REASON  (RAW/PROVEN: report path or empty)
row() {
  local lang=$1 status=$2 raw=$3 proven=$4 why=$5
  jq -cn --arg l "$lang" --arg s "$status" --arg r "$raw" --arg p "$proven" --arg why "$why" \
  '{language: $l, status: $s, raw: (if $r == "" then null else $r end),
    proven: (if $p == "" then null else $p end), reason: (if $why == "" then null else $why end)}' >> "$rows"; }

reasons=
note() { local why=$1; reasons+="${reasons:+; }$why"; }

collect_rust() {
  local tc=${PROVEN_COV_RUST_TOOLCHAIN:-stable} filter=${PROVEN_COV_RUST_PROVEN_FILTER:-prop_}
  local raw= proven= ver rc args=(--workspace --json)
  reasons=
  command -v cargo >/dev/null && cargo llvm-cov --version >/dev/null 2>&1 || { row rust not_measured "" "" "cargo-llvm-cov is not installed"; return; }
  ver=$(cargo llvm-cov --version | awk '{print $2}')
  [[ -f $workspace/Cargo.lock ]] && args+=(--locked)
  [[ $tc == nightly* ]] && args+=(--branch)
  rc=0; (cd "$workspace" && cargo llvm-cov "${args[@]}" --output-path "$cov/raw/llvm.json") >&2 || rc=$?
  if [[ $rc == 0 && -s $cov/raw/llvm.json ]] && jq -e . "$cov/raw/llvm.json" >/dev/null 2>&1; then
    raw=.proven-coverage/raw/llvm.json; sidecar "$cov/raw/llvm.json" raw cargo-llvm-cov "$ver"
  else rm -f "$cov/raw/llvm.json"; note "raw run exited $rc (build or test failure)"; fi
  rc=0; (cd "$workspace" && cargo llvm-cov "${args[@]}" --output-path "$cov/proven/llvm.json" -- "$filter") >&2 || rc=$?
  if [[ $rc == 0 && -s $cov/proven/llvm.json ]] && jq -e . "$cov/proven/llvm.json" >/dev/null 2>&1; then
    proven=.proven-coverage/proven/llvm.json; sidecar "$cov/proven/llvm.json" proven cargo-llvm-cov "$ver"
  else rm -f "$cov/proven/llvm.json"; note "proven run (filter $filter) exited $rc"; fi
  row rust "$([[ -n $raw && -n $proven ]] && echo collected || echo partial)" "$raw" "$proven" "$reasons"
}

collect_elixir() {
  local raw= proven= ver rc conv=$suite/scripts/coverdata-to-lcov.exs run
  reasons=
  command -v mix >/dev/null || { row elixir not_measured "" "" "mix is not installed"; return; }
  [[ -f $conv ]] || { row elixir not_measured "" "" "converter scripts/coverdata-to-lcov.exs missing"; return; }
  (cd "$workspace" && mix deps.get) >&2 || true
  ver=$(cd "$workspace" && MIX_ENV=test mix run --no-start "$conv" --tools-version 2>/dev/null | tail -n 1)
  [[ -n $ver ]] || ver=unknown
  for run in raw proven; do
    local only=() out=
    [[ $run == proven ]] && only=(--only proven)
    # A stale export from an earlier run must never be converted: delete it first,
    # and convert only a file this invocation created.
    rm -f -- "$workspace/cover/$run.coverdata"
    rc=0; (cd "$workspace" && MIX_ENV=test mix test --cover "${only[@]}" --export-coverage "$run") >&2 || rc=$?
    if [[ -s $workspace/cover/$run.coverdata ]]; then
      if (cd "$workspace" && MIX_ENV=test mix run --no-start "$conv" "cover/$run.coverdata" "$cov/$run/elixir.lcov") >&2 &&
         grep -q '^SF:' "$cov/$run/elixir.lcov"; then
        sidecar "$cov/$run/elixir.lcov" "$run" erlang-cover "$ver"
        out=.proven-coverage/$run/elixir.lcov
        [[ $rc == 0 ]] || note "$run: mix test exited $rc (report kept)"
      else note "$run: conversion to LCOV failed"; fi
    else note "$run: no fresh coverdata (mix test exited $rc)"; fi
    if [[ $run == raw ]]; then raw=$out; else proven=$out; fi
  done
  row elixir "$([[ -n $raw && -n $proven ]] && echo collected || echo partial)" "$raw" "$proven" "$reasons"
}

collect_js() {
  local raw_g=${PROVEN_COV_JS_RAW_TESTS:-test/**/*.test.js} proven_g=${PROVEN_COV_JS_PROVEN_TESTS:-test/**/props.test.js}
  local raw= proven= rc run globs out
  reasons=
  command -v npx >/dev/null && command -v node >/dev/null || { row js not_measured "" "" "node or npx is not installed"; return; }
  for run in raw proven; do
    if [[ $run == raw ]]; then globs=$raw_g; else globs=$proven_g; fi
    local tmp; tmp=$(mktemp -d); out=
    set -f
    # shellcheck disable=SC2086
    rc=0; (cd "$workspace" && npx --yes "c8@$c8_version" --reporter=lcovonly --report-dir="$tmp/report" \
      --temp-directory="$tmp/v8" node --test $globs) >&2 || rc=$?
    set +f
    if [[ -s $tmp/report/lcov.info ]] && grep -q '^SF:' "$tmp/report/lcov.info"; then
      cp "$tmp/report/lcov.info" "$cov/$run/js.lcov"; sidecar "$cov/$run/js.lcov" "$run" c8 "$c8_version"
      out=.proven-coverage/$run/js.lcov
      [[ $rc == 0 ]] || note "$run: node --test exited $rc (report kept)"
    else note "$run: no report (node --test $globs exited $rc)"; fi
    rm -rf -- "$tmp"
    if [[ $run == raw ]]; then raw=$out; else proven=$out; fi
  done
  row js "$([[ -n $raw && -n $proven ]] && echo collected || echo partial)" "$raw" "$proven" "$reasons"
}

has_rust && collect_rust
has_elixir && collect_elixir
has_js && collect_js

# Summary. No percentages: Hypatia judges.
{
  if [[ ! -s $rows ]]; then
    echo "### Proven coverage collector"; echo
    echo "Nothing to collect: no Cargo.toml, mix.exs or package.json at the repository root."
  else
    echo "### Proven coverage collector (shadow: collected, not judged)"; echo
    echo "| Language | Raw report | Proven report | Why missing |"
    echo "|---|---|---|---|"
    jq -r '[.language, (if .raw then "yes" else "no" end), (if .proven then "yes" else "no" end),
            (.reason // "" | gsub("\\|"; "/"))] | "| " + join(" | ") + " |"' "$rows"
    echo; echo "Hypatia judges these reports (\`mix hypatia.coverage.report\`)."
  fi
} > "$cov/summary.md"
jq -s --arg repo "$GITHUB_REPOSITORY" --arg commit "$GITHUB_SHA" --arg run "$run_id" --arg v "$version" \
  '{schema: "proven-cicd/coverage-collect-report/v1", artifact: "proven-coverage-collect", content_version: $v,
    repo: $repo, commit: $commit, run_id: $run, languages: .}' "$rows" > "$cov/collect-report.json"
cat "$cov/summary.md"
[[ -z ${GITHUB_STEP_SUMMARY:-} ]] || cat "$cov/summary.md" >> "$GITHUB_STEP_SUMMARY" || true

if [[ -s $rows ]]; then finish collected 0; else finish nothing_to_collect 0; fi
